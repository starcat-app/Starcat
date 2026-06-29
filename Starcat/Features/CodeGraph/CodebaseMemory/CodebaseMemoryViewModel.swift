//
//  CodebaseMemoryViewModel.swift
//  Starcat
//
//  驱动分支加载、版本检查、共享 ZIP、持久解压、codebase 二进制索引、UI 子进程启动、浏览器打开。
//  7 步状态机: resolveBinary → resolveRevision → download → extract → index → startUI → openBrowser
//
//  对齐 CodeFlowViewModel 的骨架（状态机 / VersionStatus / Pro gating / 步骤追踪）。

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CodebaseMemoryViewModel {

    // MARK: - State

    enum State: Equatable {
        case idle
        case preparing
        case downloading
        case extracting
        case indexing
        case startingUI
        case ready(port: Int, pageURL: URL)
        case succeeded
        case failed(message: String)
    }

    enum VersionStatus: Equatable {
        case unknown
        case checking
        case current
        case updateAvailable(generated: String, latest: String)
        case branchChanged(generated: String, selected: String)
        case unavailable(String)
    }

    // MARK: - Properties

    private(set) var state: State = .idle
    private(set) var branches: [CodeFlowBranch] = []
    private(set) var isLoadingBranches = false
    private(set) var versionStatus: VersionStatus = .unknown
    private(set) var storedProject: CodebaseMemoryStoredProject?
    private(set) var steps: [CodebaseMemoryExecutionStep] = CodebaseMemoryViewModel.emptySteps()
    var selectedBranchName = "" {
        didSet { updateSelectionVersionStatus() }
    }

    var paywallContext: ProPaywallContext?

    /// repo 由 sheet item 驱动；Panel 重建后通常与 init 参数一致。
    /// 仍保留可变字段，让 `refreshRepo(repo:)` 在 SwiftUI 复用 presentation host 时能做二次校准。
    private var repo: Repo
    private let runner: CodebaseMemoryRunner
    private let storage: CodebaseMemoryStorage
    private let binaryResolver: CodebaseMemoryBinaryResolver
    private let extractor: CodebaseMemoryExtractor
    private let snapshotService: SharedSnapshotService

    private var task: Task<Void, Never>?
    private var uiProcess: Process?

    var canGenerate: Bool {
        !selectedBranchName.isEmpty
            && branches.contains(where: { $0.name == selectedBranchName })
            && !isLoadingBranches
    }

    var isRunning: Bool {
        switch state {
        case .preparing, .downloading, .extracting, .indexing, .startingUI:
            return true
        default:
            return false
        }
    }

    // MARK: - Init

    init(
        repo: Repo,
        runner: CodebaseMemoryRunner = CodebaseMemoryRunner(),
        storage: CodebaseMemoryStorage = .shared,
        binaryResolver: CodebaseMemoryBinaryResolver? = nil,
        extractor: CodebaseMemoryExtractor = CodebaseMemoryExtractor(),
        snapshotService: SharedSnapshotService = SharedSnapshotService()
    ) {
        self.repo = repo
        self.runner = runner
        self.storage = storage
        self.binaryResolver = binaryResolver ?? CodebaseMemoryBinaryResolver(storage: storage)
        self.extractor = extractor
        self.snapshotService = snapshotService
        // 不在 init 跑 IO：macOS .sheet(item:) 复用 view + State,
        // init 里的 restoreCachedState 只会跑一次(用旧 repo 数据)
        // restoreCachedState() 移到 .task 由 SwiftUI 调起,每次 panel 显示都重查
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard branches.isEmpty, !isLoadingBranches else { return }
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        do {
            let loaded = try await snapshotService.branches(repo: repo)
            branches = sortBranches(loaded)
            if selectedBranchName.isEmpty {
                selectedBranchName = storedProject?.metadata.sourceRevision.branch
                    ?? repo.defaultBranch
                    ?? branches.first?.name
                    ?? ""
            }
            await checkSelectedBranchVersion()
        } catch {
            versionStatus = .unavailable(error.localizedDescription)
        }
    }

    func selectBranch(_ name: String) {
        selectedBranchName = name
        Task { await checkSelectedBranchVersion() }
    }

    /// 当 Sheet 切换到不同 repo 时, 主动清空旧状态 + 按新 repo 重新查 cached。
    /// SwiftUI 在 .sheet(item:) 复用 State 时, init 不会重跑, 用此方法做兜底。
    func reloadForNewRepo() {
        stopCurrentUI()
        branches = []
        isLoadingBranches = false
        versionStatus = .unknown
        selectedBranchName = ""
        steps = Self.emptySteps()
        restoreCachedState()
    }

    /// Panel `.task` 调用: 每次 panel 显示都重查 cached state + branches。
    /// 用于解决 macOS sheet 复用 view 导致 init 不重跑、cached state 停留在旧 repo 的问题。
    func restoreCachedStateForCurrentRepo() {
        restoreCachedState()
        branches = []
        isLoadingBranches = false
        versionStatus = .unknown
    }

    /// 真根因修复: Panel 的 @State repo 已更新, ViewModel 内部的 repo 字段也同步
    /// 替换, 然后按新 repo 重新查 storedProject + 清空 branches。
    func refreshRepo(repo: Repo) {
        stopCurrentUI()
        // 新 repo 替换 init 时捕获的旧 repo
        self.repo = repo
        // 清空所有跟旧 repo 相关的状态, 然后用新 repo 重新查
        branches = []
        isLoadingBranches = false
        versionStatus = .unknown
        selectedBranchName = ""
        steps = Self.emptySteps()
        state = .idle
        restoreCachedState()
    }

    func start() {
        task?.cancel()
        AppLog.ui.info("CodebaseMemory start requested repo=\(self.repo.fullName, privacy: .public) state=\(String(describing: self.state), privacy: .public) stored=\(self.storedProject?.id ?? "nil", privacy: .public) uiRunning=\((self.uiProcess?.isRunning ?? false), privacy: .public)")
        // `ready/succeeded` 只代表本次 ViewModel 持有一个仍在运行的 UI 进程。
        // 历史 metadata 里的 lastUIPort 不能作为运行态依据，因为用户关闭窗口、
        // App 重启或旧版本崩溃后，端口记录仍会留在磁盘上。
        if case .ready(let port, let pageURL) = state,
           let proc = uiProcess,
           proc.isRunning {
            AppLog.ui.info("CodebaseMemory opening existing ready UI repo=\(self.repo.fullName, privacy: .public) port=\(port, privacy: .public) url=\(pageURL.absoluteString, privacy: .public)")
            task = Task { await openBrowser(port: port, url: pageURL) }
            return
        }
        if case .succeeded = state,
           let project = storedProject,
           let port = project.metadata.lastUIPort,
           let proc = uiProcess,
           proc.isRunning {
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            AppLog.ui.info("CodebaseMemory reopening succeeded UI repo=\(self.repo.fullName, privacy: .public) port=\(port, privacy: .public) url=\(url.absoluteString, privacy: .public)")
            task = Task { await openBrowser(port: port, url: url) }
            return
        }
        generate(removingExisting: false)
    }

    func regenerate() {
        task?.cancel()
        stopCurrentUI()
        generate(removingExisting: true)
    }

    func cancel() {
        task?.cancel()
        task = nil
        // 不杀 UI 进程 — 用户继续在浏览器交互
        restoreCachedState()
    }

    // MARK: - 生成管线

    private func generate(removingExisting: Bool) {
        guard !selectedBranchName.isEmpty else {
            state = .failed(message: String.l10n("codeFlow.error.branchMissing"))
            return
        }

        task = Task {
            let startedAt = Date()
            steps = Self.emptySteps()
            do {
                // Step 0: 解析二进制（bundle → container 拷贝 + chmod）
                setStep(id: .resolveBinary, status: .running)
                // Pro check done in RepoListView.openCodebaseMemory() before sheet present
                let binaryURL: URL
                do {
                    binaryURL = try await binaryResolver.resolveExecutable()
                    setStep(id: .resolveBinary, status: .succeeded, detail: binaryURL.lastPathComponent)
                } catch {
                    setStep(id: .resolveBinary, status: .failed, detail: error.localizedDescription)
                    state = .failed(message: error.localizedDescription)
                    return
                }

                // Step 1: 解析分支 → commit SHA
                setStep(id: .resolveRevision, status: .running, detail: selectedBranchName)
                let branch = try await runStep(id: .resolveRevision) {
                    try await snapshotService.resolveBranch(repo: repo, name: selectedBranchName)
                } successDetail: { "\($0.name) · \($0.shortSHA)" }

                // Step 2: 缓存命中判定
                if !removingExisting,
                   let existing = try? storage.existingProject(owner: repo.owner, name: repo.name),
                   existing.metadata.sourceRevision.commitSHA == branch.commitSHA {
                    let root = try storage.outputRootURL()
                    let cacheDir = storage.projectCacheDirectory(root: root, owner: repo.owner, name: repo.name)
                    AppLog.ui.info("CodebaseMemory cache-hit candidate repo=\(self.repo.fullName, privacy: .public) cache=\(cacheDir.path, privacy: .public) lastPort=\(existing.metadata.lastUIPort ?? -1, privacy: .public)")
                    if runner.hasIndexedProjectCache(cacheDir: cacheDir) {
                        // 全部跳过 → 直接 openBrowser
                        steps.forEach { step in
                            if step.id != .resolveBinary, step.id != .resolveRevision {
                                setStep(id: step.id, status: .skipped)
                            }
                        }
                        let port = existing.metadata.lastUIPort ?? pickPort()
                        let pageURL = URL(string: "http://127.0.0.1:\(port)/")!
                        // 如果旧 UI 进程还在，直接打开；否则 start up
                        if uiProcess == nil || uiProcess?.isRunning == false {
                            state = .startingUI
                            setStep(id: .startUI, status: .running, detail: "localhost:\(port)")
                            let launched = try await runner.startVerifiedUI(
                                binaryURL: binaryURL,
                                port: port,
                                cacheDir: cacheDir,
                                repositoryFullName: repo.fullName
                            )
                            uiProcess = launched.process
                            AppLog.ui.info("CodebaseMemory cache-hit UI launched repo=\(self.repo.fullName, privacy: .public) pid=\(launched.process.processIdentifier, privacy: .public) port=\(port, privacy: .public)")
                            setStep(id: .startUI, status: .succeeded)
                        }
                        guard uiProcess != nil else {
                            state = .failed(message: CodebaseMemoryError.uiStartFailed(underlying: "missing UI process").localizedDescription)
                            return
                        }
                        await openBrowser(port: port, url: pageURL)
                        return
                    }
                    // metadata 命中但 per-repo cache 缺项目 DB 时，继续走完整生成管线。
                    // 这是旧共享 cache 迁移到 repo 独立 cache 后的兜底，不能打开空/旧 UI。
                }

                try Task.checkCancellation()

                // Step 3: 拉 zipball（共享缓存，秒过）
                state = .downloading
                setStep(id: .download, status: .running)
                let archive = try await snapshotService.archiveIfNeeded(repo: repo, commitSHA: branch.commitSHA)
                let byteText = ByteCountFormatter.string(fromByteCount: archive.bytes, countStyle: .file)
                setStep(id: .download, status: .succeeded, detail: archive.wasDownloaded
                    ? String(format: String.l10n("codeFlow.runtime.cachedZipFormat"), byteText)
                    : String(format: String.l10n("codeFlow.runtime.downloadedZipFormat"), byteText))

                try Task.checkCancellation()

                // Step 4: 持久解压
                state = .extracting
                setStep(id: .extract, status: .running)
                let root = try storage.outputRootURL()
                let outDir = storage.projectDirectory(root: root, owner: repo.owner, name: repo.name)
                let source = try await extractor.extractIfNeeded(zipURL: archive.url, outputDirectory: outDir)
                setStep(id: .extract, status: .succeeded,
                        detail: source.wasCached ? "cached" : "extracted")

                try Task.checkCancellation()

                // Step 5: 索引
                state = .indexing
                setStep(id: .index, status: .running)
                let cacheDir = storage.projectCacheDirectory(root: root, owner: repo.owner, name: repo.name)
                AppLog.ui.info("CodebaseMemory indexing complete repo=\(self.repo.fullName, privacy: .public) cache=\(cacheDir.path, privacy: .public)")
                let indexResult = try await runner.runIndex(
                    binaryURL: binaryURL, repoPath: source.sourceURL, cacheDir: cacheDir
                )
                if !indexResult.errors.isEmpty {
                    setStep(id: .index, status: .succeeded,
                            detail: "\(indexResult.nodeCount) nodes, \(indexResult.edgeCount) edges, \(indexResult.errors.count) warnings")
                } else {
                    setStep(id: .index, status: .succeeded,
                            detail: "\(indexResult.nodeCount) nodes, \(indexResult.edgeCount) edges")
                }

                try Task.checkCancellation()

                // Step 6: 启动 UI
                state = .startingUI
                let port = pickPort()
                setStep(id: .startUI, status: .running, detail: "localhost:\(port)")
                let launched = try await runner.startVerifiedUI(
                    binaryURL: binaryURL,
                    port: port,
                    cacheDir: cacheDir,
                    repositoryFullName: repo.fullName
                )
                uiProcess = launched.process
                AppLog.ui.info("CodebaseMemory UI launched repo=\(self.repo.fullName, privacy: .public) pid=\(launched.process.processIdentifier, privacy: .public) port=\(port, privacy: .public) url=\(launched.pageURL.absoluteString, privacy: .public)")
                setStep(id: .startUI, status: .succeeded)

                // Step 7: 保存 metadata
                let metadata = CodebaseMemoryMetadata(
                    schemaVersion: 1,
                    repository: .init(
                        githubID: repo.id, owner: repo.owner, name: repo.name,
                        fullName: repo.fullName, htmlURL: repo.htmlUrl
                    ),
                    sourceRevision: .init(
                        branch: branch.name, commitSHA: branch.commitSHA,
                        commitURL: "https://github.com/\(repo.owner)/\(repo.name)/commit/\(branch.commitSHA)"
                    ),
                    lastIndexing: .init(
                        startedAt: startedAt, finishedAt: Date(),
                        durationMs: Int(-startedAt.timeIntervalSinceNow * 1_000),
                        steps: steps,
                        indexedNodeCount: indexResult.nodeCount,
                        indexedEdgeCount: indexResult.edgeCount
                    ),
                    generation: .init(
                        generatedAt: Date(),
                        generationCount: (storedProject?.metadata.generation.generationCount ?? 0) + 1
                    ),
                    binaryVersion: "0.0.0",  // 后续从 STARCAT-INTEGRATION.md 读取
                    binarySHA256: "",
                    lastUIPort: port
                )
                _ = try storage.write(metadata: metadata, owner: repo.owner, name: repo.name)

                // 把写盘的 metadata 重新读回 storedProject, footerStatus 才能显示正确的 generationCount
                storedProject = try? storage.existingProject(owner: repo.owner, name: repo.name)

                // Step 8: 打开浏览器
                await openBrowser(port: port, url: launched.pageURL)
            } catch is CancellationError {
                restoreCachedState()
            } catch {
                stopCurrentUI()
                markRunningStepFailed(error.localizedDescription)
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Private helpers

    private func openBrowser(port: Int, url: URL) async {
        AppLog.ui.info("CodebaseMemory openBrowser begin repo=\(self.repo.fullName, privacy: .public) port=\(port, privacy: .public) url=\(url.absoluteString, privacy: .public)")
        setStep(id: .openBrowser, status: .running, detail: "localhost:\(port)")
        do {
            try await openURLInDefaultBrowser(url)
        } catch {
            let message = error.localizedDescription
            AppLog.ui.error("CodebaseMemory openBrowser failed repo=\(self.repo.fullName, privacy: .public) port=\(port, privacy: .public) error=\(message, privacy: .public)")
            setStep(id: .openBrowser, status: .failed, detail: message)
            state = .failed(message: CodebaseMemoryError.browserOpenFailed(underlying: message).localizedDescription)
            return
        }
        setStep(id: .openBrowser, status: .succeeded, detail: "localhost:\(port)")
        state = .succeeded
        AppLog.ui.info("CodebaseMemory openBrowser succeeded repo=\(self.repo.fullName, privacy: .public) port=\(port, privacy: .public)")
    }

    /// 显式交给系统默认浏览器打开，并要求激活前台应用。
    ///
    /// 直接 `NSWorkspace.shared.open(url)` 在部分默认浏览器 / Launch Services 状态下只返回
    /// “请求已提交”，但不会稳定拉起窗口。这里先解析默认浏览器，再用带 completion 的
    /// API 获取明确结果；解析不到默认浏览器时才退回原始 open 作为兜底。
    private func openURLInDefaultBrowser(_ url: URL) async throws {
        let workspace = NSWorkspace.shared
        guard let browserURL = workspace.urlForApplication(toOpen: url) else {
            AppLog.ui.warning("CodebaseMemory browser app unresolved, fallback open url=\(url.absoluteString, privacy: .public)")
            guard workspace.open(url) else {
                throw CodebaseMemoryError.browserOpenFailed(underlying: "NSWorkspace.open returned false")
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        AppLog.ui.info("CodebaseMemory opening browser url=\(url.absoluteString, privacy: .public) app=\(browserURL.path, privacy: .public)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            workspace.open(
                [url],
                withApplicationAt: browserURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    AppLog.ui.error("CodebaseMemory browser open failed url=\(url.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    AppLog.ui.info("CodebaseMemory browser open handed off url=\(url.absoluteString, privacy: .public)")
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func stopCurrentUI() {
        if let proc = uiProcess {
            runner.stopUI(proc)
        }
        uiProcess = nil
    }

    private func pickPort() -> Int {
        let range = 40000..<50000
        // 先试上次的端口
        if let previous = storedProject?.metadata.lastUIPort,
           CodebaseMemoryPortAvailability.unavailableMessage(for: previous) == nil {
            return previous
        }
        // 随机碰撞最多 16 次
        for _ in 0..<16 {
            let candidate = Int.random(in: range)
            if CodebaseMemoryPortAvailability.unavailableMessage(for: candidate) == nil {
                return candidate
            }
        }
        return 41934 // 兜底
    }

    private func runStep<T>(
        id: CodebaseMemoryExecutionStep.ID,
        block: () async throws -> T,
        successDetail: (T) -> String
    ) async throws -> T {
        let startedAt = Date()
        do {
            let value = try await block()
            setStep(id: id, status: .succeeded, detail: successDetail(value),
                    durationMs: Int(-startedAt.timeIntervalSinceNow * 1_000))
            return value
        } catch {
            setStep(id: id, status: .failed, detail: error.localizedDescription)
            throw error
        }
    }

    private func setStep(
        id: CodebaseMemoryExecutionStep.ID,
        status: CodebaseMemoryExecutionStep.Status = .running,
        detail: String? = nil,
        durationMs: Int? = nil
    ) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        var updated = steps[index]
        updated.status = status
        if let detail { updated.detail = detail }
        if let durationMs { updated.durationMilliseconds = durationMs }
        steps[index] = updated
    }

    private func markRunningStepFailed(_ message: String) {
        for i in steps.indices where steps[i].status == .running {
            steps[i].status = .failed
            steps[i].detail = message
        }
    }

    private func restoreCachedState() {
        do {
            if let project = try storage.existingProject(owner: repo.owner, name: repo.name) {
                storedProject = project
                selectedBranchName = project.metadata.sourceRevision.branch
                steps = normalizedCachedSteps(project.metadata.lastIndexing.steps)
                // metadata 只能证明索引产物存在，不能证明 UI server 还活着。
                // 因此恢复缓存时保持 idle；用户点击打开时会重新写 per-repo
                // config.json、拉起 codebase 长进程并等待端口真实监听。
                state = .idle
            } else {
                storedProject = nil
                state = .idle
                steps = Self.emptySteps()
            }
        } catch {
            storedProject = nil
            state = .failed(message: error.localizedDescription)
            steps = Self.emptySteps()
        }
    }

    private func normalizedCachedSteps(_ cachedSteps: [CodebaseMemoryExecutionStep]) -> [CodebaseMemoryExecutionStep] {
        cachedSteps.map { step in
            guard step.id == .startUI || step.id == .openBrowser else { return step }
            var updated = step
            updated.status = .pending
            updated.detail = nil
            updated.durationMilliseconds = nil
            return updated
        }
    }

    private func checkSelectedBranchVersion() async {
        guard let project = storedProject, !selectedBranchName.isEmpty else {
            versionStatus = .unknown
            return
        }
        let generatedBranch = project.metadata.sourceRevision.branch
        guard selectedBranchName == generatedBranch else {
            versionStatus = .branchChanged(generated: generatedBranch, selected: selectedBranchName)
            return
        }
        versionStatus = .checking
        do {
            let latest = try await snapshotService.resolveBranch(repo: repo, name: selectedBranchName)
            let generatedSHA = project.metadata.sourceRevision.commitSHA
            versionStatus = latest.commitSHA == generatedSHA
                ? .current
                : .updateAvailable(generated: String(generatedSHA.prefix(7)), latest: latest.shortSHA)
        } catch {
            versionStatus = .unavailable(error.localizedDescription)
        }
    }

    private func updateSelectionVersionStatus() {
        guard let project = storedProject, !selectedBranchName.isEmpty,
              selectedBranchName != project.metadata.sourceRevision.branch else { return }
        versionStatus = .branchChanged(
            generated: project.metadata.sourceRevision.branch,
            selected: selectedBranchName
        )
    }

    private func sortBranches(_ values: [CodeFlowBranch]) -> [CodeFlowBranch] {
        let generated = storedProject?.metadata.sourceRevision.branch
        return values.sorted {
            if $0.name == generated { return true }
            if $1.name == generated { return false }
            return $0.name < $1.name
        }
    }

    static func emptySteps() -> [CodebaseMemoryExecutionStep] {
        CodebaseMemoryExecutionStep.ID.allCases.map {
            CodebaseMemoryExecutionStep(id: $0, status: .pending)
        }
    }
}
