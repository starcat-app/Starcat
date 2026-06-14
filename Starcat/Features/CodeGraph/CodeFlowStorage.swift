//
//  CodeFlowStorage.swift
//  Starcat
//
//  CodeFlow 本地产物存储：负责输出目录授权、metadata 持久化、项目扫描与删除。
//  共享 GitHub ZIP 不属于 CodeFlow 产物，始终留在 App Container，由 Runner 管理。
//

import AppKit
import Foundation
import Observation

struct CodeFlowBranch: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let commitSHA: String

    var id: String { name }
    var shortSHA: String { String(commitSHA.prefix(7)) }
}

struct CodeFlowExecutionStep: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case succeeded
        case handedOff
    }

    let id: String
    let status: Status
    let durationMilliseconds: Int?
    let summary: String
}

struct CodeFlowMetadata: Codable, Equatable, Sendable {
    struct Repository: Codable, Equatable, Sendable {
        let githubID: Int64
        let owner: String
        let name: String
        let fullName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case githubID = "githubId"
            case owner, name, fullName
            case htmlURL = "htmlUrl"
        }
    }

    struct Artifact: Codable, Equatable, Sendable {
        let page: String
        let pageBytes: Int64
        let sourceArchiveBytes: Int64
        let sourceArchiveKey: String
    }

    struct Generation: Codable, Equatable, Sendable {
        let generatedAt: Date
        let generationCount: Int
        let lastDurationMilliseconds: Int
    }

    struct SourceRevision: Codable, Equatable, Sendable {
        let branch: String
        let commitSHA: String
        let commitURL: String

        var shortSHA: String { String(commitSHA.prefix(7)) }
    }

    struct Execution: Codable, Equatable, Sendable {
        let startedAt: Date
        let finishedAt: Date
        let steps: [CodeFlowExecutionStep]
    }

    struct Generator: Codable, Equatable, Sendable {
        let codeFlowCommit: String
        let integrationVersion: Int
    }

    let schemaVersion: Int
    let repository: Repository
    let artifact: Artifact
    let generation: Generation
    let sourceRevision: SourceRevision
    let lastExecution: Execution
    let generator: Generator
}

struct CodeFlowStoredProject: Identifiable, Equatable, Sendable {
    let directoryURL: URL
    let pageURL: URL
    let metadata: CodeFlowMetadata

    var id: String { metadata.repository.fullName }
    var totalBytes: Int64 { metadata.artifact.pageBytes + metadataFileBytes }

