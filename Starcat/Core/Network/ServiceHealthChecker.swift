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
enum HealthCheckOutcome: Equatable {
    /// 2xx 响应。`statusCode` 一般是 200。
    case ok(statusCode: Int)
    /// 收到响应但状态码非 2xx（404 / 5xx / 等）。说明服务跑着但 /healthz 没接通。
    case reachableButError(statusCode: Int)
    /// 完全连不上（DNS 失败 / 拒绝连接 / 超时 / SSL 握手失败 等）。
    /// `localizedReason` 已是终端用户可读的字符串（来自 URLError.localizedDescription）。
    case unreachable(reason: String)

    /// 给 UI 用的"健康图标"——SF Symbol 名。
    var systemImage: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .reachableButError: return "exclamationmark.triangle.fill"
        case .unreachable: return "xmark.octagon.fill"
        }
    }

    /// 状态对应的标题 i18n key。详情用 `subtitle` 渲染状态码 / 错误原因。
    var titleKey: LocalizedStringKey {
        switch self {
        case .ok: return "settings.services.health.ok"
        case .reachableButError: return "settings.services.health.error"
        case .unreachable: return "settings.services.health.unreachable"
        }
    }

    /// 副文本：状态码或错误原因。
    var subtitle: String {
        switch self {
        case .ok(let code): return "HTTP \(code)"
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

    /// 对 `service` 在给定 `baseURL` 上执行一次 `GET /healthz`。
    ///
    /// - Parameters:
    ///   - service: 用于决定 /healthz 路径拼接策略（sharing 的 /api 后缀需要剥掉）。
    ///   - baseURL: 当前生效的 baseURL（一般就是 `AppEndpoints.X` 或用户在设置页正在编辑的值）。
    /// - Returns: 探测结果。**永不抛错**——任何异常都映射成 `.unreachable`。
    func check(service: ThirdPartyService, baseURL: URL) async -> HealthCheckOutcome {
        let url = service.healthCheckURL(base: baseURL)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0 (health-check)", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(reason: String(localized: "network.error.serverGeneric"))
            }
            switch http.statusCode {
            case 200...299: return .ok(statusCode: http.statusCode)
            default:        return .reachableButError(statusCode: http.statusCode)
            }
        } catch let urlError as URLError {
            return .unreachable(reason: urlError.localizedDescription)
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }
}
