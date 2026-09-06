//
//  PerformanceTracer.swift
//  Starcat
//
//  Local performance tracing backed by OSSignposter.
//
//  These spans are for Instruments / Points of Interest, not remote analytics.
//  The names are centralized because `OSSignposter` requires `StaticString`;
//  allowing arbitrary runtime strings would either fail to compile or tempt
//  call sites to smuggle user data into signpost names.
//

import Foundation
import OSLog

enum PerformanceSpan: Sendable {
    case appBootstrap
    case manageInitialLoad
    case manageLoadMore
    case manageRoute
    case manageCache
    case manageDatabaseQuery
    case manageDerive
    case managePublish
    case wikiAvailabilityLoad
    case trendingDerive
    case trendingPublish
    case discoveryLocalFilter
    case activityLocalFilter
    case systemSmartCollectionBaseline
    case userSmartCollectionBaseline
    case activityInitialLoad
    case activityLoadMore
    case keywordSearchBaseline
    case semanticSearchBaseline
    case readmeLoad
    case aiStreamResponse
    case repoContextPack
}

/// 用户交互到首帧之间的离散时间点。
///
/// 这里刻意使用固定事件名，不携带仓库、分组或搜索内容；在 Instruments 的 Points of
/// Interest 里用相邻 requested / first_frame 事件即可量出 Sheet 呈现延迟。
enum PerformanceEvent: Sendable {
    case settingsWindowRequested
    case settingsWindowFirstFrame
    case aboutWindowRequested
    case aboutWindowFirstFrame
    case repoDetailSelectionRequested
    case repoDetailFirstFrame
    case readmeWebViewCreated
    case readmeWebViewNavigationFinished
    case gitHubStarListAIGroupingRequested
    case gitHubStarListAIGroupingFirstFrame
    case gitHubStarListCreateRequested
    case gitHubStarListCreateFirstFrame
}

/// 可跨 await 保存的 signpost interval token；只允许由 PerformanceTracer 创建和结束。
struct PerformanceIntervalToken: @unchecked Sendable {
    fileprivate let name: StaticString
    fileprivate let state: OSSignpostIntervalState
}

final class PerformanceTracer: @unchecked Sendable {

    static let shared = PerformanceTracer()

    private let signposter = OSSignposter(
        logger: Logger(subsystem: AppConstants.bundleIdentifier, category: "performance")
    )

    #if DEBUG
    private let mainThreadStallMonitor = MainThreadStallMonitor()
    #endif

    private init() {}

    /// DEBUG 下启动低开销主线程探针。单个 probe 完成前不会继续排队，避免主线程卡住时
    /// 反向制造一批待执行 block；测试 host 不启动，防止污染 testmanagerd 生命周期。
    func startMainThreadStallMonitoringIfNeeded() {
        #if DEBUG
        guard !TestEnvironment.isRunning else { return }
        mainThreadStallMonitor.start()
        #endif
    }

    func begin(_ span: PerformanceSpan) -> PerformanceIntervalToken {
        let intervalName = name(for: span)
        return PerformanceIntervalToken(
            name: intervalName,
            state: signposter.beginInterval(intervalName)
        )
    }

    func end(_ token: PerformanceIntervalToken) {
        signposter.endInterval(token.name, token.state)
    }

    /// 记录不需要跨 async 保存 token 的离散性能事件。
    func mark(_ event: PerformanceEvent) {
        signposter.emitEvent(name(for: event))
    }

    @discardableResult
    func trace<T>(_ span: PerformanceSpan, operation: () throws -> T) rethrows -> T {
        try trace(name(for: span), operation: operation)
    }

    @discardableResult
    func trace<T>(_ span: PerformanceSpan, operation: () async throws -> T) async rethrows -> T {
        try await trace(name(for: span), operation: operation)
    }

    /// 已经创建好的 Task 可直接进入 signpost 区间，不把 actor-isolated closure 发送给
    /// nonisolated tracer；Swift 6 的严格并发检查下这也是最清晰的所有权边界。
    func trace<T: Sendable>(_ span: PerformanceSpan, task: Task<T, Never>) async -> T {
        let intervalName = name(for: span)
        let state = signposter.beginInterval(intervalName)
        defer { signposter.endInterval(intervalName, state) }
        return await task.value
    }

