//
//  AnySearchModels.swift
//  Starcat
//
//  AnySearch REST API 的请求、响应与错误模型。
//

import Foundation

struct AnySearchRequest: Codable, Hashable, Sendable {
    let query: String
    let maxResults: Int
    let domain: String?
    let tag: String?
    let contentTypes: [String]?
    let zone: String?
    let language: String?
    let params: [String: String]?

    init(
        query: String,
        maxResults: Int = 10,
        domain: String? = "code",
        tag: String? = nil,
        contentTypes: [String]? = ["web", "doc", "news"],
        zone: String? = nil,
        language: String? = nil,
        params: [String: String]? = nil
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxResults = min(max(1, maxResults), 100)
        self.domain = domain
        self.tag = tag
        self.contentTypes = contentTypes
        self.zone = zone
        self.language = language
        self.params = params
    }
}

struct AnySearchResponse: Equatable, Sendable {
    let results: [AnySearchResult]
    let metadata: AnySearchMetadata?
}

struct AnySearchResult: Identifiable, Hashable, Sendable {
    var id: String { normalizedURL.absoluteString }
    let title: String
    let url: URL
    let normalizedURL: URL
    let snippet: String?
    let content: String?
    let sourceDomain: String?
}

struct AnySearchMetadata: Codable, Equatable, Sendable {
    let requestId: String?
    let totalResults: Int?
    let searchTimeMs: Int?
}

enum AnySearchError: Error, LocalizedError, Equatable {
    case disabled
    case invalidURL
    case invalidAPIKey
    case rateLimited
    case server(statusCode: Int)
    case invalidResponse
    case api(code: Int, message: String)
    case decoding
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .disabled: return "AnySearch 未启用"
        case .invalidURL: return "AnySearch URL 无效"
        case .invalidAPIKey: return "AnySearch API Key 无效或已过期"
        case .rateLimited: return "AnySearch 额度不足或请求过于频繁"
        case .server(let code): return "AnySearch 服务异常（HTTP \(code)）"
        case .invalidResponse: return "AnySearch 返回了无效响应"
        case .api(_, let message): return message
        case .decoding: return "AnySearch 响应解析失败"
        case .transport(let message): return message
        }
    }
}

protocol AnySearchClientProtocol: Sendable {
    func search(_ request: AnySearchRequest) async throws -> AnySearchResponse
}
