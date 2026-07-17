//
//  RAGChunkBuilder.swift
//  Starcat
//
//  把 README、私有笔记、已有 AI 摘要和 repo metadata 转换为稳定 child chunks。
//
//  README 先按 Markdown heading 建 section，再按段落 / fenced code / table 这些不可随意打断的
//  block 打包。只有超长 section 才产生 overlap；普通 section 不重复正文。chunk key 由 heading
//  path 和 section 内 segment 序号生成，因此在 README 中插入无关章节不会改变其它章节的 key。
//

import Foundation

struct RAGChunkingConfiguration: Equatable, Sendable {
    var targetTokens = 700
    var minimumTokens = 180
    var maximumTokens = 1_100
    var overlapTokens = 80
    var hardMaximumTokens = 1_600

    static let `default` = RAGChunkingConfiguration()
}

struct RAGChunkBuildInput: Sendable {
    var repo: Repo
    var readme: String?
    var note: RepoNote?
    var summaryText: String?
    var summarySourceID: String
    var tags: [String]
    /// Metadata 的跨表事实在索引器一次聚合，Builder 只负责稳定序列化，不直接访问数据库。
    var metadataSnapshot: RAGMetadataSnapshot? = nil
}

/// 单项目 Metadata 分片需要的本地事实快照。
///
/// Release、Health、OpenSSF 和 Wiki 都是本地缓存；这里不持有 API，也不允许构建 Metadata 时触发网络。
struct RAGMetadataSnapshot: Sendable {
    var latestRelease: ReleaseRecord?
    var health: RepoHealthSnapshot?
    var openSSF: OpenSSFScoreRecord?
    var wikiLinks: [WikiLink] = []
}

struct RAGChunkBuildOutput: Equatable, Sendable {
    var readme: [RAGChunkDraft]
    var notes: [RAGChunkDraft]
    var summary: [RAGChunkDraft]
    var metadata: [RAGChunkDraft]

    var all: [RAGChunkDraft] { readme + notes + summary + metadata }
}

