//
//  RepoSkillStore.swift
//  Starcat
//
//  详情、筛选共用的本地证据与有界后台队列。每次异步操作固定 writer 和账号代际。
//

import Foundation
import GRDB
import Observation

/// 主线程只发布轻量快照；网络沿用现有 GitHub 客户端，SQLite 不改变仓库归属。
@MainActor
@Observable
final class RepoSkillStore {
    @ObservationIgnored private var scanSnapshots: [Int64: RepoSkillScan] = [:]
    /// 主列表读取扫描证据时只订阅语义修订；详情进度经独立消费者回调发布。
    /// 否则即便 revision 不变，观察 scans 字典仍会使所有仓库行随每批 manifest 失效。
    var scans: [Int64: RepoSkillScan] {
        _ = revision
        return scanSnapshots
    }
    private(set) var errors: [Int64: String] = [:]
    private(set) var scanningIDs: Set<Int64> = []
    private(set) var revision: UInt64 = 0
    private(set) var isPaused = false
    private(set) var candidateCount = 0
    private(set) var processedCount = 0
    private(set) var remainingCount = 0
    private(set) var paginationRevision: UInt64 = 0
    private(set) var isChangingAccount = false
    private let database: any DatabaseManaging
    private let publicAPI: any GitHubAPIClientProtocol
    private let privateAPI: any GitHubAPIClientProtocol
    private let privateDownloader: any RepoFileDownloading
    private let publicDownloader: any RepoFileDownloading
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var loadedAccount: String?
    @ObservationIgnored private var pending: [Repo] = []
    @ObservationIgnored private var candidateRepos: [Repo] = []
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var admitted: Set<String> = []
    @ObservationIgnored private var candidateScope = ""
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var inflight: [Int64: Task<RepoSkillScan, Error>] = [:]
    @ObservationIgnored private var loadTask: Task<[RepoSkillScan], Error>?
    @ObservationIgnored private var installations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var knownRepos: [Int64: Repo] = [:]
    @ObservationIgnored private var updateHandlers: [Int64: [UUID: @MainActor @Sendable (RepoSkillScan) -> Void]] = [:]
    @ObservationIgnored private var consumers: [Int64: Set<UUID>] = [:]
    @ObservationIgnored private var scanTokens: [Int64: UUID] = [:]

    var accountRevision: UInt64 { epoch }

    init(
        database: any DatabaseManaging,
        publicAPI: any GitHubAPIClientProtocol,
        privateAPI: any GitHubAPIClientProtocol,
        publicDownloader: any RepoFileDownloading = RepoFileDownloader(),
        privateDownloader: any RepoFileDownloading
    ) {
        self.database = database
        self.publicAPI = publicAPI
        self.privateAPI = privateAPI
        self.publicDownloader = publicDownloader
        self.privateDownloader = privateDownloader
    }