    private var metadataFileBytes: Int64 {
        let url = directoryURL.appendingPathComponent("metadata.json")
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

enum CodeFlowStorageError: LocalizedError {
    case outputDirectoryUnavailable
    case invalidBookmark

    var errorDescription: String? {
        switch self {
        case .outputDirectoryUnavailable:
            return "CodeFlow 输出目录不可用，请在设置中重新选择。"
        case .invalidBookmark:
            return "无法恢复 CodeFlow 输出目录授权，请重新选择目录。"
        }
    }
}

/// 文件系统是 CodeFlow 生成物的单一真源；本类型不建立数据库镜像。
@Observable
final class CodeFlowStorage {
    static let shared = CodeFlowStorage()

    private static let bookmarkKey = "settings.codeflow.outputDirectoryBookmark.v1"
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let fixedRootURL: URL?

    private(set) var projects: [CodeFlowStoredProject] = []
    private(set) var lastErrorMessage: String?

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        fixedRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.fixedRootURL = fixedRootURL
    }

    var hasCustomOutputDirectory: Bool {
        fixedRootURL == nil && defaults.data(forKey: Self.bookmarkKey) != nil
    }

    var outputDirectoryDisplayPath: String {
        (try? resolveOutputRoot().url.path) ?? "输出目录授权已失效"
    }

    var totalBytes: Int64 { projects.reduce(0) { $0 + $1.totalBytes } }

    var totalGenerationCount: Int {
        projects.reduce(0) { $0 + $1.metadata.generation.generationCount }
    }

    var latestGeneratedAt: Date? {
        projects.map(\.metadata.generation.generatedAt).max()
    }

    /// 保存用户通过 NSOpenPanel 主动选择的目录，并把当前 CodeFlow 项目迁移过去。
    ///
    /// 用户通常会给多个集成选择同一个父目录，因此这里强制把 CodeFlow 产物隔离到
    /// `codeflow` 子目录；如果用户已经选中该目录则不重复追加。
    ///
    /// 先复制全部项目，确认成功后再删除源目录，避免迁移中断导致现有图谱丢失。
    func setCustomOutputDirectory(_ url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart else { throw CodeFlowStorageError.outputDirectoryUnavailable }
        defer { url.stopAccessingSecurityScopedResource() }

        let outputRoot = Self.customOutputRoot(for: url)
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let data = try outputRoot.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let source = try resolveOutputRoot()
        // 当前仍持有用户所选父目录的 security scope，迁移时无需对子目录重复申请。
        try migrateProjects(from: source, to: (outputRoot, false))
        defaults.set(data, forKey: Self.bookmarkKey)
        reload()
    }

    /// 将用户选择的父目录规范化为 CodeFlow 独占根目录。
    static func customOutputRoot(for selectedURL: URL) -> URL {
        guard selectedURL.lastPathComponent.lowercased() != "codeflow" else {
            return selectedURL
        }
        return selectedURL.appendingPathComponent("codeflow", isDirectory: true)
    }

    /// 恢复默认目录也属于目录切换，必须先把当前自定义目录中的项目迁回容器。
    func resetOutputDirectory() throws {
        let source = try resolveOutputRoot()
        let destination = (try defaultOutputRoot(), false)
        try migrateProjects(from: source, to: destination)
        defaults.removeObject(forKey: Self.bookmarkKey)
        reload()
    }

    func reload() {
        do {
            projects = try withOutputRoot { root in
                try scanProjects(root: root)
            }
            lastErrorMessage = nil
        } catch {
            projects = []
            lastErrorMessage = error.localizedDescription
        }
    }

    func existingProject(owner: String, name: String) throws -> CodeFlowStoredProject? {
        try withOutputRoot { root in
            try loadProject(directory: projectDirectory(root: root, owner: owner, name: name))
        }
    }

    func write(pageHTML: String, metadata: CodeFlowMetadata, owner: String, name: String) throws -> CodeFlowStoredProject {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, name: name)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let pageURL = directory.appendingPathComponent("index.html")
            let metadataURL = directory.appendingPathComponent("metadata.json")
            try pageHTML.write(to: pageURL, atomically: true, encoding: .utf8)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

            guard let project = try loadProject(directory: directory) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return project
        }
    }

    func updateMetadata(_ metadata: CodeFlowMetadata, owner: String, name: String) throws -> CodeFlowStoredProject {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, name: name)
            let metadataURL = directory.appendingPathComponent("metadata.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
            guard let project = try loadProject(directory: directory) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return project
        }
    }

    func deleteProject(owner: String, name: String) throws {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, name: name)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        reload()
    }

    /// 只删除项目子目录，保留用户主动选择的输出根目录本身。
    func deleteAllProjects() throws {
        try withOutputRoot { root in
            // 用户可能直接选择 Documents 等已有目录，绝不能删除未知子目录。
            // 只删除能解析出有效 index.html + metadata.json 的 CodeFlow 项目。
            let knownProjects = try scanProjects(root: root)
            for project in knownProjects {
                try fileManager.removeItem(at: project.directoryURL)
                let ownerDirectory = project.directoryURL.deletingLastPathComponent()
                if (try? fileManager.contentsOfDirectory(atPath: ownerDirectory.path).isEmpty) == true {
                    try? fileManager.removeItem(at: ownerDirectory)
                }
            }
        }
        reload()
    }

    func outputRootURL() throws -> URL {
        try resolveOutputRoot().url
    }

    /// 打开页面和 Finder 都必须在 security scope 有效期间发给 Launch Services。
    func openPage(_ pageURL: URL) throws -> Bool {
        try withOutputRoot { _ in NSWorkspace.shared.open(pageURL) }
    }

    func revealPage(_ pageURL: URL) throws {
        try withOutputRoot { _ in NSWorkspace.shared.activateFileViewerSelecting([pageURL]) }
    }

    func revealOutputRoot() throws {
        try withOutputRoot { root in
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    private func withOutputRoot<T>(_ operation: (URL) throws -> T) throws -> T {
        let resolved = try resolveOutputRoot()
        return try withResolvedRoot(resolved, operation)
    }

    private func withResolvedRoot<T>(
        _ resolved: (url: URL, requiresSecurityScope: Bool),
        _ operation: (URL) throws -> T
    ) throws -> T {
        let didStart = resolved.requiresSecurityScope
            ? resolved.url.startAccessingSecurityScopedResource()
            : false
        if resolved.requiresSecurityScope && !didStart {
            throw CodeFlowStorageError.outputDirectoryUnavailable
        }
        defer {
            if didStart { resolved.url.stopAccessingSecurityScopedResource() }
        }
        return try operation(resolved.url)
    }

    /// 只迁移能够识别的 CodeFlow 项目；目标冲突时以当前目录版本覆盖。
    func migrateProjects(
        from source: (url: URL, requiresSecurityScope: Bool),
        to destination: (url: URL, requiresSecurityScope: Bool)
    ) throws {
        guard source.url.standardizedFileURL != destination.url.standardizedFileURL else { return }

        try withResolvedRoot(source) { sourceRoot in
            try withResolvedRoot(destination) { destinationRoot in
                try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                let sourceProjects = try scanProjects(root: sourceRoot)
                var copiedDirectories: [URL] = []

                do {
                    for project in sourceProjects {
                        let target = projectDirectory(
                            root: destinationRoot,
                            owner: project.metadata.repository.owner,
                            name: project.metadata.repository.name
                        )
                        let temporary = target
                            .deletingLastPathComponent()
                            .appendingPathComponent(".\(project.metadata.repository.name).migration-\(UUID().uuidString)")
                        try fileManager.createDirectory(at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileManager.copyItem(at: project.directoryURL, to: temporary)
                        if fileManager.fileExists(atPath: target.path) {
                            try fileManager.removeItem(at: target)
                        }
                        try fileManager.moveItem(at: temporary, to: target)
                        copiedDirectories.append(target)
                    }
                } catch {
                    // 源目录尚未删除；清理本轮已经复制的目标，保持切换前状态。
                    for directory in copiedDirectories { try? fileManager.removeItem(at: directory) }
                    throw error
                }

                // 目标已完整复制后，源清理由 best-effort 完成。即使某个旧文件被外部进程
                // 占用，也不能让 bookmark 停留在旧目录，否则已复制的新目录反而失去授权。
                for project in sourceProjects {
                    try? fileManager.removeItem(at: project.directoryURL)
                    let ownerDirectory = project.directoryURL.deletingLastPathComponent()
                    if (try? fileManager.contentsOfDirectory(atPath: ownerDirectory.path).isEmpty) == true {
                        try? fileManager.removeItem(at: ownerDirectory)
                    }
                }
            }
        }
    }

    private func resolveOutputRoot() throws -> (url: URL, requiresSecurityScope: Bool) {
        if let fixedRootURL { return (fixedRootURL, false) }

        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            return (try defaultOutputRoot(), false)
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw CodeFlowStorageError.invalidBookmark
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodeFlowStorageError.outputDirectoryUnavailable
        }
        if isStale {
            let refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return (url, true)
    }

    private func defaultOutputRoot() throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Starcat/codeflow", isDirectory: true)
    }

    private func projectDirectory(root: URL, owner: String, name: String) -> URL {
        root.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func scanProjects(root: URL) throws -> [CodeFlowStoredProject] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var result: [CodeFlowStoredProject] = []
        let owners = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for owner in owners where (try? owner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let repositories = try fileManager.contentsOfDirectory(at: owner, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for repository in repositories where (try? repository.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // 单个 metadata 损坏不应让整个数据管理页失效；该目录不会进入删除范围。
                do {
                    if let project = try loadProject(directory: repository) {
                        result.append(project)
                    }
                } catch {
                    continue
                }
            }
        }
        return result.sorted { $0.metadata.generation.generatedAt > $1.metadata.generation.generatedAt }
    }

    private func loadProject(directory: URL) throws -> CodeFlowStoredProject? {
        let pageURL = directory.appendingPathComponent("index.html")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let pageSize = (try? pageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileManager.fileExists(atPath: pageURL.path),
              fileManager.fileExists(atPath: metadataURL.path),
              pageSize > 0 else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(CodeFlowMetadata.self, from: Data(contentsOf: metadataURL))
        return CodeFlowStoredProject(directoryURL: directory, pageURL: pageURL, metadata: metadata)
    }
}