    private func name(for span: PerformanceSpan) -> StaticString {
        switch span {
        case .appBootstrap:
            return "app.bootstrap"
        case .manageInitialLoad:
            return "manage.initial_load"
        case .manageLoadMore:
            return "manage.load_more"
        case .manageRoute:
            return "manage.route"
        case .manageCache:
            return "manage.cache"
        case .manageDatabaseQuery:
            return "manage.database_query"
        case .manageDerive:
            return "manage.derive"
        case .managePublish:
            return "manage.publish"
        case .wikiAvailabilityLoad:
            return "repo_list.wiki_availability"
        case .trendingDerive:
            return "trending.derive"
        case .trendingPublish:
            return "trending.publish"
        case .discoveryLocalFilter:
            return "discovery.local_filter"
        case .activityLocalFilter:
            return "activity.local_filter"
        case .systemSmartCollectionBaseline:
            return "manage.system_smart_collection"
        case .userSmartCollectionBaseline:
            return "manage.user_smart_collection"
        case .activityInitialLoad:
            return "activity.initial_load"
        case .activityLoadMore:
            return "activity.load_more"
        case .keywordSearchBaseline:
            return "manage.search.keyword"
        case .semanticSearchBaseline:
            return "manage.search.semantic"
        case .readmeLoad:
            return "readme.load"
        case .aiStreamResponse:
            return "ai.stream_response"
        case .repoContextPack:
            return "repo_context.pack"
        }
    }

    private func name(for event: PerformanceEvent) -> StaticString {
        switch event {
        case .settingsWindowRequested:
            return "settings.window.requested"
        case .settingsWindowFirstFrame:
            return "settings.window.first_frame"
        case .aboutWindowRequested:
            return "about.window.requested"
        case .aboutWindowFirstFrame:
            return "about.window.first_frame"
        case .repoDetailSelectionRequested:
            return "repo_detail.selection.requested"
        case .repoDetailFirstFrame:
            return "repo_detail.first_frame"
        case .readmeWebViewCreated:
            return "readme.webview.created"
        case .readmeWebViewNavigationFinished:
            return "readme.webview.navigation_finished"
        case .gitHubStarListAIGroupingRequested:
            return "github_star_list.ai_grouping.requested"
        case .gitHubStarListAIGroupingFirstFrame:
            return "github_star_list.ai_grouping.first_frame"
        case .gitHubStarListCreateRequested:
            return "github_star_list.create.requested"
        case .gitHubStarListCreateFirstFrame:
            return "github_star_list.create.first_frame"
        }
    }

    @discardableResult
    private func trace<T>(_ name: StaticString, operation: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }

    @discardableResult
    private func trace<T>(_ name: StaticString, operation: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await operation()
    }
}

#if DEBUG
/// DEBUG-only 主线程卡顿探针。
///
/// 后台 timer 每 250ms 最多投递一个 main queue block。block 真正执行时计算排队延迟，超过
/// 50ms 记录 notice，超过 100ms 标记为 hitch。它只提供相关性线索，最终归因仍以 Instruments
/// 的 Time Profiler / Animation Hitches 为准。
private final class MainThreadStallMonitor: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.starcat.debug.main-thread-stall", qos: .utility)
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "performance")
    private var timer: DispatchSourceTimer?
    private var probeInFlight = false

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.scheduleProbeIfNeeded()
        }
        self.timer = timer
        timer.resume()
    }

    private func scheduleProbeIfNeeded() {
        lock.lock()
        guard !probeInFlight else {
            lock.unlock()
            return
        }
        probeInFlight = true
        lock.unlock()

        let sentAt = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - sentAt
            let elapsedMilliseconds = Double(elapsedNanos) / 1_000_000
            if elapsedMilliseconds >= 100 {
                self.logger.notice("[main-stall] hitch duration_ms=\(elapsedMilliseconds, format: .fixed(precision: 1))")
            } else if elapsedMilliseconds >= 50 {
                self.logger.notice("[main-stall] delay duration_ms=\(elapsedMilliseconds, format: .fixed(precision: 1))")
            }

            self.lock.lock()
            self.probeInFlight = false
            self.lock.unlock()
        }
    }
}
#endif
