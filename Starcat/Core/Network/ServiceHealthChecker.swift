//
//  ServiceHealthChecker.swift
//  Starcat
//
//  第三方后端服务的「测试连接」探测器（R-03 2026-06-11 重构为单步探测）。
//
//  约定：每个后端都暴露 `GET /api/v1/ping`（sharing 是 `/v1/ping`，因为它 baseURL 含 `/api`），
//  由 BearerAuth middleware 保护。`ServiceHealthChecker` 用本端点单步探测：
//   - 200 → 服务可达 + Key 正确
//   - 401 → Key 错（缺 Authorization / 错 token 都走这里，后端 middleware 统一返 401）
//   - 其他 4xx/5xx → 服务有问题（含状态码透传给 UI）
//   - 网络错（DNS / timeout / refused / SSL 等）→ 完全连不上
//
//  设置页 → 服务 Tab 的「测试连接」按钮调本 actor，把结果映射成 `HealthCheckOutcome`
//  显示给用户。**所有 outcome 的 subtitle 都带状态码或网络错原因**，方便排查。
//
//  历史 baggage（R-01 v1.2 → R-03 演进）：
//  - 旧方案：两阶段探测「/healthz（无鉴权）+ 业务 endpoint（带鉴权）」。
//    问题：业务 endpoint 借用作 auth probe 副作用大（sharing 返 405、wiki 返 400），
//    要写一堆「这个状态码其实算 ok」的特判，状态机 5 态（ok / unauthorized /
//    authProbeError / reachableButError / unreachable）也偏复杂。
//  - 新方案：后端专门 expose `/api/v1/ping`（R-03 2026-06-11），客户端单步探测。
//    状态机简化为 4 态（ok / unauthorized / serverError / networkError），代码量减半。
//
//  设计约束：
//  - 独立 actor，自带 URLSession（超时短：5s），不复用 GitHub API session（headers / timeout 都不同）。
//  - 只发一次 GET 请求，不重试——「测试连接」是用户主动触发，失败让用户自己再点；
//    内置重试会延长用户等待时间，反而劣化体验。
//  - 返回结果不抛错，统一用 `HealthCheckOutcome` 枚举表达；UI 直接 switch 渲染状态。
//

import Foundation
import SwiftUI

/// 健康检查结果。文案走 i18n key，UI 用 `LocalizedStringKey` 渲染。
///
/// **R-03 2026-06-11 重设计**：从 5 态压缩到 4 态。所有 case 都带「状态码 / 原因」字段，
/// 让 subtitle 永远能展示具体值方便排查（旧版有 `unauthorized` 不带 statusCode、
/// `unreachable` 用 String 不利于结构化）。
enum HealthCheckOutcome: Equatable {
    /// 服务可达 + Key 正确（HTTP 200）。
    /// `statusCode` 一般是 200，留参数是为了未来后端可能扩展到 2xx 其它码（如 204）。
    case ok(statusCode: Int)
    /// API Key 错（缺 Authorization / 无效 token / 过期 token；后端 middleware 统一返 401）。
    /// `statusCode` 一般是 401，留参数让用户排查时也能确认到底是 401 还是 403（虽然现在都用 401）。
    case unauthorized(statusCode: Int)
    /// 服务跑着但鉴权后返回非 200 / 非 401 的状态码（如 404 / 405 / 5xx 等）。
    /// 可能是后端版本太旧没有 ping 端点、URL 拼错指向了别的 web 服务、或后端服务故障。
    case serverError(statusCode: Int)
    /// 完全连不上（DNS 失败 / 拒绝连接 / 超时 / SSL 握手失败 等）。
    /// `reason` 已是终端用户可读的字符串（来自 URLError.localizedDescription）。
    case networkError(reason: String)

    /// 给 UI 用的「健康图标」—— SF Symbol 名。
    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .unauthorized: return "lock.trianglebadge.exclamationmark.fill"
        case .serverError: return "exclamationmark.triangle.fill"
        case .networkError: return "xmark.octagon.fill"
        }
    }

    /// 状态对应的标题 i18n key。详情用 `subtitle` 渲染状态码 / 错误原因。
    var titleKey: LocalizedStringKey {
        switch self {
        case .ok: return "settings.services.health.ok"
        case .unauthorized: return "settings.services.health.unauthorized"
        case .serverError: return "settings.services.health.serverError"
        case .networkError: return "settings.services.health.unreachable"
        }
    }

    /// 副文本：状态码或错误原因。**所有状态都会展示**，方便排查。
    var subtitle: String {
        switch self {
        case .ok(let code): return "HTTP \(code)"
        case .unauthorized(let code): return "HTTP \(code)"
        case .serverError(let code): return "HTTP \(code)"
        case .networkError(let reason): return reason
        }
    }
}

/// 第三方后端服务的健康检查 actor。
///
/// 调用模型：UI 通过 `check(service:url:apiKey:)` 发起一次探测，返回 `HealthCheckOutcome`。
/// 并发：每次调用都 spawn 一次独立 URLSession 请求，不维护内部状态；同一时刻多个
/// 请求互不影响（actor 仅保护构造 / decode，session 本身线程安全）。
actor ServiceHealthChecker {

    // MARK: - Constants

    /// 健康检查超时。设短一点（5s）让用户快速看到「不通」结果，不和正常 API 调用混淆。
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
            // 缓存禁掉——ping 反复探测，命中缓存返回过期结果反而误导。
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// 对 `service` 在给定 `baseURL` 执行一次 ping 探测（R-03 2026-06-11 单步版本）：
    ///   `GET <base>/api/v1/ping`（带 Bearer Token，由后端 BearerAuth middleware 验）
    ///
    /// - Parameters:
    ///   - service: 用于决定 ping URL 路径拼接策略（sharing 特殊，因 baseURL 含 `/api`）。
    ///   - baseURL: 当前生效的 baseURL（持久化值或用户草稿都行）。
    ///   - apiKey: BYOK API Key 草稿值；nil / 空串表示「不带 Authorization 头」（让后端 401 → unauthorized）。
    ///     如果调用方想测「production 默认 Key」，传 `StarcatAPIKeyDefaults.productionKeyOrNil`。
    /// - Returns: 探测结果。**永不抛错**——任何异常都映射成 `.networkError` 或 `.serverError`。
    ///
    /// 状态机：
    /// ```
    /// 网络错（DNS / timeout / refused / SSL）→ networkError(reason)
    /// HTTP 200                                → ok(200)
    /// HTTP 401                                → unauthorized(401)
    /// HTTP 其他（4xx / 5xx）                  → serverError(code)
    /// 响应不是 HTTPURLResponse（极罕见）       → networkError(generic)
    /// ```
    func check(
        service: ThirdPartyService,
        baseURL: URL,
        apiKey: String? = nil
    ) async -> HealthCheckOutcome {
        let url = service.pingURL(base: baseURL)

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
                return .networkError(reason: String.l10n("network.error.serverGeneric"))
            }
            let code = http.statusCode
            switch code {
            case 200:
                return .ok(statusCode: code)
            case 401:
                return .unauthorized(statusCode: code)
            default:
                return .serverError(statusCode: code)
            }
        } catch let urlError as URLError {
            return .networkError(reason: urlError.localizedDescription)
        } catch {
            return .networkError(reason: error.localizedDescription)
        }
    }
}