    /// 账号数据库内的扫描摘要跨启动恢复；重开库后旧 writer 永远不能指向新账号。
    func prepare() async {
        guard !isChangingAccount else { return }
        let account = database.databasePath ?? "memory:\(database.currentUserId ?? 0)"
        guard loadedAccount != account else { return }
        let expected = epoch
        let writer = database.writer
        let task: Task<[RepoSkillScan], Error>
        if let loadTask {
            task = loadTask
        } else {
            task = Task {
                try await writer.read { db in
                    try Data.fetchAll(db, sql: "SELECT payload FROM repo_skill_scans")
                        .compactMap { try? JSONDecoder().decode(RepoSkillScan.self, from: $0) }
                }
            }
            loadTask = task
        }
        do {
            let values = try await task.value
            guard epoch == expected, loadedAccount != account else { return }
            // 恢复期间详情可能已完成新扫描，旧数据库快照不能覆盖更新后的证据。
            for value in values where scans[value.repositoryID] == nil
                && errors[value.repositoryID] == nil && !scanningIDs.contains(value.repositoryID) {
                scanSnapshots[value.repositoryID] = value
            }
            loadedAccount = account
            loadTask = nil
            revision &+= 1
        } catch {
            guard epoch == expected else { return }
            loadTask = nil
            AppLog.database.warning("Skill index load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func presence(for repo: Repo) -> RepoSkillPresence {
        guard let scan = scans[repo.id], scan.isFresh(for: withKnownMetadata(repo)),
              errors[repo.id] == nil else { return .unknown }
        return scan.presence
    }

    func presence(repositoryID: Int64) -> RepoSkillPresence {
        if let repo = knownRepos[repositoryID] { return presence(for: repo) }
        guard let scan = scans[repositoryID], scan.checkedAt.addingTimeInterval(86_400) > .now,
              scan.version == RepoSkillScan.rulesVersion,
              errors[repositoryID] == nil else { return .unknown }
        return scan.presence
    }

    /// 单次最多补查 200 个候选；详情主动重试可以越过本轮 attempted，后台不循环轰炸失败项。
    func enqueue(_ candidates: [Repo], scope: String) {
        guard !isChangingAccount else { return }
        if candidateScope != scope {
            candidateScope = scope
            admitted = []
            attempted = []
            pending = []
        }
        var seen: Set<Int64> = []
        candidateRepos = candidates.filter { seen.insert($0.id).inserted }
        candidateRepos.forEach { remember($0) }
        let eligible = Set(candidateRepos.map(\.id))
        pending.removeAll { !eligible.contains($0.id) || presence(for: $0) != .unknown }
        var queued = Set(pending.map(\.id))
        for repo in candidateRepos where presence(for: repo) == .unknown
            && !attempted.contains(attemptKey(repo)) && !queued.contains(repo.id) {
            guard admitted.count < 200 else { break }
            admitted.insert(attemptKey(repo))
            queued.insert(repo.id)
            pending.append(repo)
        }
        updateCoverage()
        runWorkerIfNeeded()
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused { runWorkerIfNeeded() }
    }

    /// 关闭筛选后清空待查范围；当前已开始的一项可完成缓存，不再继续后台批次。
    func stopBackgroundScan() {
        pending = []
        candidateRepos = []
        attempted = []
        admitted = []
        candidateScope = ""
        updateCoverage()
    }

    /// 扫描按 200 仓库分批，用户可继续下一批；失败项只通过详情显式重试，避免限流循环。
    func scanNextBatch() {
        isPaused = false
        admitted = []
        paginationRevision &+= 1
        enqueue(candidateRepos, scope: candidateScope)
    }

    /// 去重详情与后台的同仓请求；刷新后失败状态持久为 unknown，不沿用过期“无 Skill”。
    @discardableResult
    func detect(
        _ repo: Repo,
        force: Bool = false,
        onUpdate: (@MainActor @Sendable (RepoSkillScan) -> Void)? = nil
    ) async throws -> RepoSkillScan {
        let requestedEpoch = epoch
        await prepare()
        guard !isChangingAccount, requestedEpoch == epoch else { throw CancellationError() }
        remember(repo)
        let source = withKnownMetadata(repo)
        try Task.checkCancellation()
        // 先检查进行中的任务，不能把内存 partial 当成已结束的缓存返回给新窗口。
        if let task = inflight[repo.id], !task.isCancelled {
            return try await consume(task, repositoryID: repo.id, onUpdate: onUpdate)
        }
        if !force, !scanningIDs.contains(repo.id), let value = scans[repo.id],
           value.isFresh(for: source), errors[repo.id] == nil { return value }
        let expected = epoch
        let writer = database.writer
        let token = UUID()
        // 关窗后立即重开时，上一轮取消可能尚未收尾；它的 partial 不能成为新扫描的缓存回退。
        let previousScan = scanningIDs.contains(repo.id) ? nil : scans[repo.id]
        let api = repo.isPrivate ? privateAPI : publicAPI
        let scanner = RepoSkillScanner(
            api: api, downloader: repo.isPrivate ? privateDownloader : publicDownloader,
            cacheScope: api.fileTreeCacheScope
        )
        scanningIDs.insert(repo.id)
        scanTokens[repo.id] = token
        errors[repo.id] = nil
        let task = Task {
            defer {
                if self.epoch == expected, self.scanTokens[repo.id] == token {
                    self.scanningIDs.remove(repo.id)
                    self.inflight[repo.id] = nil
                    self.updateHandlers[repo.id] = nil
                    self.consumers[repo.id] = nil
                    self.scanTokens[repo.id] = nil
                }
            }
            do {
                let value = try await scanner.scan(
                    source, treeBudget: force ? 256 : 64, manifestBudget: force ? 1_000 : 200
                ) { value in
                    Task { @MainActor [weak self] in
                        self?.publishPartial(value, repositoryID: repo.id, epoch: expected, token: token)
                    }
                }
                try Task.checkCancellation()
                guard self.epoch == expected, self.scanTokens[repo.id] == token else { throw CancellationError() }
                let data = try await Self.encode(value)
                try Task.checkCancellation()
                try await writer.write { db in
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO repo_skill_scans
                        (repo_id, commit_sha, pushed_at, branch, rules_version, expires_at, presence, payload)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            repo.id, value.commitSHA, value.sourcePushedAt, value.sourceBranch, value.version,
                            value.checkedAt.addingTimeInterval(86_400).timeIntervalSince1970, value.presence.rawValue, data
                        ])
                }
                guard self.epoch == expected, self.scanTokens[repo.id] == token else { throw CancellationError() }
                self.scanSnapshots[repo.id] = value
                self.updateCoverage()
                // 最终落库只发一次全局修订，供 SQL Skill 筛选重新取稳定分页。
                self.revision &+= 1
                return value
            } catch {
                guard self.epoch == expected, self.scanTokens[repo.id] == token else { throw CancellationError() }
                if Task.isCancelled || error is CancellationError {
                    let previousPresence = self.presence(for: source)
                    self.scanSnapshots[repo.id] = previousScan
                    if previousPresence != self.presence(for: source) { self.revision &+= 1 }
                } else {
                    self.errors[repo.id] = error.localizedDescription
                    try? await writer.write { db in
                        try db.execute(sql: "DELETE FROM repo_skill_scans WHERE repo_id = ?", arguments: [repo.id])
                    }
                    guard self.epoch == expected, self.scanTokens[repo.id] == token else { throw CancellationError() }
                    self.scanSnapshots[repo.id] = nil
                    self.revision &+= 1
                }
                throw error
            }
        }
        inflight[repo.id] = task
        return try await consume(task, repositoryID: repo.id, onUpdate: onUpdate)
    }

