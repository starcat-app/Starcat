//
//  RAGExternalSearchProviders.swift
//  Starcat
//
//  Meilisearch keyword provider 与 Qdrant vector provider 的 REST 实现。
//
//  外部服务只保存可重建 chunk/embedding；检索结果最终按 chunk id 回读本地数据库，确保
//  citation 内容、知识库边界和历史元数据仍以 Starcat 本地真值为准。
//

import Foundation

/// 多个 source diff 在一轮 embedding 前合并成最小变更集。同一 ID 后来又被写入时，
/// upsert 覆盖 delete，避免 debounce 窗口内先删后建最终把新分片误删。
struct RAGExternalIndexChangeSet: Equatable, Sendable {
    private(set) var upsertIDs: Set<Int64> = []
    private(set) var deletedSources: [Int64: RAGChunkSource] = [:]
    private(set) var revision: UInt64 = 0

    var isEmpty: Bool { upsertIDs.isEmpty && deletedSources.isEmpty }

    mutating func merge(_ result: RAGChunkSyncResult) {
        recordDeletes(result.deletedChunks)
        recordUpserts(result.affectedChunkIDs)
    }

    mutating func recordUpserts(_ ids: some Sequence<Int64>) {
        var didChange = false
        for id in ids {
            deletedSources[id] = nil
            upsertIDs.insert(id)
            didChange = true
        }
        if didChange { revision &+= 1 }
    }

    mutating func recordDeletes(_ chunks: some Sequence<RAGDeletedChunkIdentity>) {
        var didChange = false
        for chunk in chunks {
            upsertIDs.remove(chunk.id)
            deletedSources[chunk.id] = chunk.source
            didChange = true
        }
        if didChange { revision &+= 1 }
    }

    /// 网络 await 期间若又有 source diff 进入，保留整份变更集重试，不误清新修订。
    mutating func markSynced(revision syncedRevision: UInt64) {
        guard revision == syncedRevision else { return }
        upsertIDs.removeAll(keepingCapacity: true)
        deletedSources.removeAll(keepingCapacity: true)
    }

    mutating func reset() {
        upsertIDs.removeAll()
        deletedSources.removeAll()
        revision = 0
    }
}

/// 把本地变更集投影为两个外部后端的独立操作。Qdrant 只接受当前模型的
/// ready 向量；Metadata 是 FTS-only，无论更新还是删除都不得产生 Qdrant 请求。
struct RAGExternalIndexSyncPlan: Sendable {
    var keywordUpserts: [RAGChunk]
    var keywordDeleteIDs: [Int64]
    var vectorUpserts: [RAGChunk]
    var vectorDeleteIDs: [Int64]

    init(
        changes: RAGExternalIndexChangeSet,
        currentChunks: [RAGChunk],
        publicKnowledgeRepoIDs: Set<Int64>,
        model: String
    ) {
        let currentByID = Dictionary(uniqueKeysWithValues: currentChunks.compactMap { chunk in
            chunk.id.map { ($0, chunk) }
        })
        let keywordUpserts = changes.upsertIDs.compactMap { currentByID[$0] }.filter { chunk in
            guard publicKnowledgeRepoIDs.contains(chunk.repoId) else { return false }
            return chunk.source == .metadata
                || (chunk.embeddingStatus == .ready && chunk.embeddingModel == model)
        }
        let keywordUpsertIDs = Set(keywordUpserts.compactMap(\.id))
        let keywordDeleteIDs = Set(changes.deletedSources.keys)
            .union(changes.upsertIDs.subtracting(keywordUpsertIDs))

        let vectorUpserts = keywordUpserts.filter { chunk in
            chunk.source != .metadata && !chunk.vector.isEmpty
        }
        let vectorUpsertIDs = Set(vectorUpserts.compactMap(\.id))
        let changedVectorIDs = changes.upsertIDs.filter { id in
            currentByID[id]?.source != .metadata
        }
        let deletedVectorIDs = changes.deletedSources.compactMap { id, source in
            source == .metadata ? nil : id
        }

        self.keywordUpserts = keywordUpserts.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        self.keywordDeleteIDs = keywordDeleteIDs.sorted()
        self.vectorUpserts = vectorUpserts.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        self.vectorDeleteIDs = Set(deletedVectorIDs)
            .union(changedVectorIDs.filter { !vectorUpsertIDs.contains($0) })
            .sorted()
    }
}

