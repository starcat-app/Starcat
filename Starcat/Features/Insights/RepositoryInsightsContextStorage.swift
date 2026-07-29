//
//  RepositoryInsightsContextStorage.swift
//  Starcat
//
//  仓库洞察 XML Artifact 的独立文件存储。
//
//  关键约束：
//  - 这里只管理 insights.xml、metadata.json 与删除抑制标记，绝不触碰洞察 SQLite 缓存。
//  - 每个账号作用域独立落盘，避免退出登录或切换账号后读取到私有仓库上下文。
//  - 同一 sourceHash 不重复写盘；用户删除后，同版本不会被后台任务立即重建。
//

import CryptoKit
import Foundation

struct RepositoryInsightsContextScope: Codable, Equatable, Hashable, Sendable {
    let userID: Int64?

    var storageKey: String {
        userID.map { "user-\($0)" } ?? "anonymous"
    }
}

struct RepositoryInsightsContextMetadata: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let repositoryID: Int64
    let repositoryFullName: String
    let accountStorageKey: String
    let generatedAt: Date
    let sourceHash: String
    let xmlHash: String
}

struct RepositoryInsightsContextArtifact: Equatable, Sendable {
    let document: RepositoryInsightsDocument
    let metadata: RepositoryInsightsContextMetadata
}

enum RepositoryInsightsContextWriteOutcome: Equatable, Sendable {
    case written(RepositoryInsightsContextArtifact)
    case unchanged(RepositoryInsightsContextArtifact)
    case suppressed
}

enum RepositoryInsightsContextStorageError: Error, Equatable {
    case applicationSupportUnavailable
    case invalidMetadata
    case invalidXML
    case repositoryMismatch
    case accountMismatch
    case hashMismatch
}

protocol RepositoryInsightsContextStoring: Sendable {
    func load(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) async throws -> RepositoryInsightsContextArtifact?

    func store(
        _ document: RepositoryInsightsDocument,
        scope: RepositoryInsightsContextScope,
        force: Bool
    ) async throws -> RepositoryInsightsContextWriteOutcome

    func delete(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) async throws
}