/// 将 Markdown 解析和 chunk 打包这类纯 CPU 工作与 UI actor 隔离。
///
/// `Task.detached` 不会自动继承父任务取消，因此必须用 cancellation handler 显式转发；
/// Builder 在开始和结束各检查一次，不为取消而返回可能被误写入索引的半旧计算结果。
enum RAGChunkBuildExecutor {
    static func build(
        _ input: RAGChunkBuildInput,
        using builder: RAGChunkBuilder
    ) async throws -> RAGChunkBuildOutput {
        try Task.checkCancellation()
        let task = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            let output = builder.build(input)
            try Task.checkCancellation()
            return output
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct RAGChunkBuilder: Sendable {
    private let configuration: RAGChunkingConfiguration

    init(configuration: RAGChunkingConfiguration = .default) {
        self.configuration = configuration
    }

    func build(_ input: RAGChunkBuildInput) -> RAGChunkBuildOutput {
        RAGChunkBuildOutput(
            readme: buildReadme(repoId: input.repo.id, markdown: input.readme),
            notes: buildNotes(repoId: input.repo.id, note: input.note),
            summary: buildSummary(
                repoId: input.repo.id,
                text: input.summaryText,
                sourceID: input.summarySourceID
            ),
            metadata: buildMetadata(
                repo: input.repo,
                note: input.note,
                tags: input.tags,
                snapshot: input.metadataSnapshot
            )
        )
    }

    func buildReadme(repoId: Int64, markdown: String?) -> [RAGChunkDraft] {
        guard let markdown = markdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty
        else { return [] }

        let sections = mergeSmallSections(parseSections(markdown))
        var drafts: [RAGChunkDraft] = []
        var sectionOccurrences: [String: Int] = [:]
        for section in sections {
            let baseSlug = slug(section.path.isEmpty ? section.title : section.path)
            let occurrence = sectionOccurrences[baseSlug, default: 0]
            sectionOccurrences[baseSlug] = occurrence + 1
            let sectionSlug = occurrence == 0 ? baseSlug : "\(baseSlug)-\(occurrence + 1)"
            let blocks = markdownBlocks(section.body)
            let packed = pack(blocks)
            for (segmentIndex, segment) in packed.enumerated() {
                let title = section.title.isEmpty ? "README" : section.title
                let path = section.path.isEmpty ? title : section.path
                drafts.append(RAGChunkDraft(
                    repoId: repoId,
                    source: .readme,
                    sourceId: "",
                    parentType: .readmeSection,
                    parentKey: "readme:\(sectionSlug)",
                    parentTitle: "README > \(path)",
                    chunkKey: "readme:\(sectionSlug):\(segmentIndex)",
                    chunkIndex: drafts.count,
                    sectionPath: path,
                    title: title,
                    content: segment.text,
                    tokenCount: TokenEstimator.estimate(text: segment.text),
                    isTruncated: segment.isTruncated
                ))
            }
        }
        return drafts
    }

    func buildNotes(repoId: Int64, note: RepoNote?) -> [RAGChunkDraft] {
        guard let content = note?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { return [] }
        return singleSourceDrafts(
            repoId: repoId,
            source: .notes,
            sourceId: "",
            parentType: .notes,
            parentKey: "notes",
            // Prompt 实际展示 parentTitle；必须直接声明这是用户在 Starcat 中填写的私人笔记，
            // 避免模型把含义宽泛的 Notes 误解为仓库公开字段。
            parentTitle: "Private note (user-authored in Starcat)",
            title: "Private notes",
            content: content
        )
    }

    func buildSummary(repoId: Int64, text: String?, sourceID: String) -> [RAGChunkDraft] {
        guard let content = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty
        else { return [] }
        return singleSourceDrafts(
            repoId: repoId,
            source: .summary,
            sourceId: sourceID,
            parentType: .summary,
            parentKey: "summary",
            parentTitle: "AI Summary",
            title: "AI summary",
            content: content
        )
    }

    /// 序列化项目的可检索事实。空值直接省略，不能把“未拉到”伪造成 Unknown。
    ///
    /// Metadata 被明确设计为 FTS-only：动态数字和时间保留原值，更新时只改倒排索引，
    /// 不生成 embedding，从而既能精确召回也不消耗向量额度。
    func buildMetadata(
        repo: Repo,
        note: RepoNote?,
        tags: [String],
        snapshot: RAGMetadataSnapshot?
    ) -> [RAGChunkDraft] {
        var lines = [
            "Repository: \(repo.fullName)",
            "GitHub URL: \(repo.htmlUrl)",
            "Stars: \(repo.starsCount)",
            "Forks: \(repo.forksCount)",
            "Watchers: \(repo.watchersCount)",
            "Archived: \(repo.isArchived)",
            "Fork: \(repo.isFork)",
            "Private: \(repo.isPrivate)",
            "Starred: \(repo.isStarred)",
            "Access state: \(repo.accessState.rawValue)",
            "Status: \(RepoStatus.parse(note?.status ?? RepoStatus.unread.rawValue).rawValue)"
        ]

        func append(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            lines.append("\(label): \(value)")
        }
        func append(_ label: String, _ value: Int?) {
            guard let value else { return }
            lines.append("\(label): \(value)")
        }
        func append(_ label: String, _ value: Double?) {
            guard let value else { return }
            lines.append("\(label): \(value)")
        }

        append("Description", repo.description)
        append("Homepage", repo.homepage)
        append("Clone URL", repo.cloneUrl)
        append("SSH URL", repo.sshUrl)
        append("Language", repo.language)
        append("Topics", repo.topicsArray.sorted().joined(separator: ", "))
        append("License", repo.license)
        append("Default branch", repo.defaultBranch)
        append("Subscribers", repo.subscribersCount)
        append("Open issues", repo.openIssuesCount)
        append("Access reason", repo.accessReason)
        append("Access checked at", repo.accessCheckedAt)
        append("Created at", repo.createdAt)
        append("Repository updated at", repo.updatedAt)
        append("Pushed at", repo.pushedAt)
        append("Starred at", repo.starredAt)
        append("Repository cached at", repo.cachedAt)
        append("Library state", note?.libraryState)
        append("Library updated at", note?.libraryUpdatedAt)
        append("Tags", tags.sorted().joined(separator: ", "))

        if let release = snapshot?.latestRelease {
            append("Latest release tag", release.tagName)
            append("Latest release name", release.name)
            append("Latest release URL", release.htmlUrl)
            append("Latest release published at", release.publishedAt)
            append("Latest release created at", release.createdAtRemote)
            lines.append("Latest release prerelease: \(release.isPrerelease)")
            lines.append("Latest release draft: \(release.isDraft)")
            let assets = ReleaseAssetCodec.decode(release.assetsJson)
            lines.append("Latest release asset count: \(assets.count)")
            lines.append("Latest release download count: \(assets.reduce(0) { $0 + $1.downloadCount })")
            append("Latest release fetched at", release.fetchedAt)
        }
        if let health = snapshot?.health {
            append("Repository health score", health.overallScore)
            append("Repository health grade", health.grade)
            append("Repository health status", health.fetchStatus.rawValue)
            append("Repository health computed at", health.computedAt)
        }
        if let openSSF = snapshot?.openSSF {
            append("OpenSSF status", openSSF.fetchStatus.rawValue)
            append("OpenSSF score", openSSF.aggregateScore)
            append("OpenSSF score date", openSSF.scoreDate)
            append("OpenSSF fetched at", openSSF.fetchedAt)
        }
        // 固定 provider 顺序来自 RepoWikiMenuState；未知 source 和非 http(s) URL 已在缓存派生层过滤。
        for link in snapshot?.wikiLinks ?? [] {
            let label: String
            switch link.source {
            case .deepWiki: label = "Wiki DeepWiki"
            case .zread: label = "Wiki ZRead"
            case .codeWiki: label = "Wiki CodeWiki"
            case .unknown: continue
            }
            append(label, link.url.absoluteString)
        }
        let content = lines.joined(separator: "\n")
        return [RAGChunkDraft(
            repoId: repo.id,
            source: .metadata,
            sourceId: "",
            parentType: .metadata,
            parentKey: "metadata",
            parentTitle: "Repository metadata",
            chunkKey: "metadata:0",
            chunkIndex: 0,
            sectionPath: "Metadata",
            title: repo.fullName,
            content: content,
            tokenCount: TokenEstimator.estimate(text: content),
            isTruncated: false
        )]
    }

    // MARK: - Markdown sections

    private struct MarkdownSection: Equatable {
        var title: String
        var path: String
        var body: String
    }

    private struct MarkdownBlock: Equatable {
        var text: String
        var tokens: Int
        var isTruncated: Bool
    }

    private func parseSections(_ markdown: String) -> [MarkdownSection] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var pathByLevel = Array(repeating: "", count: 6)
        var sections: [MarkdownSection] = []
        var currentTitle = "README"
        var currentPath = "README"
        var body: [String] = []
        var inFence = false

        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { body.removeAll(keepingCapacity: true); return }
            sections.append(MarkdownSection(title: currentTitle, path: currentPath, body: text))
            body.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                body.append(line)
                continue
            }
            if !inFence, let heading = Self.heading(trimmed) {
                flush()
                pathByLevel[heading.level - 1] = heading.title
                if heading.level < pathByLevel.count {
                    for index in heading.level..<pathByLevel.count { pathByLevel[index] = "" }
                }
                currentTitle = heading.title
                currentPath = pathByLevel.prefix(heading.level).filter { !$0.isEmpty }.joined(separator: " > ")
            } else if !Self.isLowValueLine(trimmed) {
                body.append(line)
            }
        }
        flush()
        return sections
    }

    private func mergeSmallSections(_ sections: [MarkdownSection]) -> [MarkdownSection] {
        var result: [MarkdownSection] = []
        var index = 0
        while index < sections.count {
            var current = sections[index]
            let currentTokens = TokenEstimator.estimate(text: current.body)
            if currentTokens < configuration.minimumTokens, index + 1 < sections.count {
                let next = sections[index + 1]
                let combined = current.body + "\n\n## " + next.title + "\n\n" + next.body
                if TokenEstimator.estimate(text: combined) <= configuration.maximumTokens {
                    current.body = combined
                    current.title = current.title == "README" ? next.title : current.title
                    index += 1
                }
            }
            result.append(current)
            index += 1
        }
        return result
    }

    // MARK: - Block packing

    private func markdownBlocks(_ body: String) -> [MarkdownBlock] {
        let lines = body.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(makeBlock(text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var codeLines = [line]
                index += 1
                while index < lines.count {
                    codeLines.append(lines[index])
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    index += 1
                }
                blocks.append(makeBlock(codeLines.joined(separator: "\n")))
                continue
            }
            if Self.startsTable(lines: lines, at: index) {
                flushParagraph()
                var tableLines: [String] = []
                while index < lines.count, lines[index].contains("|") {
                    tableLines.append(lines[index])
                    index += 1
                }
                blocks.append(contentsOf: tableBlocks(tableLines))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private func tableBlocks(_ lines: [String]) -> [MarkdownBlock] {
        guard lines.count > 2 else { return [makeBlock(lines.joined(separator: "\n"))] }
        let header = Array(lines.prefix(2))
        var result: [MarkdownBlock] = []
        var current = header
        for row in lines.dropFirst(2) {
            let candidate = (current + [row]).joined(separator: "\n")
            if TokenEstimator.estimate(text: candidate) > configuration.maximumTokens, current.count > 2 {
                result.append(makeBlock(current.joined(separator: "\n")))
                current = header + [row]
            } else {
                current.append(row)
            }
        }
        if current.count > 2 { result.append(makeBlock(current.joined(separator: "\n"))) }
        return result
    }

    private func makeBlock(_ text: String) -> MarkdownBlock {
        let tokens = TokenEstimator.estimate(text: text)
        guard tokens > configuration.hardMaximumTokens else {
            return MarkdownBlock(text: text, tokens: tokens, isTruncated: false)
        }
        // 行数截断无法处理 minified JSON 或超长代码单行：prefix/suffix 都会包含整行，
        // 结果反而比原文更长。按字符预算取首尾，确保估算 token 一定回到 hard max 内。
        let characterBudget = max(configuration.hardMaximumTokens * 3, 2)
        let keep = characterBudget / 2
        let marker = "... [content truncated by Starcat RAG] ..."
        let truncated = String(text.prefix(keep)) + "\n\(marker)\n" + String(text.suffix(keep))
        return MarkdownBlock(
            text: truncated,
            tokens: TokenEstimator.estimate(text: truncated),
            isTruncated: true
        )
    }

    private func pack(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        guard !blocks.isEmpty else { return [] }
        var result: [MarkdownBlock] = []
        var current: [MarkdownBlock] = []
        var currentTokens = 0

        func combined(_ blocks: [MarkdownBlock]) -> MarkdownBlock {
            let text = blocks.map(\.text).joined(separator: "\n\n")
            return MarkdownBlock(
                text: text,
                tokens: TokenEstimator.estimate(text: text),
                isTruncated: blocks.contains(where: \.isTruncated)
            )
        }

        for block in blocks {
            let wouldExceedTarget = currentTokens >= configuration.minimumTokens
                && currentTokens + block.tokens > configuration.targetTokens
            let wouldExceedMaximum = !current.isEmpty
                && currentTokens + block.tokens > configuration.maximumTokens
            if wouldExceedTarget || wouldExceedMaximum {
                result.append(combined(current))
                var overlap: [MarkdownBlock] = []
                var overlapCount = 0
                for candidate in current.reversed() where overlapCount < configuration.overlapTokens {
                    guard overlapCount + candidate.tokens <= configuration.overlapTokens else { continue }
                    overlap.insert(candidate, at: 0)
                    overlapCount += candidate.tokens
                }
                current = overlap
                currentTokens = overlap.reduce(0) { $0 + $1.tokens }
            }
            current.append(block)
            currentTokens += block.tokens
        }
        if !current.isEmpty { result.append(combined(current)) }
        return result
    }

    private func singleSourceDrafts(
        repoId: Int64,
        source: RAGChunkSource,
        sourceId: String,
        parentType: RAGChunkParentType,
        parentKey: String,
        parentTitle: String,
        title: String,
        content: String
    ) -> [RAGChunkDraft] {
        pack(markdownBlocks(content)).enumerated().map { index, segment in
            RAGChunkDraft(
                repoId: repoId,
                source: source,
                sourceId: sourceId,
                parentType: parentType,
                parentKey: parentKey,
                parentTitle: parentTitle,
                chunkKey: "\(source.rawValue):\(index)",
                chunkIndex: index,
                sectionPath: parentTitle,
                title: title,
                content: segment.text,
                tokenCount: segment.tokens,
                isTruncated: segment.isTruncated
            )
        }
    }

    private func slug(_ value: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var result = ""
        var previousWasDash = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash, !result.isEmpty {
                result.append("-")
                previousWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "section" : trimmed
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.count > hashes else { return nil }
        let separator = line.index(line.startIndex, offsetBy: hashes)
        guard line[separator].isWhitespace else { return nil }
        let title = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (hashes, title)
    }

    private static func startsTable(lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard separator.contains("|") else { return false }
        let characters = separator.filter { !$0.isWhitespace && $0 != "|" && $0 != ":" }
        return !characters.isEmpty && characters.allSatisfy { $0 == "-" }
    }

    private static func isLowValueLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let lower = line.lowercased()
        if lower.contains("shields.io") || lower.contains("badge.svg") { return true }
        if lower.hasPrefix("![") { return true }
        if lower.hasPrefix("<img") || lower.hasPrefix("<picture") { return true }
        return false
    }

}
