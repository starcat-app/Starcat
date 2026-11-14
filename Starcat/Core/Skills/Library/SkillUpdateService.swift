//
//  SkillUpdateService.swift
//  Starcat
//
//  更新发现只比较固定 Git 树，不下载或覆盖内容。相同仓库／ref 共享请求，
//  上游失败保留同一安装基线的既有更新证据，账号变化使本轮响应失效。
//

import Foundation

enum SkillUpdateState: String, Codable, Sendable {
    case neverChecked, checking, upToDate, available, unavailable, unsupported, stale
    var titleKey: String { "skills.update.state.\(rawValue)" }
}

/// availability 与最近尝试状态分离，离线不能把已发现的更新清零。
struct SkillUpdateCheck: SkillLibraryPersistedRecord, Equatable, Identifiable {
    static let databaseTableName = "skill_update_checks"
    let entryID: UUID
    let revisionID: UUID?
    var state: SkillUpdateState
    var hasUpdate = false
    var availableCommit: String?
    var attemptedAt = Date().timeIntervalSince1970
    var succeededAt: TimeInterval?
    var message: String?
    var id: UUID { entryID }

    enum CodingKeys: String, CodingKey {
        case state, message
        case entryID = "entry_id"
        case revisionID = "revision_id"
        case hasUpdate = "has_update"
        case availableCommit = "available_commit"
        case attemptedAt = "attempted_at"
        case succeededAt = "succeeded_at"
    }
}

/// 请求缓存只驻留内存；Token 的摘要参与身份，凭据不写入独立库或日志。
actor SkillUpdateRequests {
    private var heads: [String: (String, Date)] = [:]
    private var trees: [String: GitHubGitTreeDTO] = [:]
    private var headTasks: [String: Task<String, any Error>] = [:]
    private var treeTasks: [String: Task<GitHubGitTreeDTO, any Error>] = [:]
    private var cooldown: [String: Date] = [:]

    func head(
        locator: String, ref: String, authorizationID: String, api: any GitHubAPIClientProtocol
    ) async throws -> String {
        try Task.checkCancellation()
        let key = [authorizationID, locator, ref].joined(separator: "\u{0}")
        try checkCooldown(authorizationID)
        if let cached = heads[key], cached.1 > Date() { return cached.0 }
        if let task = headTasks[key] { return try await task.value }
        let parts = try repository(locator)
        let task = Task {
            guard let commit = try await api.repositoryLatestCommit(
                owner: parts[0], repo: parts[1], path: "", ref: ref
            ), commit.sha.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil
            else { throw RepoSkillError.emptyRepository }
            return commit.sha
        }
        headTasks[key] = task
        defer { headTasks[key] = nil }
        do {
            let commit = try await task.value
            if heads.count >= 64 { heads.removeAll() }
            heads[key] = (commit, Date().addingTimeInterval(60))
            return commit
        } catch { recordCooldown(error, authorizationID); throw error }
    }

    /// 优先共享仓库递归树；大仓库被截断时只查询目标子树，不把截断当作已完整。
    func files(
        locator: String, directory: String, commit: String,
        authorizationID: String, api: any GitHubAPIClientProtocol
    ) async throws -> [GitHubGitTreeEntryDTO] {
        let whole = try await tree(locator, commit, true, authorizationID, api)
        let entries: [GitHubGitTreeEntryDTO]
        if !whole.truncated {
            let prefix = directory.isEmpty ? "" : directory + "/"
            entries = whole.tree.filter { $0.path.hasPrefix(prefix) && $0.path != directory }.map {
                GitHubGitTreeEntryDTO(
                    path: String($0.path.dropFirst(prefix.count)), mode: $0.mode,
                    type: $0.type, sha: $0.sha, size: $0.size, url: nil
                )
            }
        } else {
            var ref = commit
            for component in directory.split(separator: "/") {
                let level = try await tree(locator, ref, false, authorizationID, api)
                guard !level.truncated, let child = level.tree.first(where: { $0.type == "tree" && $0.path == component })
                else { throw RepoSkillError.incomplete }
                ref = child.sha
            }
            let subtree = try await tree(locator, ref, true, authorizationID, api)
            guard !subtree.truncated else { throw RepoSkillError.incomplete }
            entries = subtree.tree
        }
        return try Self.validate(entries)
    }

    /// 完整文件集合与执行位都参与比较；目录 SHA 变化不代替具体文件证据。
    nonisolated static func signature(_ files: [GitHubGitTreeEntryDTO]) -> [String] {
        files.map { [$0.path, $0.mode, $0.type, $0.sha].joined(separator: "\u{0}") }.sorted()
    }

    private func tree(
        _ locator: String, _ ref: String, _ recursive: Bool,
        _ authorizationID: String, _ api: any GitHubAPIClientProtocol
    ) async throws -> GitHubGitTreeDTO {
        try Task.checkCancellation()
        try checkCooldown(authorizationID)
        let key = [authorizationID, locator, ref, String(recursive)].joined(separator: "\u{0}")
        if let cached = trees[key] { return cached }
        if let task = treeTasks[key] { return try await task.value }
        let parts = try repository(locator)
        let task = Task {
            if recursive { return try await api.repositoryGitTree(owner: parts[0], repo: parts[1], ref: ref) }
            return try await api.repositoryGitTreeLevel(owner: parts[0], repo: parts[1], ref: ref)
        }
        treeTasks[key] = task
        defer { treeTasks[key] = nil }
        do {
            let tree = try await task.value
            if trees.count >= 32 { trees.removeAll() }
            trees[key] = tree
            return tree
        } catch { recordCooldown(error, authorizationID); throw error }
    }

    private func repository(_ locator: String) throws -> [String] {
        let parts = locator.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw SkillImportError.source }
        return parts
    }

    private func checkCooldown(_ authorizationID: String) throws {
        if let date = cooldown[authorizationID], date > Date() {
            throw NetworkError.rateLimited(retryAfter: date.timeIntervalSinceNow)
        }
    }

    private func recordCooldown(_ error: any Error, _ authorizationID: String) {
        if case NetworkError.rateLimited(let seconds) = error {
            cooldown[authorizationID] = Date().addingTimeInterval(max(1, seconds))
        }
    }

    private nonisolated static func validate(_ entries: [GitHubGitTreeEntryDTO]) throws -> [GitHubGitTreeEntryDTO] {
        guard entries.count <= 5_000, Set(entries.map(\.path)).count == entries.count,
              entries.allSatisfy({
                  RepoFileTreeBuilder.isSafeRelativePath($0.path) && $0.path.split(separator: "/").count <= 16
                    && (($0.type == "tree" && $0.mode == "040000")
                        || ($0.type == "blob" && ["100644", "100755"].contains($0.mode)
                            && ($0.size ?? -1) >= 0 && ($0.size ?? Int.max) <= 67_108_864))
              }) else { throw RepoSkillError.unsupportedFiles }
        let files = entries.filter { $0.type == "blob" }.sorted { $0.path < $1.path }
        guard files.contains(where: { $0.path == "SKILL.md" }),
              files.reduce(Int64(0), { $0 + Int64($1.size ?? 0) }) <= 67_108_864
        else { throw RepoSkillError.incomplete }
        return files
    }
}

