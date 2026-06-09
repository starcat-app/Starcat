//
//  ServiceHealthChecker.swift
//  Starcat
//
//  第三方后端服务的「测试连接」探测器。
//
//  约定：每个后端都暴露 `GET <baseURL>/healthz`，返回 2xx 即视为可用。
//  设置页 → 服务 Tab 的"测试连接"按钮调本 actor，把结果映射成 `HealthCheckOutcome`
//  显示给用户。
//
//  设计约束：
//  - 独立 actor，自带 URLSession（超时短：5s），不复用 GitHub API session（headers / timeout 都不同）。
//  - 只发 HEAD/GET 一种请求，不重试——"测试连接"是用户主动触发，失败让用户自己再点；
//    内置重试会延长用户等待时间，反而劣化体验。
//  - 返回结果不抛错，统一用 `HealthCheckOutcome` 枚举表达；UI 直接 switch 渲染状态。
//

import Foundation
import SwiftUI

/// 健康检查结果。文案走 i18n key，UI 用 `LocalizedStringKey` 渲染。
///
/// **R-01 v1.2 2026-06-10 扩展**：现在分两步检测——`/healthz`（不鉴权）确认服务可达，
/// `/api/v1` 任意端点（带 Bearer）确认鉴权配置正确。新增 `unauthorized` 态专门表达
/// 「服务可达但 API Key 错」，让用户知道改 Key 而不是改服务地址。
enum HealthCheckOutcome: Equatable {
    /// 健康检查 + 鉴权探测都通过（healthz 2xx + /api/v1 200/2xx）。
    /// `statusCode` 是 healthz 的状态码（一般是 200）。
    case ok(statusCode: Int)
    /// healthz 通过但 /api/v1 探测返回 401。
    /// 服务地址正确，但 API Key 错（或者过期/被吊销）。
    case unauthorized
    /// healthz 通过但 /api/v1 探测返回非 401 的非 2xx 状态码（404 / 5xx / 等）。
    /// 服务跑着但鉴权 endpoint 行为异常，可能是后端版本太旧 / 配置错。
    case authProbeError(statusCode: Int)
    /// healthz 收到响应但状态码非 2xx。说明服务跑着但 /healthz 接错（罕见，一般是
    /// 用户填了一个跑着完全不同的 web 服务的 URL）。
    case reachableButError(statusCode: Int)
    /// 完全连不上（DNS 失败 / 拒绝连接 / 超时 / SSL 握手失败 等）。
    /// `localizedReason` 已是终端用户可读的字符串（来自 URLError.localizedDescription）。
    case unreachable(reason: String)

    /// 给 UI 用的"健康图标"——SF Symbol 名。
    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .unauthorized: return "lock.trianglebadge.exclamationmark.fill"
        case .authProbeError, .reachableButError: return "exclamationmark.triangle.fill"
        case .unreachable: return "xmark.octagon.fill"
        }
    }

    /// 状态对应的标题 i18n key。详情用 `subtitle` 渲染状态码 / 错误原因。
    var titleKey: LocalizedStringKey {
        switch self {
        case .ok: return "settings.services.health.ok"
        case .unauthorized: return "settings.services.health.unauthorized"
        case .authProbeError: return "settings.services.health.authProbeError"
        case .reachableButError: return "settings.services.health.error"
        case .unreachable: return "settings.services.health.unreachable"
        }
    }

    /// 副文本：状态码或错误原因。
    var subtitle: String {
        switch self {
        case .ok(let code): return "HTTP \(code)"
        case .unauthorized: return "HTTP 401"
        case .authProbeError(let code): return "HTTP \(code)"
        case .reachableButError(let code): return "HTTP \(code)"
        case .unreachable(let reason): return reason
        }
    }
}

