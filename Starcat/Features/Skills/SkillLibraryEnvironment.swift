//
//  SkillLibraryEnvironment.swift
//  Starcat
//
//  窗口可见期的本机库组合点。刷新始终串行，忙碌期间只累计一次 dirty；
//  文件系统事件是重扫提示，完整扫描报告才是持久化事实。
//

import Foundation

/// UI 调度留在 MainActor，磁盘工作交给 store actor／scanner／watcher。
/// runID 保护关闭再打开的 UI 生命周期，generation 保护独立库提交，二者各有职责。
@MainActor
final class SkillLibraryEnvironment {
    typealias Scanner = @Sendable (SkillScanRequest) async -> SkillScanReport
    typealias Roots = @Sendable ([SkillLibraryRoot]) async -> [SkillLibraryRoot]

    let store: SkillLibraryStore
    let operations: SkillOperationCoordinator
    let imports: SkillImportService
    private weak var viewModel: SkillWorkspaceViewModel?
    private let scan: Scanner
    private let roots: Roots
    private let watcher: any SkillRootWatching
    private let pollInterval: Duration
    private let debounceInterval: Duration
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var runID = UUID()
    private var generation: UUID?
    private var dirty = false
    private var active = false
    private var stateBeforeRefresh: SkillWorkspaceLoadState = .ready
    private var watcherFailure: String?

    /// 注入根与扫描闭包供临时目录回归使用；生产默认值在显式打开窗口后才调用。
    init(
        viewModel: SkillWorkspaceViewModel,
        distributionGate: DistributionGate = DistributionGate(),
        store: SkillLibraryStore? = nil,
        scan: Scanner? = nil,
        roots: Roots? = nil,
        watcher: (any SkillRootWatching)? = nil,
        pollInterval: Duration = .seconds(30),
        debounceInterval: Duration = .milliseconds(300)
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        let store = try store ?? SkillLibraryStore(distributionGate: distributionGate)
        let scanner = try LocalSkillScanner(distributionGate: distributionGate)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        self.store = store
        let operations = try SkillOperationCoordinator(store: store, distributionGate: distributionGate)
        self.operations = operations
        self.imports = try SkillImportService(
            store: store, operations: operations, distributionGate: distributionGate
        )
        self.viewModel = viewModel
        self.scan = scan ?? { await scanner.scan($0) }
        self.roots = roots ?? { previous in
            let detected = await RepoSkillAgentCatalog.detect(home: home, environment: environment)
            return SkillAgentProfile.roots(
                home: home, environment: environment,
                detectedPresets: Set(detected.map(\.preset)),
                previous: previous, managed: store.paths.managed
            )
        }
        self.watcher = try watcher ?? SkillRootWatcher(distributionGate: distributionGate)
        self.pollInterval = pollInterval
        self.debounceInterval = debounceInterval
    }

