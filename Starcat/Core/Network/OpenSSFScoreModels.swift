//
//  OpenSSFScoreModels.swift
//  Starcat
//
//  OpenSSF Scorecard API DTO。
//
//  只结构化 UI 和刷新策略需要的字段；完整响应仍由 `OpenSSFScoreRecord.checksJSON`
//  保存为原始 JSON，避免后续扩展视图时被当前 DTO 裁掉信息。
//

import Foundation

struct OpenSSFScorePayload: Decodable, Equatable, Sendable {
    let date: String?
    let score: Double?
    let checks: [OpenSSFScoreCheck]
}

struct OpenSSFScoreCheck: Decodable, Equatable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let score: Double
    let reason: String?
    let details: [String]?
    let documentation: OpenSSFScoreDocumentation?

    var isEvaluated: Bool {
        score >= 0
    }
}

struct OpenSSFScoreDocumentation: Decodable, Equatable, Sendable {
    let short: String?
    let url: URL?
}

enum OpenSSFScoreAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case notIndexed
    case serverError(statusCode: Int)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("openssf.error.invalidURL")
        case .notIndexed:
            return String.l10n("openssf.error.notIndexed")
        case .serverError(let statusCode):
            return String(format: String.l10n("openssf.error.serverFormat"), statusCode)
        case .transport(let message):
            return String(format: String.l10n("openssf.error.transportFormat"), message)
        case .decoding(let message):
            return String(format: String.l10n("openssf.error.decodingFormat"), message)
        }
    }
}

struct OpenSSFScoreAPIResponse: Sendable {
    let payload: OpenSSFScorePayload
    let rawData: Data
}