/// 第三方后端服务的健康检查 actor。
///
/// 状态机：UI 通过 `check(service:url:)` 发起一次探测，返回 `HealthCheckOutcome`。
/// 并发：每次调用都 spawn 一次独立 URLSession 请求，不维护内部状态；同一时刻多个
/// 请求互不影响（actor 仅保护构造 / decode，session 本身线程安全）。
actor ServiceHealthChecker {

    // MARK: - Constants

    /// 健康检查超时。设短一点（5s）让用户快速看到"不通"结果，不和正常 API 调用混淆。
    private static let timeout: TimeInterval = 5

    // MARK: - Properties

    private let session: URLSession

    // MARK: - Initialization

    /// - Parameter session: 注入用于测试 mock；默认走独立 ephemeral session。
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            // 缓存禁掉——`/healthz` 反复探测，命中缓存返回过期结果反而误导。
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// 对 `service` 在给定 `baseURL` 执行两步探测：
    ///  1. `GET <base>/healthz`（不鉴权）—— 验证服务可达
    ///  2. `GET <base>/api/v1/<probe-path>`（带 Bearer Token）—— 验证鉴权配置
    ///
    /// - Parameters:
    ///   - service: 用于决定 /healthz + /api/v1 探测路径拼接策略。
    ///   - baseURL: 当前生效的 baseURL（持久化值或用户草稿）。
    ///   - apiKey: BYOK API Key 草稿值；nil 表示「不带 Authorization 头」（让后端 401 → unauthorized）。
    ///     如果调用方想测「production 默认 Key」，传 `StarcatAPIKeyDefaults.productionKeyOrNil`。
    /// - Returns: 探测结果。**永不抛错**——任何异常都映射成 `.unreachable` / `.authProbeError`。
    ///
    /// 状态机：
    /// ```
    /// healthz 网络错 → unreachable
    /// healthz 非 2xx → reachableButError
    /// healthz 2xx →
    ///   auth-probe 网络错 → unreachable（罕见，healthz 通了网络应该没问题）
    ///   auth-probe 401 → unauthorized
    ///   auth-probe 5xx → authProbeError
    ///   auth-probe 其他（包括 200 / 404 / 405）→ ok
    /// ```
    /// 之所以 404 / 405 也算 ok：sharing 的鉴权探测用 GET /api/v1/share（业务是 POST，
    /// authMiddleware 先于路由匹配），有效 token → 路由 404/405；无效 token → 401。
    func check(
        service: ThirdPartyService,
        baseURL: URL,
        apiKey: String? = nil
    ) async -> HealthCheckOutcome {
        // 第一步：healthz
        let healthURL = service.healthCheckURL(base: baseURL)
        let healthOutcome = await probe(url: healthURL, apiKey: nil)
        switch healthOutcome {
        case .networkError(let reason):
            return .unreachable(reason: reason)
        case .response(let code) where !(200...299).contains(code):
            return .reachableButError(statusCode: code)
        case .response:
            break // 走第二步
        }

        // 第二步：auth probe
        let probeURL = service.authProbeURL(base: baseURL)
        let probeOutcome = await probe(url: probeURL, apiKey: apiKey)
        switch probeOutcome {
        case .networkError(let reason):
            return .unreachable(reason: reason)
        case .response(401):
            return .unauthorized
        case .response(let code) where (500...599).contains(code):
            return .authProbeError(statusCode: code)
        case .response(let code):
            // 200 / 2xx / 404 / 405 等：authMiddleware 放行（鉴权通过），handler 返回什么都算 ok
            return .ok(statusCode: code)
        }
    }

    // MARK: - 私有探测原语

    /// 探测单个 URL 的低层结果（response 状态码 / 网络错），不解读业务语义。
    private enum ProbeResult {
        case response(Int)
        case networkError(reason: String)
    }

    private func probe(url: URL, apiKey: String?) async -> ProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0 (health-check)", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError(reason: String(localized: "network.error.serverGeneric"))
            }
            return .response(http.statusCode)
        } catch let urlError as URLError {
            return .networkError(reason: urlError.localizedDescription)
        } catch {
            return .networkError(reason: error.localizedDescription)
        }
    }
}