    /// 幂等开启；重开保留已有列表与导航，但重新检查配置根。
    func start() {
        guard !active else { return }
        active = true
        runID = UUID()
        refresh()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                self?.refresh()
            }
        }
    }

    /// 关闭只停止索引工作；M2 已确认的文件事务由独立操作协调器持有。
    func stop() {
        active = false
        runID = UUID()
        scanTask?.cancel()
        scanTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        watcher.stop()
        dirty = false
        if let generation {
            Task { [store] in await store.invalidateScan(generation: generation) }
        }
        generation = nil
        if viewModel?.loadState == .loading { viewModel?.setLoadState(stateBeforeRefresh) }
    }

    /// 不用“正在刷新则忽略”；一次扫描期间收到任意数量请求都在完成后补扫一次。
    func refresh() {
        guard active else { return }
        if scanTask != nil {
            dirty = true
            return
        }
        let run = runID
        stateBeforeRefresh = viewModel?.loadState ?? .ready
        viewModel?.setLoadState(.loading)
        scanTask = Task { [weak self] in await self?.refresh(run: run) }
    }

    private func refresh(run: UUID) async {
        guard accepts(run) else { return }
        defer {
            if active, runID == run {
                scanTask = nil
                generation = nil
                if dirty {
                    dirty = false
                    refresh()
                }
            }
        }
        do {
            let recovery = await operations.recover()
            guard accepts(run) else { return }
            let cached = try await store.snapshot()
            guard accepts(run) else { return }
            viewModel?.applySnapshot(cached.workspaceItems, state: .loading)
            let configured = await roots(cached.roots)
            guard accepts(run) else { return }
            let generation = await store.beginScan()
            guard accepts(run) else {
                await store.invalidateScan(generation: generation)
                return
            }
            self.generation = generation
            let report = await scan(SkillScanRequest(generationID: generation, roots: configured))
            guard accepts(run) else {
                await store.invalidateScan(generation: generation)
                return
            }
            guard try await store.apply(report), accepts(run) else {
                if accepts(run) { dirty = true }
                return
            }
            let snapshot = try await store.snapshot()
            guard accepts(run) else { return }
            let activeRoots = Set(configured.map(\.id))
            let paths = Set(snapshot.roots.filter { activeRoots.contains($0.id) }
                .flatMap { [$0.configuredPath, $0.resolvedPath].compactMap { $0 } }
                + snapshot.locations.filter {
                    activeRoots.contains($0.rootID) && $0.scanState != .missing
                }.map(\.resolvedPath))
            // 同路径的目录可能已经被重建或换卷；每次对账后重建句柄，
            // 不用路径字符串相等推断系统仍在监听当前目录。
            do {
                try await watcher.start(paths: paths.sorted()) { [weak self] in
                    Task { @MainActor [weak self] in self?.didReceiveEvent(run: run) }
                }
                guard accepts(run) else { return }
                watcherFailure = nil
            } catch {
                guard accepts(run) else { return }
                watcherFailure = error.localizedDescription
            }
            guard accepts(run) else { return }
            let problems = snapshot.roots.filter { !$0.coverage.confirmsAbsence }.map {
                "\($0.configuredPath): \($0.diagnostic ?? $0.coverage.rawValue)"
            } + [watcherFailure].compactMap { $0 }
                + recovery.filter { $0.status == .needsRecovery }.compactMap(\.message)
            let state: SkillWorkspaceLoadState = if problems.isEmpty { .ready }
                else if snapshot.entries.isEmpty { .failed(problems.joined(separator: "\n")) }
                else { .partial(problems.joined(separator: "\n")) }
            viewModel?.applySnapshot(snapshot.workspaceItems, state: state)
        } catch {
            if accepts(run) { viewModel?.setLoadState(.failed(error.localizedDescription)) }
        }
    }

    /// 持续写入也不能饿死补扫：300ms 内只保留一个待执行任务，不反复重置计时。
    private func didReceiveEvent(run: UUID) {
        guard accepts(run), debounceTask == nil else { return }
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            self?.debounceTask = nil
            self?.refresh()
        }
    }

    private func accepts(_ run: UUID) -> Bool { active && runID == run && !Task.isCancelled }

    deinit {
        scanTask?.cancel()
        debounceTask?.cancel()
        pollTask?.cancel()
        watcher.stop()
    }
}

extension SkillLibrarySnapshot {
    /// 先按关系 ID 建索引再投影，避免列表每一行分别查询数据库或重复遍历全库。
    var workspaceItems: [SkillLibraryItem] {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let revisionsByID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: locations, by: \.entryID)
        return entries.map { entry in
            let found = grouped[entry.id, default: []].sorted { $0.lexicalPath < $1.lexicalPath }
            let diagnostics = [entry.diagnostic].compactMap { $0 } + found.compactMap { location in
                location.scanState == .present ? nil : "\(location.scanState.rawValue): \(location.lexicalPath)"
            }
            let source = entry.sourceID.flatMap { sourcesByID[$0] }
            let revision = entry.currentRevisionID.flatMap { revisionsByID[$0] }
            return SkillLibraryItem(
                id: entry.id, name: entry.manifestName, summary: entry.summary,
                managementKind: entry.managementKind,
                source: source.map { [$0.canonicalLocator, $0.subdirectory].filter { !$0.isEmpty }.joined(separator: "/") },
                locations: found.map { location in
                    SkillLibraryLocationSummary(
                        path: location.lexicalPath,
                        agentNames: (rootsByID[location.rootID]?.agentIDs ?? []).map(SkillAgentProfile.displayName),
                        resolvedPath: location.resolvedPath, state: location.scanState
                    )
                },
                diagnostic: diagnostics.isEmpty ? nil : diagnostics.joined(separator: "\n"),
                revision: revision?.upstreamCommit ?? revision?.contentDigest
            )
        }
    }
}
