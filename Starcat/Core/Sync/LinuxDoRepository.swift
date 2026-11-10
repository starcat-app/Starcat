//
//  LinuxDoRepository.swift
//  Starcat
//
//  公共来源快照的有界磁盘/内存缓存。独立于账号数据库，不给 repos 表添加外键，
//  因而未收藏项目也能跨分类识别来源；缓存可以重建，不参与 CloudKit。
//

import CryptoKit
import Foundation

/// 同 key 请求合并；原子落盘成功后才接纳新快照，失败保留旧内容与校验头。
actor LinuxDoRepository {
    static let freshnessInterval: TimeInterval = 30 * 60
    private let api: any LinuxDoAPIProtocol
    private let directory: URL
    private let now: @Sendable () -> Date
    private var memory: [String: LinuxDoCachedSnapshot] = [:]
    private var memorySizes: [String: Int] = [:]
    private var inflight: [String: Task<LinuxDoCachedSnapshot, Error>] = [:]

    init(api: any LinuxDoAPIProtocol, directory: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("linuxdo-v1", isDirectory: true)
        self.now = now
    }

    func providerIdentity() async -> String { await api.linuxDoProviderIdentity() }

    /// 先读缓存的入口不会联网，列表/详情可以马上渲染已验证的数据。
    func cached(_ resource: LinuxDoResource, providerID: String) -> LinuxDoCachedSnapshot? {
        let key = cacheKey(resource, providerID: providerID)
        if let value = memory[key] { return value }
        let file = directory.appendingPathComponent(key + ".json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 24 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(LinuxDoCachedSnapshot.self, from: data),
              value.providerID == providerID,
              (try? value.payload.validate(for: resource)) != nil else { return nil }
        remember(value, key: key, bytes: data.count)
        return value
    }

    /// 强制刷新只绕过 TTL，不丢 ETag；304 更新新鲜度而不清空正文。
    func refresh(_ resource: LinuxDoResource, providerID: String, force: Bool = false) async throws -> LinuxDoCachedSnapshot {
        let key = cacheKey(resource, providerID: providerID)
        if let pending = inflight[key] { return try await pending.value }
        let previous = cached(resource, providerID: providerID)
        if !force, let previous, now().timeIntervalSince(previous.checkedAt) < Self.freshnessInterval { return previous }
        let task = Task { try await self.fetchAndSave(resource, providerID: providerID, previous: previous, key: key) }
        inflight[key] = task
        defer { inflight[key] = nil }
        return try await task.value
    }

    private func fetchAndSave(_ resource: LinuxDoResource, providerID: String, previous: LinuxDoCachedSnapshot?, key: String) async throws -> LinuxDoCachedSnapshot {
        let diagnostic = DiagnosticOperation(category: "linuxdo", name: "refresh",
            fields: ["hasCachedBody": .boolean(previous != nil)])
        var outcome: DiagnosticEvent.Outcome = .failed
        defer { diagnostic.finish(Task.isCancelled ? .cancelled : outcome) }
        let response = try await api.fetchLinuxDo(resource, providerID: providerID, ifNoneMatch: previous?.etag)
        guard await api.linuxDoProviderIdentity() == providerID else { throw CancellationError() }
        guard let payload = response.payload ?? previous?.payload else { throw LinuxDoCacheError.missingCachedBody }
        try payload.validate(for: resource)
        if let previous, payload.revision < previous.payload.revision { throw LinuxDoCacheError.obsoleteRevision }
        let etag = response.payload == nil ? (response.etag ?? previous?.etag) : response.etag
        let value = LinuxDoCachedSnapshot(providerID: providerID, payload: payload, etag: etag, checkedAt: now())
        let data = try JSONEncoder().encode(value)
        guard data.count <= 24 * 1024 * 1024 else { throw LinuxDoCacheError.invalidSnapshot }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
        remember(value, key: key, bytes: data.count)
        diagnostic.event(phase: "cacheSaved", fields: ["notModified": .boolean(response.payload == nil),
                                                     "cacheBytes": .integer(data.count)])
        outcome = .succeeded
        pruneDisk()
        return value
    }

    private func remember(_ value: LinuxDoCachedSnapshot, key: String, bytes: Int) {
        memory[key] = value
        memorySizes[key] = bytes
        while memory.count > 64 || memorySizes.values.reduce(0, +) > 32 * 1024 * 1024 {
            guard let oldest = memory.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key else { break }
            memory[oldest] = nil
            memorySizes[oldest] = nil
        }
    }

    private func cacheKey(_ resource: LinuxDoResource, providerID: String) -> String {
        SHA256.hash(data: Data((providerID + "/" + resource.path).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 只清理本组件自己生成的摘要文件，目录外文件和用户数据从不参与淘汰。
    private func pruneDisk() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard url.pathExtension == "json", url.deletingPathExtension().lastPathComponent.count == 64,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= 64 || bytes > 32 * 1024 * 1024 { try? FileManager.default.removeItem(at: entry.0) }
        }
    }
}