struct FallbackRAGKeywordSearchProvider: RAGKeywordSearchProvider {
    let backendName: String
    private let primary: any RAGKeywordSearchProvider
    private let fallback: any RAGKeywordSearchProvider
    private let fallbackToSQLite: Bool

    init(
        primary: any RAGKeywordSearchProvider,
        fallback: any RAGKeywordSearchProvider,
        fallbackToSQLite: Bool = true
    ) {
        self.primary = primary
        self.fallback = fallback
        self.fallbackToSQLite = fallbackToSQLite
        self.backendName = fallbackToSQLite ? "\(primary.backendName) → \(fallback.backendName)" : primary.backendName
    }

    func search(query: RAGKeywordSearchQuery, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        do {
            let hits = try await primary.search(query: query, model: model, repoIDs: repoIDs, limit: limit)
            guard hits.isEmpty, fallbackToSQLite else { return hits }
            return try await fallback.search(query: query, model: model, repoIDs: repoIDs, limit: limit)
        } catch {
            try RAGExternalBackendFallbackPolicy.handle(error, fallbackToSQLite: fallbackToSQLite)
            return try await fallback.search(query: query, model: model, repoIDs: repoIDs, limit: limit)
        }
    }
}

struct FallbackRAGVectorSearchProvider: RAGVectorSearchProvider {
    let backendName: String
    private let primary: any RAGVectorSearchProvider
    private let fallback: any RAGVectorSearchProvider
    private let fallbackToSQLite: Bool

    init(
        primary: any RAGVectorSearchProvider,
        fallback: any RAGVectorSearchProvider,
        fallbackToSQLite: Bool = true
    ) {
        self.primary = primary
        self.fallback = fallback
        self.fallbackToSQLite = fallbackToSQLite
        self.backendName = fallbackToSQLite ? "\(primary.backendName) → \(fallback.backendName)" : primary.backendName
    }

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        do {
            let hits = try await primary.search(queryVector: queryVector, model: model, repoIDs: repoIDs, limit: limit)
            guard hits.isEmpty, fallbackToSQLite else { return hits }
            return try await fallback.search(queryVector: queryVector, model: model, repoIDs: repoIDs, limit: limit)
        } catch {
            try RAGExternalBackendFallbackPolicy.handle(error, fallbackToSQLite: fallbackToSQLite)
            return try await fallback.search(queryVector: queryVector, model: model, repoIDs: repoIDs, limit: limit)
        }
    }
}

struct MeilisearchRAGProvider: RAGKeywordSearchProvider {
    let backendName = "Meilisearch"
    private let configuration: RAGMeilisearchConfiguration
    private let apiKey: String?
    private let repository: any RAGChunkRepositoryProtocol
    private let httpClient: any RAGHTTPClientProtocol

    init(
        configuration: RAGMeilisearchConfiguration,
        apiKey: String?,
        repository: any RAGChunkRepositoryProtocol,
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient()
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.repository = repository
        self.httpClient = httpClient
    }

