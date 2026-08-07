//
//  ServiceHealthChecker.swift
//  Starcat
//
//  第三方后端服务的「测试连接」探测器（R-03 2026-06-11 重构为单步探测）。
//
//  约定：每个后端都暴露 `GET /api/v1/ping`（Sharing 与其它服务对齐：baseURL 不含 `/api`，
//  Paths 写绝对 `/api/v1/ping`；详见 AppEndpoints v5 / v10），
//  由 BearerAuth middleware 保护。`ServiceHealthChecker` 用本端点单步探测：
//   - 200 + body.data.service 与期望服务一致 + ok=true → 服务可达 + Key 正确 + 地址没配错
//   - 200 但 service 不匹配 → serviceMismatch（典型：把 trending 端口填到 sharing）
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

/// `GET /api/v1/ping` 200 响应里 envelope `data` 段的结构。
///
/// 与后端 `starcat-api-kit/httputil.HandlePingV1`（各 API handler 薄包装）对齐；
/// 路由注册时传入固定 service 名（`trending` / `weekly` / `sharing` / `wiki` 等）。
struct ServicePingPayload: Decodable, Sendable, Equatable {
    let service: String
    let ok: Bool
    /// 后端逐步补齐版本号期间必须保持可选，旧服务不返回该字段时仍能正常通过健康检查。
    let version: String?
}

/// 健康检查结果。文案走 i18n key，UI 用 `LocalizedStringKey` 渲染。
///
/// **R-03 2026-06-11 重设计**：从 5 态压缩到 4 态。所有 case 都带「状态码 / 原因」字段，
/// 让 subtitle 永远能展示具体值方便排查（旧版有 `unauthorized` 不带 statusCode、
/// `unreachable` 用 String 不利于结构化）。
enum HealthCheckOutcome: Equatable {
    /// 服务可达 + Key 正确 + ping 响应 service 与设置项一致（HTTP 200）。
    /// `statusCode` 一般是 200，留参数是为了未来后端可能扩展到 2xx 其它码（如 204）。
    /// `version` 直接展示后端返回值；旧服务未返回或只返回空白时为 nil。
    case ok(statusCode: Int, version: String?)
    /// ping 返回 200，但 `data.service` 与当前设置项不一致（典型：端口 / 服务填错）。
    /// UI 不暴露期望 / 实际服务名，只提示验证失败。
    case serviceMismatch
    /// API Key 错（缺 Authorization / 无效 token / 过期 token；后端 middleware 统一返 401）。
    /// `statusCode` 一般是 401，留参数让用户排查时也能确认到底是 401 还是 403（虽然现在都用 401）。
    case unauthorized(statusCode: Int)
    /// 服务跑着但鉴权后返回非 200 / 非 401 的状态码（如 404 / 405 / 5xx 等）。
    /// 可能是后端版本太旧没有 ping 端点、URL 拼错指向了别的 web 服务、或后端服务故障。
    case serverError(statusCode: Int)
    /// 完全连不上（DNS 失败 / 拒绝连接 / 超时 / SSL 握手失败 等）。
    /// `reason` 已是终端用户可读的字符串（来自 URLError.localizedDescription）。
    case networkError(reason: String)
    /// SwiftUI `.task` / URLSession 主动取消，不代表服务不可用。
    /// 这个状态只给调用方做控制流判断，不展示、不写诊断失败，避免页面生命周期取消污染结果。
    case cancelled

    /// 给 UI 用的「健康图标」—— SF Symbol 名。
    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .serviceMismatch: return "arrow.triangle.swap"
        case .unauthorized: return "lock.trianglebadge.exclamationmark.fill"
        case .serverError: return "exclamationmark.triangle.fill"
        case .networkError: return "xmark.octagon.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    /// 状态对应的标题 i18n key。详情用 `subtitle` 渲染状态码 / 错误原因。
    var titleKey: LocalizedStringKey {
        switch self {
        case .ok: return "settings.services.health.ok"
        case .serviceMismatch: return "settings.services.health.serviceMismatch"
        case .unauthorized: return "settings.services.health.unauthorized"
        case .serverError: return "settings.services.health.serverError"
        case .networkError: return "settings.services.health.unreachable"
        case .cancelled: return "settings.services.summary.checking"
        }
    }

