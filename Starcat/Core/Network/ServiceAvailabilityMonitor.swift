//
//  ServiceAvailabilityMonitor.swift
//  Starcat
//
//  状态栏使用的自建 API 可用性巡检。
//
//  这里刻意不复用 `ServiceHealthChecker`：设置页「测试连接」要走带鉴权的 `/api/v1/ping`，
//  用来验证 URL、服务类型与 API Key；状态栏只需要知道后端进程是否在线，因此走无鉴权
//  `/healthz`。把两者拆开可以避免 Key 错时把 toolbar 误标成“服务不可用”。默认六服务
//  共用聚合 URL 时，这里只确认网关进程返回 2xx，不解析 `services`，不能替代单服务 ping。
//

import Foundation

private let serviceAvailabilityDefaultInterval: Duration = .seconds(10 * 60)

/// 单个服务槽位对应的 `/healthz` 巡检状态；聚合默认 URL 下多个槽位会命中同一网关。
enum ServiceAvailabilityStatus: Equatable {
    /// HTTP 2xx，目标 health URL 可达；聚合场景只代表网关可达。
    case available(statusCode: Int)
    /// 服务器有响应但不是 2xx。
    case serverError(statusCode: Int)
    /// 网络层失败，例如 DNS、超时、拒绝连接或 TLS 握手失败。
    case networkError(reason: String)
    /// URLSession 没给 HTTPURLResponse，极少见；按不可用处理。
    case invalidResponse

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 单个服务槽位最近一次 `/healthz` 巡检结果。
struct ServiceAvailabilityResult: Equatable, Identifiable {
    let service: ThirdPartyService
    let status: ServiceAvailabilityStatus
    let checkedAt: Date

    var id: String { service.rawValue }
    var isAvailable: Bool { status.isAvailable }
}

/// 自建服务最新结果的聚合摘要，供 toolbar / popover 直接渲染。
struct ServiceAvailabilitySummary: Equatable {
    let totalCount: Int
    let availableCount: Int
    let failedServices: [ThirdPartyService]
    let isChecking: Bool
    let lastCheckedAt: Date?

    static let empty = ServiceAvailabilitySummary(
        totalCount: ThirdPartyService.allCases.count,
        availableCount: 0,
        failedServices: [],
        isChecking: false,
        lastCheckedAt: nil
    )

    var hasChecked: Bool { lastCheckedAt != nil }
    var hasIssue: Bool { hasChecked && !failedServices.isEmpty }
    var isAllAvailable: Bool { hasChecked && availableCount == totalCount }
}

/// 执行单次 `/healthz` 请求的 actor。
///
/// actor 自身无持久状态，只负责 URLSession 调用与结果映射；这样 monitor 可以安全地用
/// `withTaskGroup` 并发检查自建服务。它故意不解析聚合 healthz 的 `services` 字段，因此
/// 2xx 只代表当前 URL 可达，不证明请求槽位对应的业务服务已挂载。
actor ServiceAvailabilityChecker {
    private static let timeout: TimeInterval = 5

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: config)
        }
    }

    func check(service: ThirdPartyService, baseURL: URL) async -> ServiceAvailabilityResult {
        let url = service.healthURL(base: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0 (service-availability)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let status: ServiceAvailabilityStatus
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .invalidResponse
                return ServiceAvailabilityResult(service: service, status: status, checkedAt: Date())
            }
            if (200..<300).contains(http.statusCode) {
                status = .available(statusCode: http.statusCode)
            } else {
                status = .serverError(statusCode: http.statusCode)
            }
        } catch let urlError as URLError {
            status = .networkError(reason: urlError.localizedDescription)
        } catch {
            status = .networkError(reason: error.localizedDescription)
        }
        return ServiceAvailabilityResult(service: service, status: status, checkedAt: Date())
    }
}

/// toolbar 观察的服务可用性状态容器。
///
/// 约束：
/// - `refreshNow()` 不做缓存短路，每次调用都真实打 `/healthz`。
/// - 保存 `latestResults` 只是为了让 UI 有稳定的最新状态可读，不作为请求缓存策略。
/// - 后台轮询默认 10 分钟一次；手动刷新与后台刷新共享同一个 in-flight guard，避免重叠请求。
@MainActor
@Observable
final class ServiceAvailabilityMonitor {
    private let checker: ServiceAvailabilityChecker
    private let services: [ThirdPartyService]
    private let interval: Duration
    private let baseURLProvider: @MainActor (ThirdPartyService) -> URL
    private var periodicTask: Task<Void, Never>?
    private var activeRefreshTask: Task<Void, Never>?

    private(set) var latestResults: [ThirdPartyService: ServiceAvailabilityResult] = [:]
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?

    init(
        checker: ServiceAvailabilityChecker = ServiceAvailabilityChecker(),
        services: [ThirdPartyService] = ThirdPartyService.allCases,
        interval: Duration = serviceAvailabilityDefaultInterval,
        baseURLProvider: @escaping @MainActor (ThirdPartyService) -> URL = { AppEndpoints.resolved(for: $0) }
    ) {
        self.checker = checker
        self.services = services
        self.interval = interval
        self.baseURLProvider = baseURLProvider
    }

    var summary: ServiceAvailabilitySummary {
        let results = services.compactMap { latestResults[$0] }
        let available = results.filter(\.isAvailable).count
        let failed: [ThirdPartyService]
        if results.count == services.count {
            failed = services.filter { latestResults[$0]?.isAvailable != true }
        } else {
            failed = []
        }
        return ServiceAvailabilitySummary(
            totalCount: services.count,
            availableCount: available,
            failedServices: failed,
            isChecking: isChecking,
            lastCheckedAt: lastCheckedAt
        )
    }

    /// 启动后台巡检。首次启动会立刻检查一次，之后每 10 分钟检查一次。
    func startPeriodicChecks() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                do {
                    try await Task.sleep(for: self?.interval ?? serviceAvailabilityDefaultInterval)
                } catch {
                    break
                }
            }
        }
    }

    /// 停止后台巡检。当前 in-flight 请求也会取消，避免退出/测试时留下悬挂任务。
    func stopPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        isChecking = false
    }

    /// 立即并发检查自建 API。不会因为刚检查过而跳过。
    func refreshNow() async {
        if let activeRefreshTask {
            await activeRefreshTask.value
            return
        }

        isChecking = true
        let task = Task { [weak self] in
            guard let self else { return }
            let bases = await MainActor.run {
                Dictionary(uniqueKeysWithValues: self.services.map { service in
                    (service, self.baseURLProvider(service))
                })
            }

            let results = await withTaskGroup(of: ServiceAvailabilityResult.self) { group in
                for service in self.services {
                    guard let baseURL = bases[service] else { continue }
                    group.addTask { [checker = self.checker] in
                        await checker.check(service: service, baseURL: baseURL)
                    }
                }

                var collected: [ServiceAvailabilityResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            await MainActor.run {
                for result in results {
                    self.latestResults[result.service] = result
                }
                self.lastCheckedAt = results.map(\.checkedAt).max() ?? Date()
                self.isChecking = false
                self.activeRefreshTask = nil
            }
        }
        activeRefreshTask = task
        await task.value
    }
}
