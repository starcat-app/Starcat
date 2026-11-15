//
//  SkillImportService.swift
//  Starcat
//
//  本地／GitHub 导入只准备可评审的完整目录，不自动分配。
//  GitHub 请求冻结授权与 commit；预览之后仍由操作协调器复核指纹并提交。
//

import Foundation

struct SkillGitHubImportRequest: Sendable {
    let repository: String
    var ref = ""
    var directory = ""
}

struct SkillGitHubSelection: Sendable {
    let owner: String
    let repository: String
    let ref: String
    let directory: String
    var locator: String { "\(owner)/\(repository)".lowercased() }
}

struct SkillGitHubSnapshot: Sendable {
    let selection: SkillGitHubSelection
    let commit: String
    let files: [GitHubGitTreeEntryDTO]
}

struct SkillGitHubClients: Sendable {
    let api: any GitHubAPIClientProtocol
    let downloader: any RepoFileDownloading
}

/// 授权摘要只存在于本次预览内存中，不写入来源、回执或 journal。
struct PreparedSkillImport: Sendable, Identifiable {
    let plan: SkillContentOperationPlan
    let temporaryRoot: URL?
    let authorizationID: String?
    var id: UUID { plan.id }
    var fileCount: Int { plan.fingerprint.members.filter { $0.kind == .file }.count }
}

enum SkillImportError: LocalizedError {
    case source, existing, ref, authChanged
    var errorDescription: String? {
        let key = switch self {
        case .source: "source"
        case .existing: "existing"
        case .ref: "ref"
        case .authChanged: "authChanged"
        }
        return String.l10n("skills.import.error.\(key)")
    }
}

/// 固定 Token 只服务这一轮网络请求，账号切换不能让同一目录混入另一账号的响应。
private struct SkillImportTokenProvider: GitHubTokenProviding {
    let token: String?
    var requiresAuthentication: Bool { token != nil }
    func currentToken() async -> String? { token }
}