    /// 副文本：成功时只展示可选服务版本；失败时保留状态码或错误原因，方便排查。
    var subtitle: String {
        switch self {
        case .ok(_, let version): return version ?? ""
        case .serviceMismatch: return ""
        case .unauthorized(let code): return "HTTP \(code)"
        case .serverError(let code): return "HTTP \(code)"
        case .networkError(let reason): return reason
        case .cancelled: return ""
        }
    }

    /// 成功态版本副文案包含前导标点，供 UI 与“可达”无缝拼成完整句子。
    /// 保留为独立 Text 是为了继续让版本信息使用 `.secondary`，不抢成功状态的视觉层级。
    var successVersionSuffix: String? {
        guard case .ok(_, let version?) = self else { return nil }
        return String(
            format: String.l10n("settings.services.health.versionSuffixFormat"),
            version
        )
    }

    /// ping 探测是否视为「健康」——用于设置页四服务汇总徽标。
    var isHealthy: Bool {
        if case .ok = self { return true }
        return false
    }

    /// 自动探测可以轻量重试的瞬时失败。
    ///
    /// 手动测试不使用这个策略，保持“点一次测一次”的即时反馈；进入设置页的自动探测
    /// 才用它吸收 fly.io 冷启动 / TLS 抖动 / 短暂 timeout。
    var shouldRetryForAutomaticProbe: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// 取消来自视图生命周期或 URLSession 主动取消，不应覆盖已有健康结果。
    var isCancelledProbe: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// 设置页 Services Tab 顶部四服务 ping 汇总态。
enum ServicesHealthSummary: Equatable {
    case checking
    case allOK
    case partial(okCount: Int, total: Int)
    case unavailable

    /// 根据各服务 `HealthCheckOutcome` 与进行中的 probe 计算汇总。
    ///
    /// - `testableServices`：URL 校验可通过、允许发 ping 的服务（invalid URL 不参与汇总分母）。
    static func compute(
        testableServices: [ThirdPartyService],
        results: [String: HealthCheckOutcome],
        probingIDs: Set<String>
    ) -> ServicesHealthSummary {
        let total = testableServices.count
        guard total > 0 else { return .allOK }

        if !probingIDs.isEmpty {
            return .checking
        }

        let outcomes = testableServices.compactMap { results[$0.id] }

        // 进入 Tab 后四路并发尚未返回任何结果。
        if outcomes.isEmpty {
            return .checking
        }

        let okCount = outcomes.filter(\.isHealthy).count

        // 个别结果被清空（reset / 尚未 re-probe）且当前无 probe 进行中：缺失项计入分母，
        // 按已有结果汇总，避免顶部 pill 永远停在 Checking。
        if outcomes.count < total {
            if okCount == 0 { return .unavailable }
            return .partial(okCount: okCount, total: total)
        }

        if okCount == total { return .allOK }
        if okCount == 0 { return .unavailable }
        return .partial(okCount: okCount, total: total)
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .checking: return "settings.services.summary.checking"
        case .allOK: return "settings.services.summary.allOK"
        case .partial: return "settings.services.summary.partialFormat"
        case .unavailable: return "settings.services.summary.unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "arrow.triangle.2.circlepath"
        case .allOK: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .checking: return .secondary
        case .allOK: return .green
        case .partial: return .orange
        case .unavailable: return .red
        }
    }

