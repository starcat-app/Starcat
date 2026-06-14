//
//  ExternalContextDegradationReason.swift
//  Starcat
//
//  Y9.3（2026-06-14 dong4j 反馈）：摘要生成时 AnySearch 外部上下文为什么没拉到的分类原因。
//
//  设计目标：用户开启了 AnySearch 总开关 + AI 子开关后，预期摘要里有外部参考来源；
//  但当上游服务挂了 / API Key 失效 / 配额用完时，原方案是**静默降级**——摘要里没
//  「## 外部参考来源」段，状态行里没"外网"两字，但**没有任何 UI 反馈**告诉用户为什么。
//  本 enum 把 catch 到的 AnySearchError / URLError / 其他错误分类到 7 个明确语义，
//  让 UI 顶部 banner 像 Y4 代码上下文降级一样给出对应文案。
//
//  与 ContextDegradationReason 的区别：
//    - Y4 ContextDegradationReason：**代码上下文**（RepoContextPacker / SharedSnapshot）
//      失败的分类，5 case 都是"用户开了但下载/打包失败"路径；
//    - 本 enum：**外部网页上下文**（AnySearch）失败的分类，7 case 覆盖上游 5xx /
//      网络异常 / Key 失效 / 配额 / 限流 / 能力未启用 / 兜底；
//    - 两者并行存在、相互正交，UI 可同时显示两条 banner 给用户全景。
//
//  分类原则：
//    - settings 守卫拦截（用户没开 / 私仓不允许）→ 不进入降级路径，本 enum 不处理；
//    - 0 结果（HTTP 200 但 results.isEmpty）→ 不算降级，那是数据问题不是错误；
//    - 真错误（AnySearchError / URLError / 兜底）→ 都映射到本 enum 之一。
//

import Foundation

/// 外部网页上下文（AnySearch）被降级的原因（Y9.3）。
enum ExternalContextDegradationReason: Sendable, Equatable {
    /// 上游 5xx 临时错误：502 Bad Gateway / 503 Service Unavailable / 504 Gateway Timeout 等。
    /// 客户端按设计已重试 1 次仍失败。携带 statusCode 让 banner 文案可显示具体码号。
    case serviceUnavailable(statusCode: Int?)

    /// 网络层异常：DNS 解析失败 / 连接被拒 / TLS 握手失败 / 系统代理拦截 / 超时等。
    /// 对应 AnySearchError.transport 与 URLError 全集。
    case networkUnavailable

    /// 401 / 403 expired —— API Key 无效或过期。
    case invalidAPIKey

    /// 402 —— 配额用完（匿名 IP 级 / Bearer 账号级）。
    case quotaExhausted

    /// 429 —— 请求过于频繁。
    case rateLimited

    /// 403 capability_not_enabled / account_disabled —— 账号未开通 code 域能力或被封禁。
    case capabilityNotEnabled

    /// 兜底：未知错误（decoding / api / invalidResponse / 其他）。
    case unknown

    /// 本地化的 banner 文案 key。
    var bannerMessageKey: String {
        switch self {
        case .serviceUnavailable: return "ai.externalContext.degraded.serviceUnavailable"
        case .networkUnavailable: return "ai.externalContext.degraded.networkUnavailable"
        case .invalidAPIKey: return "ai.externalContext.degraded.invalidAPIKey"
        case .quotaExhausted: return "ai.externalContext.degraded.quotaExhausted"
        case .rateLimited: return "ai.externalContext.degraded.rateLimited"
        case .capabilityNotEnabled: return "ai.externalContext.degraded.capabilityNotEnabled"
        case .unknown: return "ai.externalContext.degraded.unknown"
        }
    }

    /// 把任意 error 分类到 7 case 之一。
    ///
    /// 优先级：AnySearchError typed case → URLError → 兜底 .unknown。
    /// 不属于已知错误类型 → .unknown 兜底（语义上"AnySearch 出错但分类不到具体类型"）。
    static func classify(_ error: Error) -> ExternalContextDegradationReason {
        if let anyError = error as? AnySearchError {
            switch anyError {
            case .serviceUnavailable:
                return .serviceUnavailable(statusCode: nil)
            case .server(let statusCode):
                return .serviceUnavailable(statusCode: statusCode)
            case .transport:
                return .networkUnavailable
            case .invalidAPIKey:
                return .invalidAPIKey
            case .anonymousQuotaExhausted, .keyQuotaExhausted:
                return .quotaExhausted
            case .rateLimited:
                return .rateLimited
            case .capabilityNotEnabled, .accountDisabled:
                return .capabilityNotEnabled
            case .disabled, .invalidURL, .invalidRequest, .invalidResponse, .api, .decoding:
                return .unknown
            }
        }
        if error is URLError {
            return .networkUnavailable
        }
        return .unknown
    }
}
