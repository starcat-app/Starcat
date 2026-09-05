//
//  AmbientViewModel.swift
//  Starcat
//
//  Ambient 的 MainActor 状态边界：负责 Catalog 加载代际、纯值 Engine 推进、
//  Reduce Motion / 窗口活性暂停，以及下一张 artwork 的有界预取。
//

import Foundation
import Observation

/// 不向 UI 暴露数据库路径、SQL 或底层错误文本的失败类别。
enum AmbientLoadFailure: Equatable, Sendable {
    case repositoryUnavailable
}

/// Ambient 根视图的互斥加载状态。
enum AmbientLoadState: Equatable, Sendable {
    case idle
    case loading
    case empty
    case loaded([AmbientSlotSnapshot])
    case failed(AmbientLoadFailure)
}

/// Catalog 和 Engine 的窗口级所有者。
@MainActor
@Observable
final class AmbientViewModel {
    typealias NowProvider = @MainActor @Sendable () -> TimeInterval
    typealias SleepProvider = @MainActor @Sendable (TimeInterval) async throws -> Void

    private(set) var state: AmbientLoadState = .idle
    private(set) var changedSlotIDs: Set<Int> = []
    private(set) var requestedScene: AmbientSceneKind
    private(set) var activeScene: AmbientSceneKind?
    private(set) var isSchedulerRunning = false

    @ObservationIgnored private let catalog: any AmbientCatalogProviding
    @ObservationIgnored private let prefetcher: any AmbientImagePrefetching
    @ObservationIgnored private let now: NowProvider
    @ObservationIgnored private let sleep: SleepProvider
    @ObservationIgnored private let randomSeed: @MainActor @Sendable () -> UInt64

    @ObservationIgnored private var engine: AmbientGridEngine?
    @ObservationIgnored private var currentLayout: AmbientGridLayout?
    @ObservationIgnored private var currentReduceMotion = false
    @ObservationIgnored private var isWindowActive = true
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

    init(
        catalog: any AmbientCatalogProviding,
        initialScene: AmbientSceneKind = .repos,
        prefetcher: any AmbientImagePrefetching = AmbientImagePrefetcher(),
        now: @escaping NowProvider = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping SleepProvider = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        randomSeed: @escaping @MainActor @Sendable () -> UInt64 = {
            UInt64.random(in: UInt64.min...UInt64.max)
        }
    ) {
        self.catalog = catalog
        requestedScene = initialScene
        self.prefetcher = prefetcher
        self.now = now
        self.sleep = sleep
        self.randomSeed = randomSeed
    }

    /// 加载 scene + layout 的新代际。旧 I/O 即使忽略 cancellation 迟到，也不能覆盖新状态。
    func load(scene: AmbientSceneKind, layout: AmbientGridLayout, reduceMotion: Bool) {
        requestedScene = scene
        let isSameIdentity = activeScene == scene && currentLayout == layout
        currentReduceMotion = reduceMotion
        if isSameIdentity, case .loaded = state {
            restartSchedulerForCurrentPolicy()
            return
        }

        generation &+= 1
        let requestedGeneration = generation
        activeScene = scene
        currentLayout = layout
        state = .loading
        changedSlotIDs = []
        engine = nil
        loadTask?.cancel()
        stopScheduler()
        prefetcher.cancel()

        loadTask = Task { [weak self, catalog] in
            do {
                let cards = try await catalog.loadCards(scene: scene)
                try Task.checkCancellation()
                guard let self, self.generation == requestedGeneration,
                      self.activeScene == scene, self.currentLayout == layout else { return }
                self.install(cards: cards, layout: layout)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == requestedGeneration,
                      self.activeScene == scene, self.currentLayout == layout else { return }
                AppLog.ui.error("Ambient catalog load failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(.repositoryUnavailable)
                self.engine = nil
                self.stopScheduler()
                self.prefetcher.cancel()
            }
        }
    }

    /// SwiftUI geometry 首次稳定或 debounce 后调用，按当前菜单请求场景建立新代际。
    func configure(layout: AmbientGridLayout, reduceMotion: Bool) {
        load(scene: requestedScene, layout: layout, reduceMotion: reduceMotion)
    }

    /// 同一全屏窗口切换 Repo / Owner，不创建第二套窗口状态。
    func switchScene(_ scene: AmbientSceneKind) {
        guard requestedScene != scene else { return }
        requestedScene = scene
        guard let layout = currentLayout else { return }
        load(scene: scene, layout: layout, reduceMotion: currentReduceMotion)
    }

    func retry() {
        guard let scene = activeScene, let layout = currentLayout else { return }
        // 清掉 identity，让重试不会被 loaded 快路径短路。
        activeScene = nil
        load(scene: scene, layout: layout, reduceMotion: currentReduceMotion)
    }

    func updateReduceMotion(_ reduceMotion: Bool) {
        guard currentReduceMotion != reduceMotion else { return }
        currentReduceMotion = reduceMotion
        restartSchedulerForCurrentPolicy()
    }

    func setWindowActive(_ active: Bool) {
        guard isWindowActive != active else { return }
        isWindowActive = active
        if active {
            advanceAndPublish(at: now())
            restartSchedulerForCurrentPolicy()
        } else {
            stopScheduler()
        }
    }

    /// 关闭窗口或切换账户时统一取消所有长生命周期资源。
    func cancelAll() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        stopScheduler()
        prefetcher.cancel()
        engine = nil
    }

    private func install(cards: [AmbientCardModel], layout: AmbientGridLayout) {
        guard !cards.isEmpty, layout.config.slotCount > 0 else {
            state = .empty
            engine = nil
            stopScheduler()
            prefetcher.cancel()
            return
        }

        let engine = AmbientGridEngine(
            cards: cards,
            config: layout.config,
            now: now(),
            randomSeed: randomSeed()
        )
        self.engine = engine
        changedSlotIDs = []
        state = .loaded(engine.snapshots)
        prefetcher.update(
            snapshots: engine.snapshots,
            tilePointSize: layout.tilePointSize,
            displayScale: layout.displayScale
        )
        restartSchedulerForCurrentPolicy()
    }

    private func restartSchedulerForCurrentPolicy() {
        stopScheduler()
        guard !currentReduceMotion, isWindowActive, engine?.nextDeadline != nil else { return }

        isSchedulerRunning = true
        schedulerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let self, let deadline = self.engine?.nextDeadline else { return }
                    let delay = max(0, deadline - self.now())
                    try await self.sleep(delay)
                    try Task.checkCancellation()
                    self.advanceAndPublish(at: self.now())
                }
            } catch is CancellationError {
                return
            } catch {
                AppLog.ui.error("Ambient scheduler stopped unexpectedly: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopScheduler() {
        schedulerTask?.cancel()
        schedulerTask = nil
        isSchedulerRunning = false
    }

    private func advanceAndPublish(at uptime: TimeInterval) {
        guard var engine else { return }
        let result = engine.advance(now: uptime)
        self.engine = engine
        changedSlotIDs = result.changedSlotIDs
        state = .loaded(result.snapshots)

        if let layout = currentLayout {
            prefetcher.update(
                snapshots: result.snapshots,
                tilePointSize: layout.tilePointSize,
                displayScale: layout.displayScale
            )
        }
    }
}