    /// partial 态标题需 `%d/%d` 格式化。
    var partialTitle: String? {
        guard case .partial(let ok, let total) = self else { return nil }
        return String(format: String.l10n("settings.services.summary.partialFormat"), ok, total)
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
    ///     如果调用方想测「production 默认 Key」，传 `StarcatAPIKeyDefaults.productionKeyOrNil(for:)`。
    /// - Returns: 探测结果。**永不抛错**——任何异常都映射成 `.networkError` 或 `.serverError`。
    ///
    /// 状态机：
    /// ```
    /// 网络错（DNS / timeout / refused / SSL）→ networkError(reason)
    /// HTTP 200 + service 匹配 + ok       → ok(200)
    /// HTTP 200 + service 不匹配          → serviceMismatch(...)
    /// HTTP 200 + body 无法解析           → serverError(200)
    /// HTTP 401                           → unauthorized(401)
    /// HTTP 其他（4xx / 5xx）             → serverError(code)
    /// 响应不是 HTTPURLResponse（极罕见）   → networkError(generic)
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
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: service)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .networkError(reason: String.l10n("network.error.serverGeneric"))
            }
            let code = http.statusCode
            switch code {
            case 200:
                let outcome = Self.evaluatePingBody(
                    data: data,
                    response: response,
                    expectedService: service
                )
                recordOutcome(outcome, service: service)
                return outcome
            case 401:
                let outcome = HealthCheckOutcome.unauthorized(statusCode: code)
                recordOutcome(outcome, service: service)
                return outcome
            default:
                let outcome = HealthCheckOutcome.serverError(statusCode: code)
                recordOutcome(outcome, service: service)
                return outcome
            }
        } catch let urlError as URLError where urlError.code == .cancelled || Task.isCancelled {
            return .cancelled
        } catch let urlError as URLError {
            let outcome = HealthCheckOutcome.networkError(reason: urlError.localizedDescription)
            recordOutcome(outcome, service: service)
            return outcome
        } catch is CancellationError {
            return .cancelled
        } catch {
            let outcome = HealthCheckOutcome.networkError(reason: error.localizedDescription)
            recordOutcome(outcome, service: service)
            return outcome
        }
    }

    // MARK: - Private

    /// 解析 ping 200 响应体，校验 `data.service` 与 `data.ok`。
    private static func evaluatePingBody(
        data: Data,
        response: URLResponse,
        expectedService: ThirdPartyService
    ) -> HealthCheckOutcome {
        let decoder = JSONDecoder()
        do {
            let payload = try StarcatEnvelopeDecoder.decode(
                ServicePingPayload.self,
                data: data,
                response: response,
                decoder: decoder
            )
            guard payload.ok else {
                return .serverError(statusCode: 200)
            }
            let expected = expectedService.rawValue
            guard payload.service == expected else {
                return .serviceMismatch
            }
            // 版本字段采用渐进兼容：后端未升级时保持成功且不显示副文本；空白版本也不占 UI 空间。
            let normalizedVersion = payload.version?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok(
                statusCode: 200,
                version: normalizedVersion?.isEmpty == false ? normalizedVersion : nil
            )
        } catch {
            return .serverError(statusCode: 200)
        }
    }

    /// 健康检查是用户主动排障入口，失败结果需要进入诊断包；成功只记 debug，避免噪音。
    private nonisolated func recordOutcome(_ outcome: HealthCheckOutcome, service: ThirdPartyService) {
        switch outcome {
        case .ok:
            DiagnosticLogStore.record(
                level: .debug,
                category: "network",
                operation: "serviceHealthCheck",
                message: "Service health check succeeded",
                service: service.rawValue
            )
        case .serviceMismatch:
            DiagnosticLogStore.record(
                level: .warning,
                category: "network",
                operation: "serviceHealthCheck",
                message: "Service health check mismatch",
                service: service.rawValue
            )
        case .unauthorized(let code):
            DiagnosticLogStore.record(
                level: .warning,
                category: "network",
                operation: "serviceHealthCheck",
                message: "Service health check unauthorized",
                service: service.rawValue,
                statusCode: code
            )
        case .serverError(let code):
            DiagnosticLogStore.record(
                level: .warning,
                category: "network",
                operation: "serviceHealthCheck",
                message: "Service health check server error",
                service: service.rawValue,
                statusCode: code
            )
        case .networkError(let reason):
            DiagnosticLogStore.record(
                level: .warning,
                category: "network",
                operation: "serviceHealthCheck",
                message: "Service health check network error",
                service: service.rawValue,
                underlying: reason
            )
        case .cancelled:
            break
        }
    }
}
