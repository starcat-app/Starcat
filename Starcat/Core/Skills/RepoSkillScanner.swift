//
//  RepoSkillScanner.swift
//  Starcat
//
//  复用 Git Trees、进程缓存和 blob 预览扫描真实 Skill。请求预算耗尽仍保留部分证据。
//

import Foundation

/// 每轮先冻结默认分支提交，再取树和描述文件；分支更新不会混进同一安装清单。
struct RepoSkillScanner: Sendable {
    let api: any GitHubAPIClientProtocol
    let downloader: any RepoFileDownloading
    var cache: RepoFileTreeSessionCache = .shared
    let cacheScope: String

    /// 文件树截断时有界遍历。较大仓库可以通过显式重新检测提高预算，而不宣称查全。
    @concurrent func scan(
        _ repo: Repo,
        treeBudget: Int = 64,
        manifestBudget: Int = 200,
        manifestConcurrency: Int = 4,
        onUpdate: (@Sendable (RepoSkillScan) -> Void)? = nil
    ) async throws -> RepoSkillScan {
        try Task.checkCancellation()
        let cacheGeneration = await cache.currentGeneration()
        guard let commit = try await api.repositoryLatestCommit(
            owner: repo.owner, repo: repo.name, path: "", ref: repo.defaultBranch ?? "HEAD"
        ) else { throw RepoSkillError.emptyRepository }
        let tree = try await cache.load(
            owner: repo.owner, repo: repo.name, ref: commit.sha,
            scope: cacheScope, api: api, expectedGeneration: cacheGeneration
        )
        var entries = tree.tree
        var complete = !tree.truncated
        var diagnostics: [String] = []
        if tree.truncated {
            var queue: [(prefix: String, sha: String)] = [("", tree.sha)]
            var cursor = 0
            var recovered: [GitHubGitTreeEntryDTO] = []
            while cursor < queue.count, cursor < treeBudget, recovered.count < 200_000 {
                try Task.checkCancellation()
                // 截断树的目录补查按 4 路并发。BFS 语义只要求先父后子，不要求同层请求串行。
                let batch = queue[cursor..<min(queue.count, cursor + 4, treeBudget)]
                cursor += batch.count
                let levels: [(item: (prefix: String, sha: String), level: GitHubGitTreeDTO?, failure: String?)] =
                    try await withThrowingTaskGroup(of: (Int, GitHubGitTreeDTO?, String?).self) { group in
                        for (offset, item) in batch.enumerated() {
                            group.addTask {
                                do {
                                    let level = try await self.api.repositoryGitTreeLevel(
                                        owner: repo.owner, repo: repo.name, ref: item.sha
                                    )
                                    return (offset, level, nil)
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    return (offset, nil, error.localizedDescription)
                                }
                            }
                        }
                        var values = Array(
                            repeating: (0, Optional<GitHubGitTreeDTO>.none, Optional<String>.none),
                            count: batch.count
                        )
                        for try await value in group { values[value.0] = value }
                        return zip(batch, values).map { ($0, $1.1, $1.2) }
                    }
                for (item, level, failure) in levels {
                    guard let level else {
                        diagnostics.append(item.prefix + ": " + (failure ?? String.l10n("repo.skills.error.incomplete")))
                        continue
                    }
                    if level.truncated { diagnostics.append(String.l10n("repo.skills.error.incomplete")) }
                    for entry in level.tree {
                        let path = item.prefix + entry.path
                        guard RepoFileTreeBuilder.isSafeRelativePath(path) else {
                            diagnostics.append(path)
                            continue
                        }
                        recovered.append(GitHubGitTreeEntryDTO(
                            path: path, mode: entry.mode, type: entry.type, sha: entry.sha, size: entry.size, url: entry.url
                        ))
                        if entry.type == "tree" { queue.append((path + "/", entry.sha)) }
                    }
                }
            }
            complete = cursor == queue.count && diagnostics.isEmpty
            // 用递归树已有的证据补充预算尚未到达的子目录，绝不重复计数。
            entries = Array(Dictionary((entries + recovered).map { ($0.path, $0) }, uniquingKeysWith: { _, new in new }).values)
        }
        // 路径只排序一次；每份 manifest 用二分区间取得目录，避免 N 份 Skill 扫 N 次整棵树。
        entries.sort { $0.path < $1.path }
        let manifests = entries.filter { $0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md") }
        let candidates = Array(manifests.prefix(manifestBudget))
        let concurrency = max(1, min(8, manifestConcurrency))
        var skills: [RepoSkill] = []
        var checked = 0
        let clock = ContinuousClock()
        var lastPublication: ContinuousClock.Instant?
        for start in stride(from: candidates.startIndex, to: candidates.endIndex, by: concurrency) {
            let batch = candidates[start..<min(start + concurrency, candidates.endIndex)]
            do {
                // 候选描述按小批次读取，首个有效 Skill 不需要等待整个集合完成。
                let manifestResults = try await withThrowingTaskGroup(of: (Int, String?, String?).self) { group in
                    for (offset, entry) in batch.enumerated() {
                        group.addTask {
                            do {
                                let preview = try await self.downloader.preview(
                                    owner: repo.owner, repo: repo.name, sha: entry.sha,
                                    relativePath: entry.path, hintedSize: entry.size
                                )
                                guard case .text(let markdown) = preview else {
                                    throw RepoSkillError.invalidManifest
                                }
                                return (offset, markdown, nil)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                return (offset, nil, error.localizedDescription)
                            }
                        }
                    }
                    var values = Array(repeating: (0, Optional<String>.none, Optional<String>.none), count: batch.count)
                    for try await value in group { values[value.0] = value }
                    return values
                }
                for (offset, entry) in batch.enumerated() {
                    let markdown = manifestResults[offset].1
                    guard entry.type == "blob", entry.mode == "100644" || entry.mode == "100755",
                          RepoFileTreeBuilder.isSafeRelativePath(entry.path) else {
                        diagnostics.append(entry.path + ": " + String.l10n("repo.skills.error.unsupported"))
                        continue
                    }
                    guard let markdown else {
                        diagnostics.append(entry.path + ": " + (manifestResults[offset].2 ?? ""))
                        continue
                    }
                    let directory = String(entry.path.dropLast("SKILL.md".count))
                    guard let metadata = try? SkillFrontmatter.parse(markdown, directory: directory) else {
                        diagnostics.append(entry.path + ": " + RepoSkillError.invalidManifest.localizedDescription)
                        continue
                    }
                    let contents = Self.contents(in: entries, directory: directory)
                    let unsupported = contents.contains {
                        $0.type == "commit" || $0.mode == "120000"
                            || !RepoFileTreeBuilder.isSafeRelativePath($0.path)
                    }
                    let nested = Self.contents(in: manifests, directory: directory).contains { $0.path != entry.path }
                    let externalReferences = Self.hasReferencesOutsideDirectory(markdown, directory: directory)
                    let files = contents.filter { $0.type == "blob" && ($0.mode == "100644" || $0.mode == "100755") }
                        .map { RepoSkillFile(path: String($0.path.dropFirst(directory.count)), sha: $0.sha, size: $0.size, mode: $0.mode) }
                    skills.append(RepoSkill(
                        repositoryID: repo.id, commitSHA: commit.sha, directory: directory,
                        name: metadata.name, summary: metadata.description,
                        manifest: SkillFrontmatter.stripFrontmatter(markdown), files: files,
                        installationIssue: !complete ? String.l10n("repo.skills.error.incomplete")
                            : externalReferences ? String.l10n("repo.skills.error.externalReferences")
                            : (unsupported || nested ? String.l10n("repo.skills.error.unsupported") : nil)
                    ))
                }
            } catch {
                // 任务组只让取消向外传播；其余异常已在逐项结果中保留诊断。
                throw error
            }
            checked += batch.count
            // 首批立即反馈；后续合并到最多每 150ms 一份，终态始终由返回值完整交付。
            if !skills.isEmpty, lastPublication == nil || lastPublication!.duration(to: clock.now) >= .milliseconds(150) {
                lastPublication = clock.now
                onUpdate?(RepoSkillScan(
                    repositoryID: repo.id, commitSHA: commit.sha,
                    sourcePushedAt: repo.pushedAt, sourceBranch: repo.defaultBranch,
                    checkedAt: .now, complete: false, skills: skills.sorted { $0.directory < $1.directory }, diagnostics: diagnostics,
                    manifestTotal: manifests.count, manifestChecked: checked,
                    version: RepoSkillScan.rulesVersion
                ))
            }
        }
        if manifests.count > manifestBudget { complete = false }
        skills.sort { $0.directory < $1.directory }
        return RepoSkillScan(
            repositoryID: repo.id, commitSHA: commit.sha,
            sourcePushedAt: repo.pushedAt, sourceBranch: repo.defaultBranch,
            checkedAt: .now, complete: complete && diagnostics.isEmpty,
            skills: skills, diagnostics: diagnostics,
            manifestTotal: manifests.count, manifestChecked: candidates.count,
            version: RepoSkillScan.rulesVersion
        )
    }

    /// Git 路径按相同字典序排列，前缀范围连续；根 Skill 仍覆盖整棵树，安装边界保持不变。
    private static func contents(
        in entries: [GitHubGitTreeEntryDTO], directory: String
    ) -> ArraySlice<GitHubGitTreeEntryDTO> {
        guard !directory.isEmpty else { return entries[...] }
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].path < directory { lower = middle + 1 } else { upper = middle }
        }
        let start = lower
        upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entries[middle].path.hasPrefix(directory) { lower = middle + 1 } else { upper = middle }
        }
        return entries[start..<lower]
    }

    /// 明确指向目录外的 Markdown 附件不能随单个 Skill 交付；保留预览并说明打包限制。
    static func hasReferencesOutsideDirectory(_ markdown: String, directory: String) -> Bool {
        guard !directory.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\]\(\s*<?((?:\.\.?/)+[^)\s>]+)"#)
        else { return false }
        let base = URL(fileURLWithPath: "/repository/" + directory, isDirectory: true).standardizedFileURL
        let source = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: source.length)).contains { match in
            let relative = source.substring(with: match.range(at: 1)).removingPercentEncoding
                ?? source.substring(with: match.range(at: 1))
            let destination = base.appendingPathComponent(relative).standardizedFileURL.path
            return !destination.hasPrefix(base.path + "/") && destination != base.path
        }
    }
}