    /// 每个窗口/后台队列拥有独立订阅；最后一个消费者离开才取消共享请求。
    /// 取消回调只投递 MainActor 清理，不能跨隔离域直接修改观察状态。
    private func consume(
        _ task: Task<RepoSkillScan, Error>, repositoryID: Int64,
        onUpdate: (@MainActor @Sendable (RepoSkillScan) -> Void)?
    ) async throws -> RepoSkillScan {
        let consumer = UUID()
        consumers[repositoryID, default: []].insert(consumer)
        if let onUpdate {
            updateHandlers[repositoryID, default: [:]][consumer] = onUpdate
            if let partial = scans[repositoryID], !partial.complete { onUpdate(partial) }
        }
        return try await withTaskCancellationHandler {
            defer { releaseConsumer(consumer, repositoryID: repositoryID) }
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseConsumer(consumer, repositoryID: repositoryID) }
        }
    }

    private func releaseConsumer(_ consumer: UUID, repositoryID: Int64) {
        guard consumers[repositoryID]?.remove(consumer) != nil else { return }
        updateHandlers[repositoryID]?[consumer] = nil
        if consumers[repositoryID]?.isEmpty == true { inflight[repositoryID]?.cancel() }
    }

    /// 大正文和文件清单的 JSON 编码必须在通用执行器完成，主线程只提交数据库异步写入。
    @concurrent private nonisolated static func encode(_ value: RepoSkillScan) async throws -> Data {
        try Task.checkCancellation()
        return try JSONEncoder().encode(value)
    }

    func downloader(for repo: Repo) -> any RepoFileDownloading {
        repo.isPrivate ? privateDownloader : publicDownloader
    }

    /// 必须在切库前调用；任务捕获旧 writer，取消并推进代际后不会把私仓数据发布给新账号。
    func resetForAccountChange() async {
        isChangingAccount = true
        epoch &+= 1
        worker?.cancel()
        worker = nil
        inflight.values.forEach { $0.cancel() }
        inflight = [:]
        loadTask?.cancel()
        loadTask = nil
        let activeInstallations = Array(installations.values)
        activeInstallations.forEach { $0.cancel() }
        // 发布事务完成或 staging 清理结束后才允许切库，不能只依赖窗口稍后消失。
        for task in activeInstallations { await task.value }
        installations = [:]
        updateHandlers = [:]
        consumers = [:]
        scanTokens = [:]
        pending = []
        candidateRepos = []
        attempted = []
        admitted = []
        candidateScope = ""
        scanSnapshots = [:]
        knownRepos = [:]
        errors = [:]
        scanningIDs = []
        loadedAccount = nil
        candidateCount = 0
        processedCount = 0
        remainingCount = 0
        isPaused = false
        revision &+= 1
    }

    func finishAccountChange() { isChangingAccount = false }

    func trackInstallation(_ task: Task<Void, Never>, id: UUID) { installations[id] = task }
    func finishInstallation(id: UUID) { installations[id] = nil }

    private func attemptKey(_ repo: Repo) -> String {
        "\(repo.id):\(repo.pushedAt ?? ""):\(repo.defaultBranch ?? "")"
    }

    /// 部分结果只进入内存和 UI，最终落库仍由 scan 完成后的主路径处理。
    private func publishPartial(_ value: RepoSkillScan, repositoryID: Int64, epoch expected: UInt64, token: UUID) {
        guard epoch == expected, scanTokens[repositoryID] == token, !isChangingAccount,
              inflight[repositoryID]?.isCancelled == false, repositoryID == value.repositoryID else { return }
        if let current = scans[repositoryID], current.commitSHA == value.commitSHA,
           (current.manifestChecked ?? 0) > (value.manifestChecked ?? 0) { return }
        let previous = presence(repositoryID: repositoryID)
        scanSnapshots[repositoryID] = value
        // manifest 数量和正文属于详情进度；主列表只关心 unknown/contains/absent 的变化。
        if previous != presence(repositoryID: repositoryID) {
            updateCoverage()
            revision &+= 1
        }
        updateHandlers[repositoryID]?.values.forEach { $0(value) }
    }

    /// 摘要型来源缺字段时保留已知元数据，使按 ID 的筛选和详情采用同一新鲜度判断。
    private func remember(_ repo: Repo) {
        let previous = presence(repositoryID: repo.id)
        knownRepos[repo.id] = withKnownMetadata(repo)
        if previous != presence(repositoryID: repo.id) { revision &+= 1 }
    }

    private func withKnownMetadata(_ repo: Repo) -> Repo {
        var value = repo
        if let old = knownRepos[repo.id] {
            value.pushedAt = repo.pushedAt ?? old.pushedAt
            value.defaultBranch = repo.defaultBranch ?? old.defaultBranch
            if let latest = old.pushedAt, let incoming = repo.pushedAt, latest > incoming {
                value.pushedAt = latest
                value.defaultBranch = old.defaultBranch ?? repo.defaultBranch
            }
        }
        return value
    }

    private func updateCoverage() {
        candidateCount = candidateRepos.count
        processedCount = candidateRepos.filter {
            presence(for: $0) != .unknown || attempted.contains(attemptKey($0))
        }.count
        remainingCount = pending.count
    }

    private func runWorkerIfNeeded() {
        guard worker == nil, !isPaused, !pending.isEmpty else { return }
        let expected = epoch
        worker = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty, !self.isPaused, !Task.isCancelled, self.epoch == expected {
                let repo = self.pending.removeFirst()
                let scope = self.candidateScope
                self.attempted.insert(self.attemptKey(repo))
                do {
                    try await self.detect(repo)
                } catch {
                    // 遇限流/权限失败先停队列，用户可以恢复；不把数百个后续请求一起打出去。
                    if self.epoch == expected, self.candidateScope == scope, !Task.isCancelled {
                        self.isPaused = true
                    }
                }
                guard self.epoch == expected else { return }
                self.updateCoverage()
                try? await Task.sleep(for: .milliseconds(400))
            }
            if self.epoch == expected { self.worker = nil }
        }
    }
}
