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
            return "URL 无效"
        case .invalidResponse:
            return "响应格式无效"
        case .unauthorized:
            return "未授权，请重新登录"
        case .rateLimited(let retryAfter):
            let seconds = Int(retryAfter.rounded())
            return "请求过于频繁，请在 \(seconds) 秒后重试"
        case .notFound:
            return "资源不存在"
        case .serverError(let code):
            return "GitHub 服务器错误（\(code)）"
        case .clientError(let code, let message):
            if let message {
                return "请求失败（\(code)）：\(message)"
            }
            return "请求失败（\(code)）"
        case .decodingError(let error):
            return "响应解析失败：\(error.localizedDescription)"
        case .transport(let error):
            return "网络错误：\(error.localizedDescription)"
        case .cancelled:
            return "已取消"
        }
    }
}
