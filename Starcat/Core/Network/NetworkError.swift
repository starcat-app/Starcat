//
//  NetworkError.swift
//  Starcat
//
//  统一网络错误类型，覆盖 GitHub API 调用全过程：构造请求、传输、状态码、解码、限流。
//

import Foundation

/// 网络错误。
///
/// 业务层只关心枚举 case，本地化文案由 `errorDescription` 提供。
/// 不直接暴露 URLSession 的 NSURLError 给 UI。
enum NetworkError: Error, LocalizedError {
    /// 构造 URL 失败（编程错误，理论上不应出现）。
    case invalidURL

    /// 非 HTTPURLResponse，URLSession 异常。
    case invalidResponse

    /// 鉴权失败（401），通常需要用户重新登录。
    case unauthorized

    /// 触发 Rate Limit（403 + X-RateLimit-Remaining=0）。
    case rateLimited(retryAfter: TimeInterval)

    /// W4-4 C2：条件请求命中 304 Not Modified。
    /// 业务层（SyncManager）捕获此错误代表"内容未变化"，应继续使用本地缓存。
    /// 携带响应的 ETag（通常与请求时的 If-None-Match 相同，但 GitHub 偶尔会返回更新过的格式 — 原样保留即可）。
    case notModified(etag: String?)

    /// 404。
    case notFound

    /// 服务端错误（5xx）。
    case serverError(statusCode: Int)

    /// 客户端错误（4xx 但不是上面那些）。
    case clientError(statusCode: Int, message: String?)

    /// 响应解码失败。
    case decodingError(underlying: Error)

    /// URLSession 传输错误（断网、超时、DNS 等）。
    case transport(underlying: Error)

    /// 业务取消。
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "network.error.invalidURL")
        case .invalidResponse:
            return String(localized: "network.error.invalidResponse")
        case .unauthorized:
            return String(localized: "network.error.unauthorized")
        case .rateLimited(let retryAfter):
            let seconds = Int(retryAfter.rounded())
            return String(format: String(localized: "network.error.rateLimitedFormat"), seconds)
        case .notModified:
            return String(localized: "network.error.notModified")
        case .notFound:
            return String(localized: "network.error.notFound")
        case .serverError(let code):
            return String(format: String(localized: "network.error.serverFormat"), code)
        case .clientError(let code, let message):
            if let message {
                return String(format: String(localized: "network.error.clientWithMessageFormat"), code, message)
            }
            return String(format: String(localized: "network.error.clientFormat"), code)
        case .decodingError(let error):
            return String(format: String(localized: "network.error.decodingFormat"), error.localizedDescription)
        case .transport(let error):
            return String(format: String(localized: "network.error.transportFormat"), error.localizedDescription)
        case .cancelled:
            return String(localized: "network.error.cancelled")
        }
    }
}
