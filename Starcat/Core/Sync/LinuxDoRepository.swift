//
//  LinuxDoRepository.swift
//  Starcat
//
//  Linux.do 的条件刷新与旧缓存迁移。SwiftUI 只读取目录摘要、当前页或一批来源 ID。
//

import CryptoKit
import Foundation

/// 以服务身份隔离公共缓存。同一资源的刷新合并，只有 SQLite 事务成功才发布新版本。
actor LinuxDoRepository {
    static let freshnessInterval: TimeInterval = 30 * 60
    private let api: any LinuxDoAPIProtocol
    private let directory: URL
    private let now: @Sendable () -> Date
    private var sqlite: LinuxDoSQLiteCache?
    private var checkedLegacyKeys: Set<String> = []
    private var inflight: [String: Task<LinuxDoCacheMetadata, Error>] = [:]

    init(api: any LinuxDoAPIProtocol, directory: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("linuxdo-v1", isDirectory: true)
        self.now = now
    }

    func providerIdentity() async -> String { await api.linuxDoProviderIdentity() }

    func catalogSummary(providerID: String) throws -> LinuxDoCatalogSummary? {
        _ = try cached(.catalog, providerID: providerID)
        return try database().catalogSummary(providerID: providerID)
    }

    func page(
        key: LinuxDoCatalogKey, query: LinuxDoCatalogQuery, memberships: [LinuxDoRepoMembership] = [],
        limit: Int = ListPaginationPolicy.repoCardPageSize, offset: Int = 0, knownTotal: Int? = nil
    ) throws -> LinuxDoCatalogPage? {
        try database().page(key: key, query: query, memberships: memberships, limit: limit, offset: offset, knownTotal: knownTotal)
    }

    func signalCandidates(key: LinuxDoCatalogKey, query: LinuxDoCatalogQuery) throws -> [WikiAvailabilityRequest] {
        try database().signalCandidates(key: key, query: query)
    }

    func verifiedIDs(_ ids: [Int64], providerID: String) throws -> Set<Int64> {
        try database().verifiedIDs(ids, providerID: providerID, now: now())
    }

    func contains(repoID: Int64, providerID: String) throws -> Bool {
        try database().contains(repoID: repoID, providerID: providerID)
    }

    func discussionURL(repoID: Int64, providerID: String, minimumRevision: Int64) throws -> URL? {
        _ = try cached(.topics(repoID), providerID: providerID)
        return try database().discussionURL(repoID: repoID, providerID: providerID, minimumRevision: minimumRevision)
    }

    /// 按原资源键惰性导入。只有事务成功才移除旧 JSON，断网启动与升级中断均可恢复。
    func cached(_ resource: LinuxDoResource, providerID: String) throws -> LinuxDoCacheMetadata? {
        let cache = try database()
        if let metadata = try cache.metadata(resource, providerID: providerID) { return metadata }
        let key = cacheKey(resource, providerID: providerID)
        guard !checkedLegacyKeys.contains(key) else { return nil }
        let file = directory.appendingPathComponent(key + ".json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 24 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(LinuxDoCachedSnapshot.self, from: data),
              snapshot.providerID == providerID,
              (try? snapshot.payload.validate(for: resource)) != nil else {
            checkedLegacyKeys.insert(key)
            return nil
        }
        let metadata = LinuxDoCacheMetadata(revision: snapshot.payload.revision, etag: snapshot.etag, checkedAt: snapshot.checkedAt)
        try cache.save(snapshot.payload, metadata: metadata, resource: resource, providerID: providerID)
        try? FileManager.default.removeItem(at: file)
        return metadata
    }

    /// 强制刷新绕过 TTL，依然发送 ETag。304 与已缓存版本只更新校验时间。
    func refresh(_ resource: LinuxDoResource, providerID: String, force: Bool = false) async throws -> LinuxDoCacheMetadata {
        let key = cacheKey(resource, providerID: providerID)
        if let pending = inflight[key] { return try await pending.value }
        let previous = try cached(resource, providerID: providerID)
        if !force, let previous, now().timeIntervalSince(previous.checkedAt) < Self.freshnessInterval { return previous }
        let task = Task { try await self.fetchAndSave(resource, providerID: providerID, previous: previous) }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    /// API 挂起时允许读旧页；返回后重新核对服务身份，再以同一事务提交正文与元数据。
    private func fetchAndSave(
        _ resource: LinuxDoResource, providerID: String, previous: LinuxDoCacheMetadata?
    ) async throws -> LinuxDoCacheMetadata {
        let diagnostic = DiagnosticOperation(category: "linuxdo", name: "refresh",
            fields: ["hasCachedBody": .boolean(previous != nil)])
        var outcome: DiagnosticEvent.Outcome = .failed
        defer { diagnostic.finish(Task.isCancelled ? .cancelled : outcome) }
        let response = try await api.fetchLinuxDo(resource, providerID: providerID, ifNoneMatch: previous?.etag)
        guard await api.linuxDoProviderIdentity() == providerID else { throw CancellationError() }
        guard let revision = response.payload?.revision ?? previous?.revision else { throw LinuxDoCacheError.missingCachedBody }
        if let previous, revision < previous.revision { throw LinuxDoCacheError.obsoleteRevision }
        try response.payload?.validateStructure(for: resource)
        let changedBody = revision == previous?.revision ? nil : response.payload
        try changedBody?.validate(for: resource)
        let etag = response.payload == nil ? response.etag ?? previous?.etag : response.etag
        let metadata = LinuxDoCacheMetadata(revision: revision, etag: etag, checkedAt: now())
        try database().save(changedBody, metadata: metadata, resource: resource, providerID: providerID)
        diagnostic.event(phase: "cacheSaved", fields: ["notModified": .boolean(changedBody == nil)])
        outcome = .succeeded
        return metadata
    }

    private func database() throws -> LinuxDoSQLiteCache {
        if let sqlite { return sqlite }
        let cache = try LinuxDoSQLiteCache(directory: directory)
        sqlite = cache
        return cache
    }

    private func cacheKey(_ resource: LinuxDoResource, providerID: String) -> String {
        SHA256.hash(data: Data((providerID + "/" + resource.path).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
