//
//  RAGBackendConfiguration.swift
//  Starcat
//
//  知识库 RAG 的可选自托管检索后端配置。
//
//  SQLite 始终是默认和回退实现。endpoint/index/collection 属于普通偏好；Meilisearch 与
//  Qdrant API key 使用 KeychainManager 的独立账户保存，不进入 UserDefaults 或日志。
//

import Foundation

enum RAGKeywordBackend: String, CaseIterable, Codable, Sendable {
    case sqliteFTS5 = "sqlite_fts5"
    case meilisearch
}

enum RAGVectorBackend: String, CaseIterable, Codable, Sendable {
    case sqlite
    case qdrant
}

struct RAGMeilisearchConfiguration: Codable, Equatable, Sendable {
    var endpoint = "http://127.0.0.1:7700"
    var indexName = "starcat_rag_chunks"

    var validationMessage: String? {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return "Meilisearch endpoint 无效"
        }
        return Self.isValidIdentifier(indexName) ? nil : "Meilisearch index 只能包含字母、数字、- 和 _"
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct RAGQdrantConfiguration: Codable, Equatable, Sendable {
    var endpoint = "http://127.0.0.1:6333"
    var collectionName = "starcat_rag_chunks"
    var vectorName = "content"

    var validationMessage: String? {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return "Qdrant endpoint 无效"
        }
        if !Self.isValidIdentifier(collectionName) { return "Qdrant collection 只能包含字母、数字、- 和 _" }
        if !Self.isValidIdentifier(vectorName) { return "Qdrant vector name 只能包含字母、数字、- 和 _" }
        return nil
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct RAGBackendConfiguration: Codable, Equatable, Sendable {
    static let meilisearchKeychainID = "rag-backend-meilisearch"
    static let qdrantKeychainID = "rag-backend-qdrant"

    var keywordBackend: RAGKeywordBackend = .sqliteFTS5
    var vectorBackend: RAGVectorBackend = .sqlite
    var fallbackToSQLite = true
    var meilisearch = RAGMeilisearchConfiguration()
    var qdrant = RAGQdrantConfiguration()
}

enum RAGExternalBackendError: Error, LocalizedError {
    case invalidConfiguration(String)
    case http(backend: String, status: Int, message: String)
    case invalidResponse(String)
    case operationFailed(backend: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .http(let backend, let status, let message): return "\(backend) HTTP \(status)：\(message)"
        case .invalidResponse(let backend): return "\(backend) 返回了无法解析的数据"
        case .operationFailed(let backend, let message): return "\(backend) 操作失败：\(message)"
        }
    }
}
