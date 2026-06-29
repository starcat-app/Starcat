//
//  CodebaseMemoryStorage.swift
//  Starcat
//
//  CodebaseMemory 本地产物存储：负责输出目录授权、metadata 持久化、项目扫描与删除。
//
//  骨架完全对齐 CodeFlowStorage（同款 bookmark / migrate / summary 模式），
//  差异点：
//    - 默认根: Application Support/Starcat/codebasememory
//    - project 结构: <owner>/<repo>/{source/, metadata.json}
//    - metadata 含 binaryVersion / binarySHA256 / lastUIPort / indexedNodeCount 等
//    - 无 openPage 方法（UI 走浏览器,不走本地 HTML）

import AppKit
import Foundation
import Observation

// MARK: - CodebaseMemorySummary

/// HOM-203：CodebaseMemory 产物根目录的汇总缓存（落盘为 `<root>/.starcat-summary.json`）。
///
/// 与 CodeFlowSummary / RepoContextSummary 同款设计——UI 渲染 4 列汇总用，
/// per-project metadata.json 仍是真源。
struct CodebaseMemorySummary: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let projectCount: Int
    let totalBytes: Int64
    let totalGenerationCount: Int
    let latestGeneratedAt: Date?
    let updatedAt: Date

    static let currentSchemaVersion: Int = 1
    static let filename: String = ".starcat-summary.json"

    static let empty: CodebaseMemorySummary = .init(
        schemaVersion: currentSchemaVersion,
        projectCount: 0,
        totalBytes: 0,
        totalGenerationCount: 0,
        latestGeneratedAt: nil,
        updatedAt: .distantPast
    )

    func withUpdatedAt(_ date: Date) -> CodebaseMemorySummary {
        .init(
            schemaVersion: schemaVersion,
            projectCount: projectCount,
            totalBytes: totalBytes,
            totalGenerationCount: totalGenerationCount,
            latestGeneratedAt: latestGeneratedAt,
            updatedAt: date
        )
    }
}

// MARK: - CodebaseMemoryExecutionStep

struct CodebaseMemoryExecutionStep: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending, running, succeeded, failed, skipped, handedOff
    }

    /// 步骤标识（与 ViewModel 的 7 个步骤对齐）。
    enum ID: String, Codable, CaseIterable, Sendable {
        case resolveBinary, resolveRevision, download, extract, index, startUI, openBrowser

        /// 执行详情中的人类可读名称。
        var displayTitle: String {
            switch self {
            case .resolveBinary: return String.l10n("codebaseMemory.step.resolveBinary.title")
            case .resolveRevision: return String.l10n("codebaseMemory.step.resolveRevision.title")
            case .download: return String.l10n("codebaseMemory.step.download.title")
            case .extract: return String.l10n("codebaseMemory.step.extract.title")
            case .index: return String.l10n("codebaseMemory.step.index.title")
            case .startUI: return String.l10n("codebaseMemory.step.startUI.title")
            case .openBrowser: return String.l10n("codebaseMemory.step.openBrowser.title")
            }
        }
    }

    let id: ID
    var status: Status
    var detail: String?
    var durationMilliseconds: Int?
}

// MARK: - CodebaseMemoryMetadata

struct CodebaseMemoryMetadata: Codable, Equatable, Sendable {

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

    struct SourceRevision: Codable, Equatable, Sendable {
        let branch: String
        let commitSHA: String
        let commitURL: String

        var shortSHA: String { String(commitSHA.prefix(7)) }
    }

    struct Execution: Codable, Equatable, Sendable {
        let startedAt: Date
        let finishedAt: Date
        let durationMs: Int
        let steps: [CodebaseMemoryExecutionStep]
        let indexedNodeCount: Int?
        let indexedEdgeCount: Int?
    }

    struct Generation: Codable, Equatable, Sendable {
        let generatedAt: Date
        let generationCount: Int
    }

    let schemaVersion: Int
    let repository: Repository
    let sourceRevision: SourceRevision
    let lastIndexing: Execution
    let generation: Generation
    let binaryVersion: String
    let binarySHA256: String
    let lastUIPort: Int?

    /// 方便缓存命中判断时比较 commitSHA，无需解构 sourceRevision。
    var commitSHA: String { sourceRevision.commitSHA }
}

// MARK: - CodebaseMemoryStoredProject

/// 单个 `<owner>/<repo>` 产物项。
///
/// 字段与 CodeFlowStoredProject 镜像，便于 UI 复用同款行 / 统计渲染函数。
struct CodebaseMemoryStoredProject: Identifiable, Equatable, Sendable {
    /// `<owner>/<repo>` 子目录绝对路径。
    let directoryURL: URL
    /// `metadata.json` 绝对路径。
    let metadataURL: URL
    /// 解码后的 metadata（复用，不二次读文件）。
    let metadata: CodebaseMemoryMetadata