actor SkillImportService {
    typealias ClientFactory = @Sendable (String?) -> SkillGitHubClients
    nonisolated let store: SkillLibraryStore
    private let operations: SkillOperationCoordinator
    private let tokenProvider: any GitHubTokenProviding
    private let makeClients: ClientFactory
    private let updateRequests: SkillUpdateRequests
    private var temporaryRoots: Set<URL> = []
    private var retainedRoots: Set<URL> = []
    private var executingSources: Set<String> = []

    init(
        store: SkillLibraryStore,
        operations: SkillOperationCoordinator,
        distributionGate: DistributionGate = DistributionGate(),
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider(),
        updateRequests: SkillUpdateRequests = SkillUpdateRequests(),
        makeClients: @escaping ClientFactory = SkillImportService.defaultClients
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.store = store
        self.operations = operations
        self.tokenProvider = tokenProvider
        self.makeClients = makeClients
        self.updateRequests = updateRequests
    }

    /// 导入与更新共用冻结授权的客户端构造，真实凭据不进入持久模型。
    nonisolated static func defaultClients(_ token: String?) -> SkillGitHubClients {
        let provider = SkillImportTokenProvider(token: token)
        return SkillGitHubClients(
            api: GitHubAPIClient(tokenProvider: provider),
            downloader: RepoFileDownloader(tokenProvider: provider)
        )
    }

    /// 词法别名在来源身份中归一；原始目录始终保留，后续复制的是完整文件集合。
    func prepareLocal(_ directory: URL) async throws -> PreparedSkillImport {
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        return try await makePreview(
            directory: canonical,
            source: SkillLibrarySource(kind: .local, canonicalLocator: canonical.path, subdirectory: ""),
            trackingRef: nil, commit: nil, temporaryRoot: nil, authorizationID: nil,
            expectedDirectory: canonical.lastPathComponent
        )
    }

    /// 先冻结 commit，再按该树逐 blob 下载，不运行 git、hook 或仓库脚本。
    func prepareGitHub(_ request: SkillGitHubImportRequest) async throws -> PreparedSkillImport {
        let token = await tokenProvider.currentToken()
        let authorizationID = Self.authorizationID(token)
        let clients = makeClients(token)
        let selection = try await selection(request, api: clients.api)
        let snapshot = try await snapshot(selection, api: clients.api)
        try await validateAuthorization(authorizationID)
        return try await download(snapshot, clients: clients, authorizationID: authorizationID)
    }

    /// 仓库详情已展示某个 commit，入库必须使用该版本；来源分支仅用于后续更新发现。
    func prepareRepositorySkill(_ request: SkillRepositoryImportRequest) async throws -> PreparedSkillImport {
        let skill = request.skill
        let directory = skill.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard request.repo.id == skill.repositoryID, skill.installationIssue == nil,
              skill.commitSHA.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil,
              skill.directory == directory || skill.directory == directory + "/"
        else { throw SkillImportError.source }
        let prepared = try await prepareGitHub(.init(
            repository: "\(request.repo.owner)/\(request.repo.name)", ref: skill.commitSHA, directory: directory
        ))
        do {
            guard prepared.plan.entry.manifestName == skill.name else { throw SkillOperationError.planChanged }
            var source = prepared.plan.source
            source.defaultRef = request.trackingRef
            var entry = prepared.plan.entry
            entry.trackingRef = request.trackingRef
            return PreparedSkillImport(
                plan: SkillContentOperationPlan(
                    id: prepared.id, createdAt: prepared.plan.createdAt,
                    source: source, entry: entry, revision: prepared.plan.revision,
                    incomingDirectory: prepared.plan.incomingDirectory, fingerprint: prepared.plan.fingerprint,
                    previousEntry: nil, previousReceipt: nil
                ),
                temporaryRoot: prepared.temporaryRoot, authorizationID: prepared.authorizationID
            )
        } catch { discard(prepared); throw error }
    }

    /// 比较来源时保留条目身份与安装基线；明确 commit 时绝不重新解析默认分支。
    func prepareUpdate(
        entryID: UUID, commit: String? = nil, payloadCache: SkillImportPayloadCache? = nil
    ) async throws -> PreparedSkillImport {
        let stored = try await store.snapshot()
        guard let entry = stored.entries.first(where: { $0.id == entryID && $0.managementKind == .managed }),
              let source = stored.sources.first(where: { $0.id == entry.sourceID }),
              try await store.receipt(for: entryID)?.revisionID == entry.currentRevisionID
        else { throw SkillOperationError.ownership }
        if source.kind == .local {
            return try await makePreview(
                directory: URL(fileURLWithPath: source.canonicalLocator), source: source,
                trackingRef: entry.trackingRef, commit: nil, temporaryRoot: nil, authorizationID: nil,
                expectedDirectory: entry.manifestName, previous: entry
            )
        }
        let token = await tokenProvider.currentToken()
        let authorizationID = Self.authorizationID(token)
        let clients = makeClients(token)
        let parts = source.canonicalLocator.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw SkillImportError.source }
        let fixed: String
        if let commit { fixed = commit }
        else {
            fixed = try await updateRequests.head(
                locator: source.canonicalLocator, ref: entry.trackingRef ?? source.defaultRef ?? "HEAD",
                authorizationID: authorizationID, api: clients.api
            )
        }
        guard fixed.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil else { throw SkillImportError.ref }
        let files = try await updateRequests.files(
            locator: source.canonicalLocator, directory: source.subdirectory,
            commit: fixed, authorizationID: authorizationID, api: clients.api
        )
        let snapshot = SkillGitHubSnapshot(
            selection: .init(owner: parts[0], repository: parts[1], ref: entry.trackingRef ?? "HEAD", directory: source.subdirectory),
            commit: fixed, files: files
        )
        try await validateAuthorization(authorizationID)
        return try await download(
            snapshot, clients: clients, authorizationID: authorizationID, previous: entry, payloadCache: payloadCache
        )
    }

    /// 确认前再检查授权；已下载的私有预览不能在换账号后静默入库。
    func execute(_ preview: PreparedSkillImport) async -> SkillOperationResult {
        let source = preview.plan.source
        let identity = [source.kind.rawValue, source.canonicalLocator, source.subdirectory].joined(separator: "\u{0}")
        guard executingSources.insert(identity).inserted else {
            return SkillOperationResult(
                id: preview.id, entryID: nil, status: .conflict,
                message: SkillOperationError.planChanged.localizedDescription
            )
        }
        defer { executingSources.remove(identity) }
        let result: SkillOperationResult
        do {
            if let identity = preview.authorizationID { try await validateAuthorization(identity) }
            try Task.checkCancellation()
            _ = await operations.recover()
            let snapshot = try await store.snapshot()
            let existingSource = snapshot.sources.first {
                $0.kind == source.kind && $0.canonicalLocator == source.canonicalLocator && $0.subdirectory == source.subdirectory
            }
            if preview.plan.previousEntry == nil, let existingSource, let existing = snapshot.entries.first(where: {
                $0.sourceID == existingSource.id && $0.managementKind == .managed
            }) {
                result = SkillOperationResult(id: preview.id, entryID: existing.id, status: .alreadySatisfied, message: nil)
            } else { result = await operations.execute(preview.plan) }
        } catch {
            let cancelled = error is CancellationError || (error as? SkillImportError) == .authChanged
            result = SkillOperationResult(
                id: preview.id, entryID: preview.plan.entry.id,
                status: cancelled ? .cancelled : .failed, message: error.localizedDescription
            )
        }
        if result.status == .needsRecovery, let root = preview.temporaryRoot { retainedRoots.insert(root) }
        else { discard(preview) }
        return result
    }

    /// 只清理本服务创建且未进入恢复现场的下载缓存，不接触本地原目录或事务 payload。
    func discard(_ preview: PreparedSkillImport) {
        guard let root = preview.temporaryRoot, temporaryRoots.contains(root), !retainedRoots.contains(root) else { return }
        do {
            try FileManager.default.removeItem(at: root)
            temporaryRoots.remove(root)
        } catch {}
    }

    private func makePreview(
        directory: URL, source: SkillLibrarySource, trackingRef: String?, commit: String?,
        temporaryRoot: URL?, authorizationID: String?, expectedDirectory: String,
        previous: SkillLibraryEntry? = nil
    ) async throws -> PreparedSkillImport {
        let fingerprint = try await SkillFilePrimitives.fingerprint(directory)
        let bytes = try await Self.manifestBytes(directory)
        let metadata = try SkillFrontmatter.parse(
            String(decoding: bytes, as: UTF8.self), directory: expectedDirectory
        )
        guard let manifest = fingerprint.members.first(where: { $0.path == "SKILL.md" }),
              manifest.digest == SkillFilePrimitives.digest(bytes) else { throw SkillOperationError.planChanged }
        let snapshot = try await store.snapshot()
        let existing = snapshot.sources.first {
            $0.kind == source.kind && $0.canonicalLocator == source.canonicalLocator && $0.subdirectory == source.subdirectory
        }
        if previous == nil, let existing, snapshot.entries.contains(where: { $0.sourceID == existing.id && $0.managementKind == .managed }) {
            throw SkillImportError.existing
        }
        let source = existing ?? source
        var entry = previous ?? SkillLibraryEntry(
            sourceID: source.id, manifestName: metadata.name, summary: metadata.description,
            managementKind: .managed, trackingRef: trackingRef
        )
        guard previous == nil || metadata.name == previous?.manifestName else { throw SkillOperationError.planChanged }
        entry.summary = metadata.description
        entry.updatedAt = Date().timeIntervalSince1970
        let revision = snapshot.revisions.first { $0.entryID == entry.id && $0.contentDigest == fingerprint.digest } ?? SkillLibraryRevision(
            entryID: entry.id, contentDigest: fingerprint.digest, manifestDigest: SkillFilePrimitives.digest(bytes),
            upstreamCommit: commit
        )
        let receipt: SkillLibraryReceipt?
        if let previous { receipt = try await store.receipt(for: previous.id) }
        else { receipt = nil }
        return PreparedSkillImport(
            plan: SkillContentOperationPlan(
                source: source, entry: entry, revision: revision, incomingDirectory: directory.path,
                fingerprint: fingerprint, previousEntry: previous, previousReceipt: receipt
            ),
            temporaryRoot: temporaryRoot, authorizationID: authorizationID
        )
    }

    /// tree URL 的 slash ref 由分支证据或显式 ref 拆解；多义时让用户分别填写。
    private func selection(
        _ request: SkillGitHubImportRequest, api: any GitHubAPIClientProtocol
    ) async throws -> SkillGitHubSelection {
        let raw = request.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let components: [String]
        if raw.contains("://") {
            guard let url = URL(string: raw), url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil
            else { throw SkillImportError.source }
            components = url.path.split(separator: "/").map(String.init)
        } else { components = raw.split(separator: "/").map(String.init) }
        guard components.count >= 2 else { throw SkillImportError.source }
        let owner = components[0]
        let repository = components[1].hasSuffix(".git") ? String(components[1].dropLast(4)) : components[1]
        guard owner.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil,
              repository.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              repository != ".", repository != ".." else { throw SkillImportError.source }
        var ref = request.ref.trimmingCharacters(in: .whitespacesAndNewlines)
        var directory = request.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if components.count > 2 {
            guard components.count >= 4, components[2] == "tree" else { throw SkillImportError.source }
            let tail = Array(components.dropFirst(3))
            if ref.isEmpty {
                if tail[0].range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil { ref = tail[0] }
                else {
                    let branches = try await api.repositoryBranches(owner: owner, repo: repository)
                    let matches = branches.map(\.name).filter { tail.starts(with: $0.split(separator: "/").map(String.init)) }
                    guard matches.count <= 1 else { throw SkillImportError.ref }
                    ref = matches.first ?? tail[0]
                }
            }
            let parts = ref.split(separator: "/").map(String.init)
            guard !parts.isEmpty, tail.starts(with: parts) else { throw SkillImportError.ref }
            let inferred = tail.dropFirst(parts.count).joined(separator: "/")
            guard directory.isEmpty || directory == inferred else { throw SkillImportError.ref }
            directory = inferred
        }
        if ref.isEmpty { ref = "HEAD" }
        guard ref.count <= 255, !ref.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              directory.isEmpty || RepoFileTreeBuilder.isSafeRelativePath(directory),
              directory.split(separator: "/").count <= 16 else { throw SkillImportError.source }
        return SkillGitHubSelection(owner: owner, repository: repository, ref: ref, directory: directory)
    }

    /// 只取指定 Skill 子树。父仓库的递归树截断时不宣称所需文件已经完整。
    private func snapshot(
        _ selection: SkillGitHubSelection, api: any GitHubAPIClientProtocol
    ) async throws -> SkillGitHubSnapshot {
        try Task.checkCancellation()
        let commit: String
        if selection.ref.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil { commit = selection.ref }
        else {
            guard let resolved = try await api.repositoryLatestCommit(
                owner: selection.owner, repo: selection.repository, path: "", ref: selection.ref
            ), resolved.sha.range(of: #"^[a-fA-F0-9]{40}$"#, options: .regularExpression) != nil
            else { throw RepoSkillError.emptyRepository }
            commit = resolved.sha
        }
        var treeRef = commit
        for component in selection.directory.split(separator: "/") {
            let level = try await api.repositoryGitTreeLevel(owner: selection.owner, repo: selection.repository, ref: treeRef)
            guard !level.truncated, let child = level.tree.first(where: { $0.type == "tree" && $0.path == component })
            else { throw RepoSkillError.incomplete }
            treeRef = child.sha
        }
        let tree = try await api.repositoryGitTree(owner: selection.owner, repo: selection.repository, ref: treeRef)
        guard !tree.truncated, tree.tree.count <= 5_000,
              tree.tree.allSatisfy({
                  RepoFileTreeBuilder.isSafeRelativePath($0.path) && $0.path.split(separator: "/").count <= 16
                      && (($0.type == "tree" && $0.mode == "040000")
                          || ($0.type == "blob" && ["100644", "100755"].contains($0.mode)))
              }) else { throw RepoSkillError.unsupportedFiles }
        let files = tree.tree.filter { $0.type == "blob" }.sorted { $0.path < $1.path }
        guard files.contains(where: { $0.path == "SKILL.md" }),
              files.allSatisfy({ ($0.size ?? -1) >= 0 && ($0.size ?? Int.max) <= 67_108_864 }),
              files.reduce(Int64(0), { $0 + Int64($1.size ?? 0) }) <= 67_108_864
        else { throw RepoSkillError.incomplete }
        return SkillGitHubSnapshot(selection: selection, commit: commit, files: files)
    }

    private func download(
        _ snapshot: SkillGitHubSnapshot, clients: SkillGitHubClients, authorizationID: String,
        previous: SkillLibraryEntry? = nil, payloadCache: SkillImportPayloadCache? = nil
    ) async throws -> PreparedSkillImport {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("StarcatSkillImport-\(UUID().uuidString)")
        let content = root.appendingPathComponent("content")
        let downloads = root.appendingPathComponent("downloads")
        try manager.createDirectory(at: content, withIntermediateDirectories: true)
        temporaryRoots.insert(root)
        do {
            var bytes: Int64 = 0
            for file in snapshot.files {
                try Task.checkCancellation()
                try await validateAuthorization(authorizationID)
                let fileURL: URL
                if let payloadCache {
                    fileURL = downloads.appendingPathComponent(file.path)
                    try await payloadCache.copy(
                        file: file, selection: snapshot.selection, authorizationID: authorizationID,
                        downloader: clients.downloader, destination: fileURL
                    )
                } else {
                    fileURL = try await clients.downloader.download(
                        owner: snapshot.selection.owner, repo: snapshot.selection.repository, sha: file.sha,
                        relativePath: file.path, toRoot: downloads
                    )
                }
                guard fileURL.resolvingSymlinksInPath().path.hasPrefix(downloads.resolvingSymlinksInPath().path + "/"),
                      !SkillFilePrimitives.isSymbolicLink(fileURL),
                      try await clients.downloader.verifyDownloadedFile(
                        owner: snapshot.selection.owner, repo: snapshot.selection.repository, sha: file.sha, fileURL: fileURL
                      ) else { throw RepoSkillError.verification }
                bytes += (try manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard bytes <= 67_108_864 else { throw RepoSkillError.incomplete }
                let destination = content.appendingPathComponent(file.path)
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: fileURL, to: destination)
                try manager.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: destination.path)
            }
            try await validateAuthorization(authorizationID)
            try Task.checkCancellation()
            return try await makePreview(
                directory: content,
                source: SkillLibrarySource(
                    kind: .github, canonicalLocator: snapshot.selection.locator, subdirectory: snapshot.selection.directory,
                    defaultRef: snapshot.selection.ref
                ),
                trackingRef: snapshot.selection.ref, commit: snapshot.commit, temporaryRoot: root,
                authorizationID: authorizationID, expectedDirectory: previous?.manifestName ?? snapshot.selection.directory,
                previous: previous
            )
        } catch {
            try? manager.removeItem(at: root)
            temporaryRoots.remove(root)
            throw error
        }
    }

    private func validateAuthorization(_ expected: String) async throws {
        guard Self.authorizationID(await tokenProvider.currentToken()) == expected else { throw SkillImportError.authChanged }
    }

    private static func authorizationID(_ token: String?) -> String {
        SkillFilePrimitives.digest(Data((token ?? "").utf8))
    }

    /// 单独限制 manifest，完整目录预算不意味着允许一次解码数十 MiB 的 YAML。
    @concurrent static func manifestBytes(_ directory: URL) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent("SKILL.md"))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
        guard bytes.count <= 1_048_576, String(data: bytes, encoding: .utf8) != nil else { throw RepoSkillError.invalidManifest }
        return bytes
    }
}
