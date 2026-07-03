//
//  DiskExternalSearchCache.swift
//  Starcat
//
//  External Search 磁盘缓存。
//
//  关键约束：
//  - 缓存根目录使用 `external-search-cache/`，与旧 AnySearch 缓存隔离；
//  - global cache 按 provider 分目录，避免不同服务同 query 结果互相污染；
//  - credentialTest 永远不写缓存，避免设置页连通性检测污染业务搜索结果；
//  - 失败和 0 命中不写缓存，下一次搜索仍按真实 Provider 状态处理。
//

import CryptoKit
import Foundation
import Observation

enum DiskExternalSearchCacheError: LocalizedError {
    case applicationSupportUnavailable
    case unsafeKey(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("cache.anySearch.error.applicationSupportUnavailable")
        case .unsafeKey(let value):
            return String(format: String.l10n("cache.anySearch.error.unsafeKeyFormat"), value)
        }
    }
}

enum ExternalSearchCacheKind: String, Sendable {
    case global
    case aiContext = "ai-context"
}

@MainActor
@Observable
final class DiskExternalSearchCache {
    static let shared = DiskExternalSearchCache()

    static let globalTTL: TimeInterval = 6 * 60 * 60
    static let aiContextTTL: TimeInterval = 24 * 60 * 60

    private(set) var totalBytes: Int64 = 0
    private(set) var itemCount: Int = 0

    private let fileManager: FileManager
    private let rootOverride: URL?

    private let valueEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let valueDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let keyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    func loadGlobal(
        provider: ExternalSearchProviderID,
        request: ExternalSearchRequest
    ) async throws -> ExternalSearchResponse? {
        guard request.purpose != .credentialTest else { return nil }
        let key = try Self.globalCacheKey(provider: provider, request: request, encoder: keyEncoder)
        let fileURL = try globalFile(provider: provider, key: key)
        return try loadAndTouch(at: fileURL, maxIdle: Self.globalTTL, decode: ExternalSearchResponse.self)
    }

    func saveGlobal(
        provider: ExternalSearchProviderID,
        request: ExternalSearchRequest,
        response: ExternalSearchResponse
    ) async throws {
        guard request.purpose != .credentialTest, !response.hits.isEmpty else { return }
        let key = try Self.globalCacheKey(provider: provider, request: request, encoder: keyEncoder)
        let fileURL = try globalFile(provider: provider, key: key)
        try writeAtomically(response, to: fileURL)
    }

    func loadAIContext(
        provider: ExternalSearchProviderID,
        repoID: Int64,
        queryFingerprint: String
    ) async throws -> ExternalSearchResponse? {
        guard repoID > 0, !queryFingerprint.isEmpty else { return nil }
        let fileURL = try aiContextFile(provider: provider, repoID: repoID, queryFingerprint: queryFingerprint)
        return try loadAndTouch(at: fileURL, maxIdle: Self.aiContextTTL, decode: ExternalSearchResponse.self)
    }

    func saveAIContext(
        provider: ExternalSearchProviderID,
        repoID: Int64,
        queryFingerprint: String,
        response: ExternalSearchResponse
    ) async throws {
        guard repoID > 0, !queryFingerprint.isEmpty, !response.hits.isEmpty else { return }
        let fileURL = try aiContextFile(provider: provider, repoID: repoID, queryFingerprint: queryFingerprint)
        try writeAtomically(response, to: fileURL)
    }

    func deleteEverything() async throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        reload()
    }

    func reload() {
        guard let root = try? rootURL(), fileManager.fileExists(atPath: root.path) else {
            totalBytes = 0
            itemCount = 0
            return
        }
        let files = collectJSONFiles(under: root)
        itemCount = files.count
        totalBytes = files.reduce(Int64(0)) { total, url in
            let size = ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    nonisolated static func globalCacheKey(
        provider: ExternalSearchProviderID,
        request: ExternalSearchRequest,
        encoder: JSONEncoder
    ) throws -> String {
        let payload = GlobalKeyPayload(provider: provider, request: request)
        let data = try encoder.encode(payload)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadAndTouch<T: Decodable>(
        at fileURL: URL,
        maxIdle: TimeInterval,
        decode type: T.Type
    ) throws -> T? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
        let modifiedAt = (attrs[.modificationDate] as? Date) ?? .distantPast
        guard Date().timeIntervalSince(modifiedAt) <= maxIdle else {
            try? fileManager.removeItem(at: fileURL)
            reload()
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let value = try valueDecoder.decode(type, from: data)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return value
        } catch {
            try? fileManager.removeItem(at: fileURL)
            reload()
            return nil
        }
    }

    private func writeAtomically<T: Encodable>(_ value: T, to fileURL: URL) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try valueEncoder.encode(value)
        try data.write(to: fileURL, options: [.atomic])
        reload()
    }

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskExternalSearchCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("external-search-cache", isDirectory: true)
    }

    private func globalFile(provider: ExternalSearchProviderID, key: String) throws -> URL {
        try Self.assertHexKey(key)
        return try rootURL()
            .appendingPathComponent(ExternalSearchCacheKind.global.rawValue, isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(key).json")
    }

    private func aiContextFile(
        provider: ExternalSearchProviderID,
        repoID: Int64,
        queryFingerprint: String
    ) throws -> URL {
        let key = Self.sha256Hex("\(provider.rawValue)|\(repoID)|\(queryFingerprint)")
        return try rootURL()
            .appendingPathComponent(ExternalSearchCacheKind.aiContext.rawValue, isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent("\(repoID)", isDirectory: true)
            .appendingPathComponent("\(key).json")
    }

    private func collectJSONFiles(under dir: URL) -> [URL] {
        var out: [URL] = []
        let children = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            if child.hasDirectoryPath {
                out.append(contentsOf: collectJSONFiles(under: child))
            } else if child.pathExtension == "json" {
                out.append(child)
            }
        }
        return out
    }

    private static func assertHexKey(_ key: String) throws {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else {
            throw DiskExternalSearchCacheError.unsafeKey(key)
        }
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct GlobalKeyPayload: Encodable {
    let provider: ExternalSearchProviderID
    let request: ExternalSearchRequest
}