    var id: String { "\(metadata.repository.owner)/\(metadata.repository.name)" }

    /// 递归目录总大小（字节）。metadata.json + source/ + .codebase-memory/ 等全部计入。
    var totalBytes: Int64 {
        Int64((try? Self.directorySize(of: directoryURL)) ?? 0)
    }

    /// 最近活跃时间（UI 排序用）。
    var lastActiveAt: Date {
        metadata.generation.generatedAt
    }

    /// 生成时间（UI 列表副标题用）。
    var generatedAtDate: Date {
        metadata.generation.generatedAt
    }

    public static func == (lhs: CodebaseMemoryStoredProject, rhs: CodebaseMemoryStoredProject) -> Bool {
        lhs.directoryURL == rhs.directoryURL && lhs.metadata.commitSHA == rhs.metadata.commitSHA
    }

    // MARK: - Helpers

    /// 递归计算目录总字节数（与 SourceZipExtractor.directorySize 同款）。
    private static func directorySize(of url: URL) -> Int {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += size
            }
        }
        return total
    }
}

// MARK: - CodebaseMemoryStorage

/// 文件系统是 CodebaseMemory 产物的单一真源；本类型不建立数据库镜像。
@Observable
final class CodebaseMemoryStorage {

    /// security-scoped bookmark 授权的是用户选择目录,实际产物位于其 `codebasememory`
    /// 子目录。两者必须分开保存,避免 bookmark 解析回父目录时误把父目录当输出根。
    private struct ResolvedOutputRoot {
        let url: URL
        let securityScopeURL: URL?
    }

    static let shared = CodebaseMemoryStorage()

    private static let bookmarkKey = "settings.codebaseMemory.outputDirectoryBookmark.v1"
    private let fileManager: FileManager
    private let defaults: UserDefaults

    // MARK: - 状态

    /// HOM-203：summary 缓存优先；打不开或过期时降级全量 scan。
    private(set) var summary: CodebaseMemorySummary = .empty
    /// 最近一次操作失败的错误消息（UI 展示用）。
    private(set) var lastErrorMessage: String?
    /// 递增版本号驱动 SwiftUI 重建 `.id(directoryConfigurationRevision)`。
    private(set) var directoryConfigurationRevision: Int = 0

    /// 单测旁路：直接指定输出根,不再走 bookmark 路径。
    var fixedRootURL: URL?