    func search(query: RAGKeywordSearchQuery, model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        try validate()
        let filter = "repo_id IN [\(repoIDs.map(String.init).joined(separator: ","))] AND ((embedding_model = \"\(escape(model))\" AND embedding_status = \"ready\") OR embedding_status = \"keyword_only\")"
        let body: [String: Any] = ["q": query.externalQuery, "limit": limit, "filter": filter, "attributesToRetrieve": ["id"]]
        let data = try await request(path: "indexes/\(configuration.indexName)/search", method: "POST", json: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = object["hits"] as? [[String: Any]] else {
            throw RAGExternalBackendError.invalidResponse(backendName)
        }
        let ids = hits.compactMap { value -> Int64? in
            if let id = value["id"] as? Int64 { return id }
            if let id = value["id"] as? Int { return Int64(id) }
            if let id = value["id"] as? String { return Int64(id) }
            return nil
        }
        let chunks = try await repository.fetchChunks(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: chunks.compactMap { chunk in chunk.id.map { ($0, chunk) } })
        return ids.enumerated().compactMap { index, id in
            byID[id].map { RAGChildHit(chunk: $0, score: 1 / Double(index + 1), kind: .keyword) }
        }
    }

    func replaceAll(chunks: [RAGChunk]) async throws {
        try validate()
        do {
            try await enqueueAndWait(
                path: "indexes/\(configuration.indexName)/documents",
                method: "DELETE",
                json: nil
            )
        } catch let RAGExternalBackendError.http(_, status, _) where status == 404 {
            // 首次同步时 index 尚不存在，后续 documents/settings 写入会创建它。
        }
        try await upsertDocuments(chunks)
        try await enqueueAndWait(
            path: "indexes/\(configuration.indexName)/settings/filterable-attributes",
            method: "PUT",
            json: ["repo_id", "embedding_model", "embedding_status"]
        )
    }

    /// 增量同步不清空 index；Meilisearch task 仍逐个等待完成，避免后续检索看到半轮状态。
    func applyChanges(upserts: [RAGChunk], deleteIDs: [Int64]) async throws {
        try validate()
        for batch in deleteIDs.chunked(into: 500) where !batch.isEmpty {
            try await enqueueAndWait(
                path: "indexes/\(configuration.indexName)/documents/delete-batch",
                method: "POST",
                json: batch
            )
        }
        try await upsertDocuments(upserts)
    }

    private func upsertDocuments(_ chunks: [RAGChunk]) async throws {
        for batch in chunks.chunked(into: 500) {
            let documents: [[String: Any]] = batch.compactMap { chunk in
                guard let id = chunk.id else { return nil }
                return [
                    "id": id,
                    "repo_id": chunk.repoId,
                    "title": chunk.title,
                    "section_path": chunk.sectionPath,
                    "content": chunk.content,
                    "source": chunk.source.rawValue,
                    "embedding_model": chunk.embeddingModel ?? "",
                    "embedding_status": chunk.embeddingStatus.rawValue
                ]
            }
            try await enqueueAndWait(
                path: "indexes/\(configuration.indexName)/documents?primaryKey=id",
                method: "POST",
                json: documents
            )
        }
    }

    func testConnection() async throws {
        try validate()
        _ = try await request(path: "health", method: "GET", json: nil)
    }

    private func validate() throws {
        if let message = configuration.validationMessage { throw RAGExternalBackendError.invalidConfiguration(message) }
    }

    private func request(path: String, method: String, json: Any?) async throws -> Data {
        let base = configuration.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)") else {
            throw RAGExternalBackendError.invalidConfiguration(
                String.l10n("rag.core.backend.error.meilisearchURL")
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, response) = try await httpClient.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw RAGExternalBackendError.http(backend: backendName, status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Meilisearch 写 API 只返回已入队 task。必须等 task 成功后再执行下一步，既保证
    /// delete -> import -> settings 的顺序，也避免把异步失败误报成“外部索引已完成”。
    private func enqueueAndWait(path: String, method: String, json: Any?) async throws {
        let data = try await request(path: path, method: method, json: json)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskUID = (object["taskUid"] as? NSNumber)?.intValue else {
            throw RAGExternalBackendError.invalidResponse("\(backendName) task")
        }
        for _ in 0..<120 {
            try Task.checkCancellation()
            let taskData = try await request(path: "tasks/\(taskUID)", method: "GET", json: nil)
            guard let task = try JSONSerialization.jsonObject(with: taskData) as? [String: Any],
                  let status = task["status"] as? String else {
                throw RAGExternalBackendError.invalidResponse("\(backendName) task")
            }
            switch status {
            case "succeeded":
                return
            case "failed", "canceled":
                let error = task["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "task \(taskUID) \(status)"
                throw RAGExternalBackendError.operationFailed(backend: backendName, message: message)
            default:
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw RAGExternalBackendError.operationFailed(
            backend: backendName,
            message: String(
                format: String.l10n("rag.core.backend.error.taskTimeoutFormat"),
                taskUID
            )
        )
    }

    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "\\\"") }
}

struct QdrantRAGProvider: RAGVectorSearchProvider {
    let backendName = "Qdrant"
    private let configuration: RAGQdrantConfiguration
    private let apiKey: String?
    private let repository: any RAGChunkRepositoryProtocol
    private let httpClient: any RAGHTTPClientProtocol

    init(
        configuration: RAGQdrantConfiguration,
        apiKey: String?,
        repository: any RAGChunkRepositoryProtocol,
        httpClient: any RAGHTTPClientProtocol = URLSessionRAGHTTPClient()
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.repository = repository
        self.httpClient = httpClient
    }

    func search(queryVector: [Float], model: String, repoIDs: [Int64], limit: Int) async throws -> [RAGChildHit] {
        try validate()
        let body: [String: Any] = [
            "query": queryVector,
            "using": configuration.vectorName,
            "filter": ["must": [
                ["key": "repo_id", "match": ["any": repoIDs]],
                ["key": "embedding_model", "match": ["value": model]]
            ]],
            "limit": limit,
            "with_payload": false
        ]
        let response = try await request(path: collectionPath("points/query"), method: "POST", json: body, accepted: 200..<300)
        let data = response.data
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RAGExternalBackendError.invalidResponse(backendName)
        }
        let rawResult: [[String: Any]]
        if let values = object["result"] as? [[String: Any]] {
            rawResult = values
        } else if let result = object["result"] as? [String: Any], let values = result["points"] as? [[String: Any]] {
            rawResult = values
        } else {
            throw RAGExternalBackendError.invalidResponse(backendName)
        }
        let scoredIDs: [(Int64, Double)] = rawResult.compactMap { value in
            let id: Int64?
            if let raw = value["id"] as? Int { id = Int64(raw) }
            else if let raw = value["id"] as? Int64 { id = raw }
            else if let raw = value["id"] as? String { id = Int64(raw) }
            else { id = nil }
            guard let id, let score = value["score"] as? Double else { return nil }
            return (id, score)
        }
        let chunks = try await repository.fetchChunks(ids: scoredIDs.map(\.0))
        let byID = Dictionary(uniqueKeysWithValues: chunks.compactMap { chunk in chunk.id.map { ($0, chunk) } })
        return scoredIDs.compactMap { id, score in
            byID[id].map {
                RAGChildHit(
                    chunk: $0,
                    score: score,
                    kind: .vector,
                    vectorSimilarity: score
                )
            }
        }
    }

    func replaceAll(chunks: [RAGChunk]) async throws {
        try validate()
        let dimension = chunks.first(where: { !$0.vector.isEmpty })?.vector.count
        guard try await ensureCollection(expectedDimension: dimension) else { return }
        _ = try await request(
            path: collectionPath("points/delete?wait=true"),
            method: "POST",
            json: ["filter": [:]],
            accepted: 200..<300
        )
        try await upsertPoints(chunks)
    }

    /// 增量路径只删除指定 point ID，不使用空 filter 清空 collection。
    func applyChanges(upserts: [RAGChunk], deleteIDs: [Int64]) async throws {
        try validate()
        guard !upserts.isEmpty || !deleteIDs.isEmpty else { return }
        let dimension = upserts.first(where: { !$0.vector.isEmpty })?.vector.count
        guard try await ensureCollection(expectedDimension: dimension) else { return }
        for batch in deleteIDs.chunked(into: 256) where !batch.isEmpty {
            _ = try await request(
                path: collectionPath("points/delete?wait=true"),
                method: "POST",
                json: ["points": batch],
                accepted: 200..<300
            )
        }
        try await upsertPoints(upserts)
    }

    /// 返回 false 表示 collection 不存在且本轮没有向量可用于建表。
    private func ensureCollection(expectedDimension dimension: Int?) async throws -> Bool {
        let collectionResponse = try await request(
            path: "collections/\(configuration.collectionName)",
            method: "GET",
            json: nil,
            accepted: 200..<500
        )
        if collectionResponse.status == 404 {
            guard let dimension else { return false }
            _ = try await request(
                path: "collections/\(configuration.collectionName)",
                method: "PUT",
                json: ["vectors": [configuration.vectorName: ["size": dimension, "distance": "Cosine"]]],
                accepted: 200..<300
            )
        } else if !(200..<300).contains(collectionResponse.status) {
            throw RAGExternalBackendError.http(backend: backendName, status: collectionResponse.status, message: String(data: collectionResponse.data, encoding: .utf8) ?? "")
        } else {
            try validateCollection(data: collectionResponse.data, expectedDimension: dimension)
        }
        return true
    }

    private func upsertPoints(_ chunks: [RAGChunk]) async throws {
        for batch in chunks.chunked(into: 128) {
            let points: [[String: Any]] = batch.compactMap { chunk in
                guard let id = chunk.id, !chunk.vector.isEmpty else { return nil }
                return [
                    "id": id,
                    "vector": [configuration.vectorName: chunk.vector],
                    "payload": [
                        "repo_id": chunk.repoId,
                        "embedding_model": chunk.embeddingModel ?? "",
                        "source": chunk.source.rawValue,
                        "parent_key": chunk.parentKey
                    ]
                ]
            }
            _ = try await request(
                path: collectionPath("points?wait=true"),
                method: "PUT",
                json: ["points": points],
                accepted: 200..<300
            )
        }
    }

    func testConnection() async throws {
        try validate()
        _ = try await request(path: "healthz", method: "GET", json: nil, accepted: 200..<300)
        let collectionResponse = try await request(
            path: "collections/\(configuration.collectionName)",
            method: "GET",
            json: nil,
            accepted: 200..<500
        )
        if collectionResponse.status == 404 {
            // 新 collection 会在首次重建时按当前 embedding dimension 创建。
            return
        }
        guard (200..<300).contains(collectionResponse.status) else {
            throw RAGExternalBackendError.http(
                backend: backendName,
                status: collectionResponse.status,
                message: String(data: collectionResponse.data, encoding: .utf8) ?? ""
            )
        }
        try validateCollection(data: collectionResponse.data, expectedDimension: nil)
    }

    private func validate() throws {
        if let message = configuration.validationMessage { throw RAGExternalBackendError.invalidConfiguration(message) }
    }

    /// Starcat 创建的是 named vector collection。若用户连接到已有 collection，必须在删除旧点位前
    /// 验证 vector name 和维度，避免误清空不兼容的 collection 后才在 upsert 阶段失败。
    private func validateCollection(data: Data, expectedDimension: Int?) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let config = result["config"] as? [String: Any],
              let params = config["params"] as? [String: Any],
              let vectors = params["vectors"] as? [String: Any],
              let vector = vectors[configuration.vectorName] as? [String: Any] else {
            throw RAGExternalBackendError.invalidConfiguration(String(
                format: String.l10n("rag.core.backend.error.qdrantVectorMissingFormat"),
                configuration.vectorName
            ))
        }
        if let expectedDimension {
            let size = (vector["size"] as? NSNumber)?.intValue
            guard size == expectedDimension else {
                throw RAGExternalBackendError.invalidConfiguration(String(
                    format: String.l10n("rag.core.backend.error.qdrantDimensionMismatchFormat"),
                    size.map(String.init) ?? "unknown",
                    expectedDimension
                ))
            }
        }
    }

    private func collectionPath(_ suffix: String) -> String {
        "collections/\(configuration.collectionName)/\(suffix)"
    }

    private func request(
        path: String,
        method: String,
        json: Any?,
        accepted: Range<Int>
    ) async throws -> (data: Data, status: Int) {
        let base = configuration.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(path)") else {
            throw RAGExternalBackendError.invalidConfiguration(
                String.l10n("rag.core.backend.error.qdrantURL")
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "api-key") }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, response) = try await httpClient.data(for: request)
        guard accepted.contains(response.statusCode) else {
            throw RAGExternalBackendError.http(backend: backendName, status: response.statusCode, message: String(data: data, encoding: .utf8) ?? "")
        }
        return (data, response.statusCode)
    }

}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