/// 单次检查冻结授权，逐条写回前核对安装 revision，过时结果不能污染更新后的条目。
actor SkillUpdateService {
    private let store: SkillLibraryStore
    private let tokenProvider: any GitHubTokenProviding
    private let makeClients: SkillImportService.ClientFactory
    private let requests: SkillUpdateRequests

    init(
        store: SkillLibraryStore, distributionGate: DistributionGate = DistributionGate(),
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider(),
        requests: SkillUpdateRequests = SkillUpdateRequests(),
        makeClients: @escaping SkillImportService.ClientFactory = SkillImportService.defaultClients
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.tokenProvider = tokenProvider
        self.requests = requests
        self.makeClients = makeClients
    }

    func check(entryIDs: Set<UUID>? = nil) async throws {
        let snapshot = try await store.snapshot()
        let token = await tokenProvider.currentToken()
        let authorizationID = Self.authorizationID(token)
        let api = makeClients(token).api
        for entry in snapshot.entries where entry.managementKind == .managed && (entryIDs?.contains(entry.id) ?? true) {
            try Task.checkCancellation()
            let old = snapshot.updateChecks.first { $0.entryID == entry.id && $0.revisionID == entry.currentRevisionID }
            var check = old ?? SkillUpdateCheck(entryID: entry.id, revisionID: entry.currentRevisionID, state: .neverChecked)
            check.attemptedAt = Date().timeIntervalSince1970
            do {
                guard let source = snapshot.sources.first(where: { $0.id == entry.sourceID }), source.kind == .github,
                      let revision = snapshot.revisions.first(where: { $0.id == entry.currentRevisionID }),
                      let baseline = revision.upstreamCommit else {
                    check.state = .unsupported
                    check.hasUpdate = false
                    check.availableCommit = nil
                    check.message = nil
                    try await store.save(check)
                    continue
                }
                let latest = try await requests.head(
                    locator: source.canonicalLocator, ref: entry.trackingRef ?? source.defaultRef ?? "HEAD",
                    authorizationID: authorizationID, api: api
                )
                let changed: Bool
                if baseline == latest { changed = false }
                else {
                    let remote = try await requests.files(
                        locator: source.canonicalLocator, directory: source.subdirectory, commit: latest,
                        authorizationID: authorizationID, api: api
                    )
                    let base = try await requests.files(
                        locator: source.canonicalLocator, directory: source.subdirectory, commit: baseline,
                        authorizationID: authorizationID, api: api
                    )
                    changed = SkillUpdateRequests.signature(remote) != SkillUpdateRequests.signature(base)
                }
                guard Self.authorizationID(await tokenProvider.currentToken()) == authorizationID else { throw SkillImportError.authChanged }
                try Task.checkCancellation()
                check.state = changed ? .available : .upToDate
                check.hasUpdate = changed
                check.availableCommit = latest
                check.succeededAt = Date().timeIntervalSince1970
                check.message = nil
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                check.state = old?.hasUpdate == true ? .stale : .unavailable
                check.message = error.localizedDescription
            }
            try await store.save(check)
        }
    }

    nonisolated static func authorizationID(_ token: String?) -> String {
        SkillFilePrimitives.digest(Data((token ?? "").utf8))
    }
}