actor RepositoryInsightsContextStorage: RepositoryInsightsContextStoring {
    private struct DeletionMarker: Codable, Equatable, Sendable {
        let repositoryID: Int64
        let repositoryFullName: String
        let accountStorageKey: String
        let deletedSourceHash: String
        let deletedAt: Date
    }

    private static let metadataFileName = "metadata.json"
    private static let deletionDirectoryName = ".deleted"

    private let fileManager: FileManager
    private let fixedRootURL: URL?
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.fixedRootURL = rootURL
        self.now = now
    }

    func load(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) throws -> RepositoryInsightsContextArtifact? {
        let directory = try artifactDirectory(repositoryID: repositoryID, scope: scope)
        try recoverInterruptedReplacement(at: directory)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }

        let xmlURL = directory.appendingPathComponent(
            RepositoryInsightsDocument.fileName,
            isDirectory: false
        )
        let metadataURL = directory.appendingPathComponent(
            Self.metadataFileName,
            isDirectory: false
        )
        guard
            let xmlData = fileManager.contents(atPath: xmlURL.path),
            let metadataData = fileManager.contents(atPath: metadataURL.path)
        else {
            throw RepositoryInsightsContextStorageError.invalidMetadata
        }

        let metadata: RepositoryInsightsContextMetadata
        do {
            metadata = try Self.decoder().decode(
                RepositoryInsightsContextMetadata.self,
                from: metadataData
            )
        } catch {
            throw RepositoryInsightsContextStorageError.invalidMetadata
        }
        guard metadata.schemaVersion == RepositoryInsightsContextMetadata.schemaVersion else {
            throw RepositoryInsightsContextStorageError.invalidMetadata
        }
        guard metadata.repositoryID == repositoryID,
              metadata.repositoryFullName == repositoryFullName else {
            throw RepositoryInsightsContextStorageError.repositoryMismatch
        }
        guard metadata.accountStorageKey == scope.storageKey else {
            throw RepositoryInsightsContextStorageError.accountMismatch
        }
        guard metadata.xmlHash == Self.sha256(xmlData) else {
            throw RepositoryInsightsContextStorageError.hashMismatch
        }

        let xml: String
        if let value = String(data: xmlData, encoding: .utf8) {
            xml = value
        } else {
            throw RepositoryInsightsContextStorageError.invalidXML
        }
        try Self.validate(
            xmlData: xmlData,
            repositoryID: repositoryID,
            repositoryFullName: repositoryFullName,
            sourceHash: metadata.sourceHash
        )
        let document = RepositoryInsightsDocument(
            repositoryID: repositoryID,
            repositoryFullName: repositoryFullName,
            generatedAt: metadata.generatedAt,
            sourceHash: metadata.sourceHash,
            xml: xml
        )
        return RepositoryInsightsContextArtifact(document: document, metadata: metadata)
    }

    func store(
        _ document: RepositoryInsightsDocument,
        scope: RepositoryInsightsContextScope,
        force: Bool = false
    ) throws -> RepositoryInsightsContextWriteOutcome {
        let marker = try loadDeletionMarker(
            repositoryID: document.repositoryID,
            repositoryFullName: document.repositoryFullName,
            scope: scope
        )
        if !force, marker?.deletedSourceHash == document.sourceHash {
            return .suppressed
        }
        if let existing = try load(
            repositoryID: document.repositoryID,
            repositoryFullName: document.repositoryFullName,
            scope: scope
        ), existing.document.sourceHash == document.sourceHash {
            return .unchanged(existing)
        }

        let xmlData = Data(document.xml.utf8)
        try Self.validate(
            xmlData: xmlData,
            repositoryID: document.repositoryID,
            repositoryFullName: document.repositoryFullName,
            sourceHash: document.sourceHash
        )
        let metadata = RepositoryInsightsContextMetadata(
            schemaVersion: RepositoryInsightsContextMetadata.schemaVersion,
            repositoryID: document.repositoryID,
            repositoryFullName: document.repositoryFullName,
            accountStorageKey: scope.storageKey,
            generatedAt: document.generatedAt,
            sourceHash: document.sourceHash,
            xmlHash: Self.sha256(xmlData)
        )
        let artifact = RepositoryInsightsContextArtifact(document: document, metadata: metadata)
        let finalDirectory = try artifactDirectory(
            repositoryID: document.repositoryID,
            scope: scope
        )
        let parent = finalDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try replaceDirectoryAtomically(
            finalDirectory: finalDirectory,
            xmlData: xmlData,
            metadataData: try Self.encoder().encode(metadata)
        )
        try removeDeletionMarker(repositoryID: document.repositoryID, scope: scope)
        return .written(artifact)
    }

    func delete(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) throws {
        guard let artifact = try load(
            repositoryID: repositoryID,
            repositoryFullName: repositoryFullName,
            scope: scope
        ) else {
            return
        }
        let marker = DeletionMarker(
            repositoryID: repositoryID,
            repositoryFullName: repositoryFullName,
            accountStorageKey: scope.storageKey,
            deletedSourceHash: artifact.document.sourceHash,
            deletedAt: now()
        )
        let markerURL = try deletionMarkerURL(repositoryID: repositoryID, scope: scope)
        try fileManager.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 先写抑制标记再删 Artifact；即使删除失败，也不会出现“刚删完立即后台重建”。
        try Self.encoder().encode(marker).write(to: markerURL, options: .atomic)
        let directory = try artifactDirectory(repositoryID: repositoryID, scope: scope)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func replaceDirectoryAtomically(
        finalDirectory: URL,
        xmlData: Data,
        metadataData: Data
    ) throws {
        let parent = finalDirectory.deletingLastPathComponent()
        let temporaryDirectory = parent.appendingPathComponent(
            ".\(finalDirectory.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupDirectory = parent.appendingPathComponent(
            ".\(finalDirectory.lastPathComponent).backup",
            isDirectory: true
        )
        try? fileManager.removeItem(at: temporaryDirectory)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        try xmlData.write(
            to: temporaryDirectory.appendingPathComponent(
                RepositoryInsightsDocument.fileName,
                isDirectory: false
            ),
            options: .atomic
        )
        try metadataData.write(
            to: temporaryDirectory.appendingPathComponent(
                Self.metadataFileName,
                isDirectory: false
            ),
            options: .atomic
        )

        try recoverInterruptedReplacement(at: finalDirectory)
        try? fileManager.removeItem(at: backupDirectory)
        let hadExisting = fileManager.fileExists(atPath: finalDirectory.path)
        if hadExisting {
            try fileManager.moveItem(at: finalDirectory, to: backupDirectory)
        }
        do {
            try fileManager.moveItem(at: temporaryDirectory, to: finalDirectory)
            try? fileManager.removeItem(at: backupDirectory)
        } catch {
            if hadExisting,
               !fileManager.fileExists(atPath: finalDirectory.path),
               fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: finalDirectory)
            }
            throw error
        }
    }

    /// 上次进程若在目录交换中断，优先恢复已经完整写好的旧目录。
    private func recoverInterruptedReplacement(at finalDirectory: URL) throws {
        let backupDirectory = finalDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(finalDirectory.lastPathComponent).backup", isDirectory: true)
        let finalExists = fileManager.fileExists(atPath: finalDirectory.path)
        let backupExists = fileManager.fileExists(atPath: backupDirectory.path)
        if finalExists, backupExists {
            try fileManager.removeItem(at: backupDirectory)
        } else if !finalExists, backupExists {
            try fileManager.moveItem(at: backupDirectory, to: finalDirectory)
        }
    }

    private func loadDeletionMarker(
        repositoryID: Int64,
        repositoryFullName: String,
        scope: RepositoryInsightsContextScope
    ) throws -> DeletionMarker? {
        let url = try deletionMarkerURL(repositoryID: repositoryID, scope: scope)
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        guard let marker = try? Self.decoder().decode(DeletionMarker.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard marker.repositoryID == repositoryID,
              marker.repositoryFullName == repositoryFullName,
              marker.accountStorageKey == scope.storageKey else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return marker
    }

    private func removeDeletionMarker(
        repositoryID: Int64,
        scope: RepositoryInsightsContextScope
    ) throws {
        let url = try deletionMarkerURL(repositoryID: repositoryID, scope: scope)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func artifactDirectory(
        repositoryID: Int64,
        scope: RepositoryInsightsContextScope
    ) throws -> URL {
        try rootURL()
            .appendingPathComponent(scope.storageKey, isDirectory: true)
            .appendingPathComponent("repo-\(repositoryID)", isDirectory: true)
    }

    private func deletionMarkerURL(
        repositoryID: Int64,
        scope: RepositoryInsightsContextScope
    ) throws -> URL {
        try rootURL()
            .appendingPathComponent(scope.storageKey, isDirectory: true)
            .appendingPathComponent(Self.deletionDirectoryName, isDirectory: true)
            .appendingPathComponent("repo-\(repositoryID).json", isDirectory: false)
    }

    private func rootURL() throws -> URL {
        if let fixedRootURL { return fixedRootURL }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RepositoryInsightsContextStorageError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("repository-insights-context", isDirectory: true)
    }

    private static func validate(
        xmlData: Data,
        repositoryID: Int64,
        repositoryFullName: String,
        sourceHash: String
    ) throws {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: xmlData, options: [])
        } catch {
            throw RepositoryInsightsContextStorageError.invalidXML
        }
        guard let root = document.rootElement(), root.name == "repository_insights" else {
            throw RepositoryInsightsContextStorageError.invalidXML
        }
        guard root.attribute(forName: "schema_version")?.stringValue
            == String(RepositoryInsightsDocument.schemaVersion),
              root.attribute(forName: "repository_id")?.stringValue == String(repositoryID),
              root.attribute(forName: "repository")?.stringValue == repositoryFullName
        else {
            throw RepositoryInsightsContextStorageError.repositoryMismatch
        }
        guard root.attribute(forName: "source_hash")?.stringValue == sourceHash else {
            throw RepositoryInsightsContextStorageError.hashMismatch
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
