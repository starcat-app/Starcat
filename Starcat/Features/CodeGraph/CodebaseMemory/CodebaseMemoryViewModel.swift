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

    private let repo: Repo
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
        restoreCachedState()
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

    func start() {
        task?.cancel()
        if case .ready(let port, let pageURL) = state {
            openBrowser(port: port, url: pageURL)
            return
        }
        if case .succeeded = state,
           let project = storedProject,
           let port = project.metadata.lastUIPort {
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            openBrowser(port: port, url: url)
            return
        }
        generate(removingExisting: false)
    }

    func regenerate() {
        task?.cancel()
        // 杀掉旧 UI 子进程
        if let proc = uiProcess, proc.isRunning {
            proc.terminate()
            uiProcess = nil
        }
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
                    // 全部跳过 → 直接 openBrowser
                    steps.forEach { step in
                        if step.id != .resolveBinary, step.id != .resolveRevision {
                            setStep(id: step.id, status: .skipped)
                        }
                    }
                    let port = existing.metadata.lastUIPort ?? pickPort()
                    // 如果旧 UI 进程还在，直接打开；否则 start up
                    if uiProcess == nil || uiProcess?.isRunning == false {
                        state = .startingUI
                        let cacheDir = try storage.outputRootURL().appendingPathComponent(".internal-cache")
                        setStep(id: .startUI, status: .running, detail: "localhost:\(port)")
                        let proc = try runner.startUI(
                            binaryURL: binaryURL, port: port, cacheDir: cacheDir,
                            repositoryFullName: repo.fullName
                        )
                        uiProcess = proc
                        setStep(id: .startUI, status: .succeeded)
                    }
                    openBrowser(port: port, url: URL(string: "http://127.0.0.1:\(port)/")!)
                    return
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
                let cacheDir = root.appendingPathComponent(".internal-cache")
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
                let proc = try runner.startUI(
                    binaryURL: binaryURL, port: port, cacheDir: cacheDir,
                    repositoryFullName: repo.fullName
                )
                uiProcess = proc

                // 等待 web server 就绪（最多 8 秒，每秒探测一次）
                let pageURL = URL(string: "http://127.0.0.1:\(port)/")!
                let ready = await waitForServer(url: pageURL, timeout: 8)
                if !ready {
                    setStep(id: .startUI, status: .failed, detail: "server did not respond")
                    state = .failed(message: CodebaseMemoryError.uiStartFailed(underlying: "server did not respond on port \(port)").localizedDescription)
                    return
                }
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
                openBrowser(port: port, url: pageURL)
            } catch is CancellationError {
                restoreCachedState()
            } catch {
                markRunningStepFailed(error.localizedDescription)
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Private helpers

    private func openBrowser(port: Int, url: URL) {
        setStep(id: .openBrowser, status: .running, detail: "localhost:\(port)")
        guard NSWorkspace.shared.open(url) else {
            setStep(id: .openBrowser, status: .failed, detail: "localhost:\(port)")
            state = .failed(message: CodebaseMemoryError.browserOpenFailed.localizedDescription)
            return
        }
        setStep(id: .openBrowser, status: .succeeded, detail: "localhost:\(port)")
        state = .succeeded
    }

    /// 轮询等待 HTTP server 就绪，每秒探测一次，超时返回 false。
    private func waitForServer(url: URL, timeout: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode < 500 {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
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
                steps = project.metadata.lastIndexing.steps
                if let port = project.metadata.lastUIPort {
                    state = .ready(port: port, pageURL: URL(string: "http://127.0.0.1:\(port)/")!)
                } else {
                    state = .idle
                }
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
