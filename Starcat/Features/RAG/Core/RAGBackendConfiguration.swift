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
            return String.l10n("rag.core.backend.error.meilisearchEndpoint")
        }
        return Self.isValidIdentifier(indexName)
            ? nil
            : String.l10n("rag.core.backend.error.meilisearchIndex")
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
            return String.l10n("rag.core.backend.error.qdrantEndpoint")
        }
        if !Self.isValidIdentifier(collectionName) {
            return String.l10n("rag.core.backend.error.qdrantCollection")
        }
        if !Self.isValidIdentifier(vectorName) {
            return String.l10n("rag.core.backend.error.qdrantVectorName")
        }
        return nil
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Starcat 第一阶段支持的 Rerank HTTP 协议。
///
/// 不以“模型”作为协议判断条件：同一模型可由不同服务承载，而请求/响应字段才决定客户端适配方式。
enum RAGRerankProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case huggingFaceTEI = "huggingface_tei"
    case cohereCompatible = "cohere_compatible"

    var id: String { rawValue }

    var defaultEndpoint: String {
        switch self {
        case .huggingFaceTEI: return "http://127.0.0.1:8080/rerank"
        case .cohereCompatible: return "https://api.cohere.com/v2/rerank"
        }
    }

}

/// Rerank 是召回后的可选重排序步骤；地址、协议、模型和开关均由用户控制，不假定服务位于本机。
struct RAGRerankConfiguration: Codable, Equatable, Sendable {
    /// API Token 与配置分开存放，避免令牌进入 UserDefaults、Debug Trace 或导出文件。
    static let keychainID = "rag-rerank"

    var isEnabled = false
    var provider: RAGRerankProvider = .huggingFaceTEI
    var endpoint = RAGRerankProvider.huggingFaceTEI.defaultEndpoint
    var model = ""
    var candidateLimit = 24

    var normalized: RAGRerankConfiguration {
        var value = self
        value.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.candidateLimit = min(max(candidateLimit, 10), 60)
        return value
    }

    var validationMessage: String? {
        let value = normalized
        guard let url = URL(string: value.endpoint),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return String.l10n("rag.core.backend.error.rerankEndpoint") }
        if value.provider == .cohereCompatible, value.model.isEmpty {
            return String.l10n("rag.core.backend.error.cohereModelEmpty")
        }
        return nil
    }

    /// 初版曾只保存 endpoint/model/candidateLimit；缺少 provider 时按原 Cohere 风格协议读取，
    /// 既不让已保存设置解码失败，也不会把旧地址误发成 TEI 请求。
    init(
        isEnabled: Bool = false,
        provider: RAGRerankProvider = .huggingFaceTEI,
        endpoint: String = RAGRerankProvider.huggingFaceTEI.defaultEndpoint,
        model: String = "",
        candidateLimit: Int = 24
    ) {
        self.isEnabled = isEnabled
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.candidateLimit = candidateLimit
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, provider, endpoint, model, candidateLimit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        provider = try values.decodeIfPresent(RAGRerankProvider.self, forKey: .provider) ?? .cohereCompatible
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? provider.defaultEndpoint
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        candidateLimit = try values.decodeIfPresent(Int.self, forKey: .candidateLimit) ?? 24
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

    /// 禁用 SQLite 回退时，外部后端配置错误必须在装配阶段暴露，不能静默改用本地实现。
    func validateSelectedBackendsForRuntime() throws {
        guard !fallbackToSQLite else { return }
        if keywordBackend == .meilisearch, let message = meilisearch.validationMessage {
            throw RAGExternalBackendError.invalidConfiguration(message)
        }
        if vectorBackend == .qdrant, let message = qdrant.validationMessage {
            throw RAGExternalBackendError.invalidConfiguration(message)
        }
    }
}

/// 查询与索引同步共享同一错误边界：普通外部错误仅在用户允许时回退，取消永远向上传播。
enum RAGExternalBackendFallbackPolicy {
    static func handle(_ error: any Error, fallbackToSQLite: Bool) throws {
        if error is CancellationError { throw error }
        if !fallbackToSQLite { throw error }
    }
}

enum RAGExternalBackendError: Error, LocalizedError {
    case invalidConfiguration(String)
    case http(backend: String, status: Int, message: String)
    case invalidResponse(String)
    case operationFailed(backend: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .http(let backend, let status, let message):
            return String(
                format: String.l10n("rag.core.backend.error.httpFormat"),
                backend,
                status,
                message
            )
        case .invalidResponse(let backend):
            return String(format: String.l10n("rag.core.backend.error.invalidResponseFormat"), backend)
        case .operationFailed(let backend, let message):
            return String(
                format: String.l10n("rag.core.backend.error.operationFailedFormat"),
                backend,
                message
            )
        }
    }
}