    // MARK: - Init

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
    }

    // MARK: - 派生属性

    var outputDirectoryDisplayPath: String {
        _ = directoryConfigurationRevision
        return (try? resolveOutputRoot().url.path) ?? ""
    }

    /// 用户是否已选择自定义输出根（= 存在 bookmark）。
    var hasCustomOutputDirectory: Bool {
        defaults.data(forKey: Self.bookmarkKey) != nil
    }

    /// 项目数（从 summary 读, O(1)）。
    var projectCount: Int { summary.projectCount }

    /// 总占用（从 summary 读）。
    var totalBytes: Int64 { summary.totalBytes }

    /// 累计生成次数。
    var totalGenerationCount: Int { summary.totalGenerationCount }

    /// 最近一次生成。
    var latestGeneratedAt: Date? { summary.latestGeneratedAt }

    // MARK: - 目录切换（对齐 CodeFlowStorage）

    /// 用户通过 NSOpenPanel 选择新输出根目录。
    ///
    /// 先复制全部项目,确认成功后再删除源目录,避免迁移中断导致已生成上下文丢失。
    func setCustomOutputDirectory(_ url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart else { throw CodebaseMemoryStorageError.outputDirectoryUnavailable }
        defer { url.stopAccessingSecurityScopedResource() }

        let outputRoot = Self.customOutputRoot(for: url)
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let source = try resolveOutputRoot()
        try migrateProjects(
            from: source,
            to: ResolvedOutputRoot(url: outputRoot, securityScopeURL: nil)
        )
        defaults.set(data, forKey: Self.bookmarkKey)
        directoryConfigurationRevision += 1
        reload()
    }

    /// 将用户选择的父目录规范化为 CodebaseMemory 独占根目录。
    static func customOutputRoot(for selectedURL: URL) -> URL {
        guard selectedURL.lastPathComponent.lowercased() != "codebasememory" else {
            return selectedURL
        }
        return selectedURL.appendingPathComponent("codebasememory", isDirectory: true)
    }

    /// 恢复默认目录（先迁回项目,再清除 bookmark）。
    func resetOutputDirectory() throws {
        let source = try resolveOutputRoot()
        let destination = ResolvedOutputRoot(url: try defaultOutputRoot(), securityScopeURL: nil)
        try migrateProjects(from: source, to: destination)
        defaults.removeObject(forKey: Self.bookmarkKey)
        directoryConfigurationRevision += 1
        reload()
    }

    // MARK: - UI 刷新入口（HOM-203 改造）

    func reload() {
        do {
            try withOutputRoot { root in
                try loadOrRebuildSummary(root: root)
            }
            lastErrorMessage = nil
        } catch {
            summary = .empty
            lastErrorMessage = error.localizedDescription
        }
    }

    func rebuildSummary() {
        do {
            try withOutputRoot { root in
                try rebuildSummaryOnDisk(root: root)
            }
            lastErrorMessage = nil
        } catch {
            summary = .empty
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - 项目查询

    func existingProject(owner: String, name: String) throws -> CodebaseMemoryStoredProject? {
        try withOutputRoot { root in
            try loadProject(directory: projectDirectory(root: root, owner: owner, name: name))
        }
    }

    // MARK: - 写入

    func write(
        metadata: CodebaseMemoryMetadata,
        owner: String,
        name: String
    ) throws -> CodebaseMemoryStoredProject {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, name: name)
            let existing = try? loadProject(directory: directory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let metadataURL = directory.appendingPathComponent("metadata.json")
            let encoder = Self.metadataEncoder
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

            guard let project = try loadProject(directory: directory) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            updateSummaryAfterWrite(root: root, newProject: project, oldProject: existing)
            return project
        }
    }

    // MARK: - 删除

    func deleteProject(owner: String, name: String) throws {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, name: name)
            let removed = try? loadProject(directory: directory)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
            updateSummaryAfterDelete(root: root, removed: removed)
        }
    }

    /// 删除所有项目产物。
    /// - 项目目录: `<root>/<owner>/<repo>/`
    /// - 项目缓存: `<root>/<owner>/<repo>/.internal-cache/` 随项目目录一起删除
    ///
    /// 项目缓存必须按 repo 隔离；否则浏览器 UI 可能继续读取上一个 repo 的 graph/config。
    /// 内置 `codebase` 可执行副本不属于用户数据,由 `CodebaseMemoryBinaryResolver`
    /// 放在 App 自己的 Application Support 缓存目录,这里不再删除。
    func deleteAllProjects() throws {
        try withOutputRoot { root in
            let knownProjects = try scanProjects(root: root)
            for project in knownProjects {
                try fileManager.removeItem(at: project.directoryURL)
                let ownerDirectory = project.directoryURL.deletingLastPathComponent()
                if (try? fileManager.contentsOfDirectory(atPath: ownerDirectory.path).isEmpty) == true {
                    try? fileManager.removeItem(at: ownerDirectory)
                }
            }
            writeSummary(.empty.withUpdatedAt(.now), root: root)
            summary = .empty.withUpdatedAt(.now)
        }
    }

    // MARK: - 工具

    func outputRootURL() throws -> URL {
        try resolveOutputRoot().url
    }

    func revealOutputRoot() throws {
        try withOutputRoot { root in
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    /// 给定 owner/name 返回其项目目录（不创建,不保证存在）。
    func projectDirectory(root: URL, owner: String, name: String) -> URL {
        root.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// 给定 owner/name 返回该项目专属的 codebase-memory 缓存目录。
    ///
    /// 该目录会存放 binary 的 graph db 与 UI config。必须放在项目目录内，而不是
    /// `<root>/.internal-cache` 这类全局位置，否则打开 Repo B 时浏览器 UI 可能复用 Repo A 的状态。
    func projectCacheDirectory(root: URL, owner: String, name: String) -> URL {
        projectDirectory(root: root, owner: owner, name: name)
            .appendingPathComponent(".internal-cache", isDirectory: true)
    }

    // MARK: - 内部：输出根解析

    private func resolveOutputRoot() throws -> ResolvedOutputRoot {
        if let fixedRootURL {
            return ResolvedOutputRoot(url: fixedRootURL, securityScopeURL: nil)
        }

        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            return ResolvedOutputRoot(url: try defaultOutputRoot(), securityScopeURL: nil)
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
            throw CodebaseMemoryStorageError.invalidBookmark
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodebaseMemoryStorageError.outputDirectoryUnavailable
        }
        if isStale {
            let refreshed = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return ResolvedOutputRoot(
            url: Self.customOutputRoot(for: url),
            securityScopeURL: url
        )
    }

    private func defaultOutputRoot() throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Starcat/codebasememory", isDirectory: true)
    }

    // MARK: - 内部：security scope

    private func withOutputRoot<T>(_ operation: (URL) throws -> T) throws -> T {
        let resolved = try resolveOutputRoot()
        return try withResolvedRoot(resolved, operation)
    }

    private func withResolvedRoot<T>(
        _ resolved: ResolvedOutputRoot,
        _ operation: (URL) throws -> T
    ) throws -> T {
        let didStart = resolved.securityScopeURL?.startAccessingSecurityScopedResource() ?? false
        if resolved.securityScopeURL != nil && !didStart {
            throw CodebaseMemoryStorageError.outputDirectoryUnavailable
        }
        defer {
            if didStart { resolved.securityScopeURL?.stopAccessingSecurityScopedResource() }
        }
        return try operation(resolved.url)
    }

    // MARK: - 内部：迁移

    func migrateProjects(
        from source: (url: URL, requiresSecurityScope: Bool),
        to destination: (url: URL, requiresSecurityScope: Bool)
    ) throws {
        try migrateProjects(
            from: ResolvedOutputRoot(
                url: source.url,
                securityScopeURL: source.requiresSecurityScope ? source.url : nil
            ),
            to: ResolvedOutputRoot(
                url: destination.url,
                securityScopeURL: destination.requiresSecurityScope ? destination.url : nil
            )
        )
    }

    private func migrateProjects(
        from source: ResolvedOutputRoot,
        to destination: ResolvedOutputRoot
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
                            .appendingPathComponent(
                                ".\(project.metadata.repository.name).migration-\(UUID().uuidString)"
                            )
                        try fileManager.createDirectory(
                            at: temporary.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.copyItem(at: project.directoryURL, to: temporary)
                        if fileManager.fileExists(atPath: target.path) {
                            try fileManager.removeItem(at: target)
                        }
                        try fileManager.moveItem(at: temporary, to: target)
                        copiedDirectories.append(target)
                    }
                } catch {
                    for directory in copiedDirectories { try? fileManager.removeItem(at: directory) }
                    throw error
                }

                for project in sourceProjects {
                    try? fileManager.removeItem(at: project.directoryURL)
                    let ownerDirectory = project.directoryURL.deletingLastPathComponent()
                    if (try? fileManager.contentsOfDirectory(atPath: ownerDirectory.path).isEmpty) == true {
                        try? fileManager.removeItem(at: ownerDirectory)
                    }
                }
                let sourceSummary = sourceRoot.appendingPathComponent(
                    CodebaseMemorySummary.filename, isDirectory: false
                )
                try? fileManager.removeItem(at: sourceSummary)

                // 同步迁移 .bin(codebase 容器副本)。
                // 项目级 .internal-cache 已经在各项目目录内, 会随项目目录一起复制。
                // 复制即可, BinaryResolver 会校验大小并自动重新 chmod
                let auxiliaryDirs = [".bin"]
                for dirName in auxiliaryDirs {
                    let sourceAux = sourceRoot.appendingPathComponent(dirName, isDirectory: true)
                    let destAux = destinationRoot.appendingPathComponent(dirName, isDirectory: true)
                    guard fileManager.fileExists(atPath: sourceAux.path) else { continue }
                    try fileManager.createDirectory(
                        at: destAux.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fileManager.fileExists(atPath: destAux.path) {
                        try fileManager.removeItem(at: destAux)
                    }
                    try fileManager.copyItem(at: sourceAux, to: destAux)
                }
            }
        }
    }

    // MARK: - 内部：Summary 缓存

    private func loadOrRebuildSummary(root: URL) throws {
        guard fileManager.fileExists(atPath: root.path) else {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let empty = CodebaseMemorySummary.empty.withUpdatedAt(.now)
            writeSummary(empty, root: root)
            summary = empty
            return
        }
        if let cached = readSummary(root: root) {
            if cached.schemaVersion != CodebaseMemorySummary.currentSchemaVersion {
                try rebuildSummaryOnDisk(root: root)
                return
            }
            let approximate = try approximateProjectCount(root: root)
            let drift = abs(approximate - cached.projectCount)
            let tolerance = max(10, cached.projectCount / 10)
            if drift <= tolerance {
                summary = cached
                return
            }
        }
        try rebuildSummaryOnDisk(root: root)
    }

    private func rebuildSummaryOnDisk(root: URL) throws {
        let scanned = try scanProjects(root: root)
        let computed = CodebaseMemorySummary(
            schemaVersion: CodebaseMemorySummary.currentSchemaVersion,
            projectCount: scanned.count,
            totalBytes: scanned.reduce(0) { $0 + $1.totalBytes },
            totalGenerationCount: scanned.reduce(0) { $0 + $1.metadata.generation.generationCount },
            latestGeneratedAt: scanned.map(\.metadata.generation.generatedAt).max(),
            updatedAt: .now
        )
        writeSummary(computed, root: root)
        summary = computed
    }

    private func updateSummaryAfterWrite(
        root: URL,
        newProject: CodebaseMemoryStoredProject,
        oldProject: CodebaseMemoryStoredProject?
    ) {
        guard let base = summary ?? readSummary(root: root) else {
            try? rebuildSummaryOnDisk(root: root)
            return
        }
        let projectCount = base.projectCount + (oldProject == nil ? 1 : 0)
        let totalBytes = base.totalBytes + (newProject.totalBytes - (oldProject?.totalBytes ?? 0))
        let countDelta = newProject.metadata.generation.generationCount
            - (oldProject?.metadata.generation.generationCount ?? 0)
        let totalGenerationCount = max(0, base.totalGenerationCount + countDelta)
        let latestGeneratedAt: Date? = {
            let candidate = newProject.metadata.generation.generatedAt
            if let existing = base.latestGeneratedAt {
                return max(existing, candidate)
            }
            return candidate
        }()
        let updated = CodebaseMemorySummary(
            schemaVersion: CodebaseMemorySummary.currentSchemaVersion,
            projectCount: projectCount,
            totalBytes: totalBytes,
            totalGenerationCount: totalGenerationCount,
            latestGeneratedAt: latestGeneratedAt,
            updatedAt: .now
        )
        writeSummary(updated, root: root)
        summary = updated
    }

    private func updateSummaryAfterDelete(
        root: URL,
        removed: CodebaseMemoryStoredProject?
    ) {
        guard let removed else {
            summary = (summary ?? .empty).withUpdatedAt(.now)
            return
        }
        guard let base = summary ?? readSummary(root: root) else {
            try? rebuildSummaryOnDisk(root: root)
            return
        }
        let nextCount = max(0, base.projectCount - 1)
        let nextBytes = max(0, base.totalBytes - removed.totalBytes)
        let nextGen = max(0, base.totalGenerationCount - removed.metadata.generation.generationCount)
        let nextLatest: Date? = nextCount == 0 ? nil : base.latestGeneratedAt
        let updated = CodebaseMemorySummary(
            schemaVersion: CodebaseMemorySummary.currentSchemaVersion,
            projectCount: nextCount,
            totalBytes: nextBytes,
            totalGenerationCount: nextGen,
            latestGeneratedAt: nextLatest,
            updatedAt: .now
        )
        writeSummary(updated, root: root)
        summary = updated
    }

    private func readSummary(root: URL) -> CodebaseMemorySummary? {
        let url = root.appendingPathComponent(CodebaseMemorySummary.filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodebaseMemorySummary.self, from: data)
    }

    private func writeSummary(_ value: CodebaseMemorySummary, root: URL) {
        let url = root.appendingPathComponent(CodebaseMemorySummary.filename, isDirectory: false)
        do {
            let data = try Self.metadataEncoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("[CodebaseMemoryStorage] summary write failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private func approximateProjectCount(root: URL) throws -> Int {
        let owners = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        var count = 0
        for owner in owners where (try? owner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let repos = try fileManager.contentsOfDirectory(
                at: owner, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            count += repos.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.count
        }
        return count
    }

    private func scanProjects(root: URL) throws -> [CodebaseMemoryStoredProject] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var result: [CodebaseMemoryStoredProject] = []
        let owners = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        for owner in owners where (try? owner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let repositories = try fileManager.contentsOfDirectory(
                at: owner, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
            for repository in repositories where (try? repository.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
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

    private func loadProject(directory: URL) throws -> CodebaseMemoryStoredProject? {
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(CodebaseMemoryMetadata.self, from: data)
        return CodebaseMemoryStoredProject(
            directoryURL: directory,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }

    // MARK: - 内部：JSON encoder

    private static let metadataEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

// MARK: - CodebaseMemoryStorageError

enum CodebaseMemoryStorageError: LocalizedError {
    case outputDirectoryUnavailable
    case invalidBookmark

    var errorDescription: String? {
        switch self {
        case .outputDirectoryUnavailable:
            return String.l10n("codebaseMemory.storage.error.outputDirectoryUnavailable")
        case .invalidBookmark:
            return String.l10n("codebaseMemory.storage.error.invalidBookmark")
        }
    }
}
