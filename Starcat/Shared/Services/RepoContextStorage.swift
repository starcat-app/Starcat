//
//  RepoContextStorage.swift
//  Starcat
//
//  RepoContextPacker 产物本地存储（W6，2026-06-13）。负责：
//    - 用户自定义输出目录（Security-scoped bookmark）+ 重置 + 迁移；
//    - 扫描 `<root>/<owner>/<repo>/{context.xml, metadata.json}` 得到 projects；
//    - 单删 / 一键清空 / 在 Finder 显示；
//    - 写盘入口 `write(xml:metadata:owner:repo:)`（W8 ContextWriter 走这里）；
//    - `existingProject(owner:repo:)`（W3 RepoAIContextProvider 缓存命中走这里）。
//
//  设计要点（与 `CodeFlowStorage.swift` 接口对齐）：
//    - **文件系统是唯一信任源**：不维护内存索引，UI 状态 (`projects`) 完全派生自
//      `scanProjects(root:)`；所有写操作末尾都触发 `reload()`。
//    - **@Observable + 单例**：和 CodeFlow 同款，让 SwiftUI 视图 (`StorageSettingsTab`)
//      直接观察 `storage.projects` 变化；单例避免在多处持有不同的 bookmark 状态。
//    - **写盘要先读旧 metadata**：W7 引入的 `generationCount` 字段语义是"累计次数"，
//      所以 `write` 内部要先 `loadProject(directory:)` 拿旧 `generationCount`，新值 +1。
//
//  关键约束（已踩过的坑级）：
//    1. PackMetadata.generatedAt 是 ISO-8601 String，不是 Date。`latestGeneratedAt`
//       计算时要解析；解析失败的 metadata 不参与排序（用 .distantPast 兜底，会排到末尾）。
//    2. Security-scoped bookmark 仅在 `startAccessingSecurityScopedResource` 期间有效；
//       任何 `FileManager` / `Data.write` / `JSONEncoder.encode().write` 都要在
//       `withOutputRoot { _ in ... }` 闭包内执行。
//    3. `deleteAllProjects` 不能直接 `removeItem(at: root)`——用户可能选择 `~/Documents`
//       作为根，整目录删会误删；必须先 `scanProjects` 得到识别的 owner/repo 子目录列表，
//       再逐个删（与 CodeFlow 同款防御）。
//

import AppKit
import Foundation
import Observation

/// 单个 `<owner>/<repo>` 产物项。
///
/// 字段与 `CodeFlowStoredProject` 镜像，便于 UI 复用同款行 / 统计渲染函数。
struct RepoContextStoredProject: Identifiable, Equatable, Sendable {

    let directoryURL: URL
    let contextURL: URL
    let metadataURL: URL
    let metadata: PackMetadata

    var id: String { "\(metadata.owner)/\(metadata.repo)" }

    /// `context.xml` 字节数（写盘时已经回填 `metadata.stats.contextXmlBytes`，
    /// 但为了与 CodeFlow `totalBytes` 接口形态对齐，包含 metadata.json 自身体积）。
    var totalBytes: Int64 {
        Int64(metadata.stats.contextXmlBytes) + metadataFileBytes
    }

    /// 最近一次访问时间（W7 lastAccessedAt 字段；nil 时回退 `generatedAt`，再不行 distantPast）。
    var lastActiveAt: Date {
        if let lastAccessedAtString = metadata.lastAccessedAt,
           let parsed = ISO8601DateFormatter.starcatPackerFormatter.date(from: lastAccessedAtString) {
            return parsed
        }
        return ISO8601DateFormatter.starcatPackerFormatter.date(from: metadata.generatedAt)
            ?? .distantPast
    }

    /// 用户可见的"生成时间"（UI 列表行的副标题用）。
    var generatedAtDate: Date {
        ISO8601DateFormatter.starcatPackerFormatter.date(from: metadata.generatedAt) ?? .distantPast
    }

    private var metadataFileBytes: Int64 {
        let values = try? metadataURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    public static func == (lhs: RepoContextStoredProject, rhs: RepoContextStoredProject) -> Bool {
        lhs.directoryURL == rhs.directoryURL && lhs.metadata.commitSha == rhs.metadata.commitSha
    }
}

/// ISO-8601 解析器（与 `RepoContextPacker.iso8601(_:)` 编码格式对齐：`Z` 后缀 UTC）。
extension ISO8601DateFormatter {
    static let starcatPackerFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum RepoContextStorageError: LocalizedError {
    case outputDirectoryUnavailable
    case invalidBookmark

    var errorDescription: String? {
        switch self {
        case .outputDirectoryUnavailable:
            return "AI 代码上下文输出目录不可用，请在设置中重新选择。"
        case .invalidBookmark:
            return "无法恢复输出目录授权，请重新选择目录。"
        }
    }
}

/// 文件系统是 RepoContextPacker 产物的单一真源；本类型不建立数据库镜像。
@Observable
final class RepoContextStorage {

    /// security-scoped bookmark 授权的是用户选择目录，实际产物可能位于其 `repocontext`
    /// 子目录。两者必须分开保存，否则 bookmark 解析回父目录时会误把父目录当输出根。
    private struct ResolvedOutputRoot {
        let url: URL
        let securityScopeURL: URL?
    }

    static let shared = RepoContextStorage()

    private static let bookmarkKey = "settings.repoContext.outputDirectoryBookmark.v1"
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let fixedRootURL: URL?

    private(set) var projects: [RepoContextStoredProject] = []
    private(set) var lastErrorMessage: String?
    /// UserDefaults 不受 Observation 自动追踪；切换配置后递增以刷新路径与按钮状态。
    private var directoryConfigurationRevision: Int = 0

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        fixedRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.fixedRootURL = fixedRootURL
    }

    // MARK: - UI 状态属性（@Observable 派生）

    var hasCustomOutputDirectory: Bool {
        _ = directoryConfigurationRevision
        return fixedRootURL == nil && defaults.data(forKey: Self.bookmarkKey) != nil
    }

    var outputDirectoryDisplayPath: String {
        _ = directoryConfigurationRevision
        return (try? resolveOutputRoot().url.path) ?? "输出目录授权已失效"
    }

    var totalBytes: Int64 { projects.reduce(0) { $0 + $1.totalBytes } }

    /// 累计生成次数（W7 generationCount；nil 时按 1 算，避免新装 metadata 显示 0）。
    var totalGenerationCount: Int {
        projects.reduce(0) { $0 + ($1.metadata.generationCount ?? 1) }
    }

    var latestGeneratedAt: Date? {
        projects.map(\.generatedAtDate).max()
    }

    // MARK: - 用户路径配置入口

    /// 保存用户通过 NSOpenPanel 主动选择的目录，并把当前项目迁移过去。
    ///
    /// 用户通常会给多个集成选择同一个父目录，因此这里强制把上下文产物隔离到
    /// `repocontext` 子目录；如果用户已经选中该目录则不重复追加。
    ///
    /// 先复制全部项目，确认成功后再删除源目录，避免迁移中断导致已生成上下文丢失。
    func setCustomOutputDirectory(_ url: URL) throws {
        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart else { throw RepoContextStorageError.outputDirectoryUnavailable }
        defer { url.stopAccessingSecurityScopedResource() }

        let outputRoot = Self.customOutputRoot(for: url)
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        // bookmark 保存用户实际授权的目录；恢复后再计算 repocontext 子目录。
        // macOS 可能把子目录 bookmark 规范化回授权父目录，不能依赖它保留 child path。
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let source = try resolveOutputRoot()
        // 当前仍持有用户所选父目录的 security scope，迁移时无需对子目录重复申请。
        try migrateProjects(
            from: source,
            to: ResolvedOutputRoot(url: outputRoot, securityScopeURL: nil)
        )
        defaults.set(data, forKey: Self.bookmarkKey)
        directoryConfigurationRevision += 1
        reload()
    }

    /// 将用户选择的父目录规范化为 RepoContextPacker 独占根目录。
    static func customOutputRoot(for selectedURL: URL) -> URL {
        guard selectedURL.lastPathComponent.lowercased() != "repocontext" else {
            return selectedURL
        }
        return selectedURL.appendingPathComponent("repocontext", isDirectory: true)
    }

    /// 恢复默认目录也属于目录切换，必须先把当前自定义目录中的项目迁回容器。
    func resetOutputDirectory() throws {
        let source = try resolveOutputRoot()
        let destination = ResolvedOutputRoot(url: try defaultOutputRoot(), securityScopeURL: nil)
        try migrateProjects(from: source, to: destination)
        defaults.removeObject(forKey: Self.bookmarkKey)
        directoryConfigurationRevision += 1
        reload()
    }

    // MARK: - UI 刷新入口（重新扫描产物目录）

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

    // MARK: - W3 缓存命中入口

    /// 给 `RepoAIContextProvider` 用的命中查询。
    ///
    /// 返回非 nil 不代表"可以用旧 metadata"——caller 还要比较 `commitSha + tokenBudget +
    /// tier1MaxLines + tierRulesVersion`，全等才命中。
    func existingProject(owner: String, repo: String) throws -> RepoContextStoredProject? {
        try withOutputRoot { root in
            try loadProject(directory: projectDirectory(root: root, owner: owner, repo: repo))
        }
    }

    /// 在 security scope 内读取指定项目的 `context.xml` 全文。
    ///
    /// **为什么单列这个 helper（2026-06-14 silent failure 修复）**：
    ///
    /// `existingProject(...)` / packer 输出会返回携带 `contextURL: URL` 的结构体。
    /// 但 `withOutputRoot { ... }` 在 closure 返回的瞬间就 `stopAccessingSecurityScopedResource()`，
    /// 调用方拿到 URL 后在 closure 外面 `String(contentsOf:)` —— 用户若把输出根目录改成
    /// 自选文件夹（Documents / iCloud Drive 等需要 security scope 的位置），那次读取必然
    /// 失败，被外层 `try?` 吞掉变成 nil → AI 摘要静默丢失代码上下文 metadata，UI footer
    /// 第二行 / ⋯ 菜单的「在 Finder 中显示上下文」一并消失，用户无任何提示（dong4j 2026-06-14
    /// 反馈 `addyosmani/agent-skills` 案例）。
    ///
    /// 把"读 xml"也封装进 storage、让整个 IO 都在 `withOutputRoot` 内完成，从源头杜绝
    /// 上层漏 scope 的可能；上层只消费返回的 `String?`，不再直接接触 URL。
    ///
    /// - Returns: 找不到 / 文件不存在 / 文件空 → 返回 nil；caller 应视为降级路径。
    ///            真正读取失败（权限 / IO 错误）会 throw，让 caller 能区分"没有"与"读不到"。
    func loadContextXml(owner: String, repo: String) throws -> String? {
        try withOutputRoot { root in
            let url = projectDirectory(root: root, owner: owner, repo: repo)
                .appendingPathComponent("context.xml")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let xml = try String(contentsOf: url, encoding: .utf8)
            return xml.isEmpty ? nil : xml
        }
    }

    // MARK: - W8 ContextWriter 写盘入口

    /// 把 packer 产生的 xml + metadata 写到 `<root>/<owner>/<repo>/`。
    ///
    /// W8 决议：写盘前先 `loadProject(directory:)` 读旧 generationCount，新 metadata
    /// 的 `generationCount = old + 1`；首次写盘为 1。同时刷新 `lastAccessedAt = now`。
    ///
    /// **注意**：传入的 `metadata` 参数里的 `generationCount` / `lastAccessedAt` 会被本方法
    /// 覆盖（caller 不需要预先计算）；其它字段照搬。
    func write(
        xml: String,
        metadata: PackMetadata,
        owner: String,
        repo: String
    ) throws -> RepoContextStoredProject {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let contextURL = directory.appendingPathComponent("context.xml")
            let metadataURL = directory.appendingPathComponent("metadata.json")

            // 写 xml 拿真实字节数（用来回填 metadata.stats.contextXmlBytes）。
            try xml.write(to: contextURL, atomically: true, encoding: .utf8)
            let xmlBytes = (try? contextURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            // 读旧 metadata 拿 generationCount + 1；不存在则首次 = 1。
            let existing = try? loadProject(directory: directory)
            let nextGenerationCount = (existing?.metadata.generationCount ?? 0) + 1

            // 用 metadata 主字段 + 回填 stats.contextXmlBytes / generationCount /
            // lastAccessedAt 三个 writer 阶段才能确定的字段重建一个完整 metadata。
            let updatedStats = PackStats(
                totalFiles: metadata.stats.totalFiles,
                tier0Count: metadata.stats.tier0Count,
                tier1Count: metadata.stats.tier1Count,
                tier2Count: metadata.stats.tier2Count,
                estimatedTokens: metadata.stats.estimatedTokens,
                actualTokens: metadata.stats.actualTokens,
                contextXmlBytes: xmlBytes
            )
            let nowISO = ISO8601DateFormatter.starcatPackerFormatter.string(from: .now)
            let finalMetadata = PackMetadata(
                schemaVersion: metadata.schemaVersion,
                tierRulesVersion: metadata.tierRulesVersion,
                tokenEstimatorVersion: metadata.tokenEstimatorVersion,
                owner: metadata.owner,
                repo: metadata.repo,
                ref: metadata.ref,
                commitSha: metadata.commitSha,
                generatedAt: metadata.generatedAt,
                tokenBudget: metadata.tokenBudget,
                stats: updatedStats,
                skippedFiles: metadata.skippedFiles,
                warnings: metadata.warnings,
                tier1MaxLines: metadata.tier1MaxLines,
                lastAccessedAt: nowISO,
                generationCount: nextGenerationCount
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(finalMetadata).write(to: metadataURL, options: .atomic)

            guard let project = try loadProject(directory: directory) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // 这里**不**调 reload()——W8 ContextWriter 外层会在写盘完成后统一调一次，
            // 避免重复扫描整棵目录（写完单个 repo 后再扫所有 owners 浪费）。
            return project
        }
    }

    /// W3 缓存命中后刷新 lastAccessedAt（让 UI 列表能按"最近使用"排序）。
    func touch(owner: String, repo: String) throws {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            guard let existing = try loadProject(directory: directory) else { return }
            let nowISO = ISO8601DateFormatter.starcatPackerFormatter.string(from: .now)
            let updated = PackMetadata(
                schemaVersion: existing.metadata.schemaVersion,
                tierRulesVersion: existing.metadata.tierRulesVersion,
                tokenEstimatorVersion: existing.metadata.tokenEstimatorVersion,
                owner: existing.metadata.owner,
                repo: existing.metadata.repo,
                ref: existing.metadata.ref,
                commitSha: existing.metadata.commitSha,
                generatedAt: existing.metadata.generatedAt,
                tokenBudget: existing.metadata.tokenBudget,
                stats: existing.metadata.stats,
                skippedFiles: existing.metadata.skippedFiles,
                warnings: existing.metadata.warnings,
                tier1MaxLines: existing.metadata.tier1MaxLines,
                lastAccessedAt: nowISO,
                generationCount: existing.metadata.generationCount
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(updated).write(to: existing.metadataURL, options: .atomic)
        }
    }

    // MARK: - 删除入口

    func deleteProject(owner: String, repo: String) throws {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
                // owner 目录如果空了一起清掉（与 CodeFlow 同款）。
                let ownerDirectory = directory.deletingLastPathComponent()
                if (try? fileManager.contentsOfDirectory(atPath: ownerDirectory.path).isEmpty) == true {
                    try? fileManager.removeItem(at: ownerDirectory)
                }
            }
        }
        reload()
    }

    /// 只删除项目子目录，保留用户主动选择的输出根目录本身。
    func deleteAllProjects() throws {
        try withOutputRoot { root in
            // 用户可能直接选择 Documents 等已有目录，绝不能删除未知子目录。
            // 只删除能解析出有效 context.xml + metadata.json 的 RepoContextPacker 项目。
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

    // MARK: - 目录暴露 / Finder 跳转

    func outputRootURL() throws -> URL {
        try resolveOutputRoot().url
    }

    /// 解析根 URL 时启动 security scope，给 caller 用 closure 形式访问。
    /// 外部（如 packer / ContextWriter）需要在 root 内做多步文件操作时走这里。
    func withOutputRoot<T>(_ operation: (URL) throws -> T) throws -> T {
        let resolved = try resolveOutputRoot()
        return try withResolvedRoot(resolved, operation)
    }

    func revealProject(_ project: RepoContextStoredProject) throws {
        try withOutputRoot { _ in
            NSWorkspace.shared.activateFileViewerSelecting([project.contextURL])
        }
    }

    func revealOutputRoot() throws {
        try withOutputRoot { root in
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    // MARK: - 内部：security scope 与迁移

    private func withResolvedRoot<T>(
        _ resolved: ResolvedOutputRoot,
        _ operation: (URL) throws -> T
    ) throws -> T {
        let didStart = resolved.securityScopeURL?.startAccessingSecurityScopedResource() ?? false
        if resolved.securityScopeURL != nil && !didStart {
            throw RepoContextStorageError.outputDirectoryUnavailable
        }
        defer {
            if didStart { resolved.securityScopeURL?.stopAccessingSecurityScopedResource() }
        }
        return try operation(resolved.url)
    }

    /// 只迁移能够识别的项目；目标冲突时以源目录版本覆盖。
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
                            owner: project.metadata.owner,
                            repo: project.metadata.repo
                        )
                        let temporary = target
                            .deletingLastPathComponent()
                            .appendingPathComponent(".\(project.metadata.repo).migration-\(UUID().uuidString)")
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

                // 目标已完整复制后，源清理由 best-effort 完成。
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
            throw RepoContextStorageError.invalidBookmark
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw RepoContextStorageError.outputDirectoryUnavailable
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
        .appendingPathComponent("Starcat/repocontext", isDirectory: true)
    }

    private func projectDirectory(root: URL, owner: String, repo: String) -> URL {
        root.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }

    private func scanProjects(root: URL) throws -> [RepoContextStoredProject] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var result: [RepoContextStoredProject] = []
        let owners = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for owner in owners where (try? owner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let repositories = try fileManager.contentsOfDirectory(
                at: owner,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for repository in repositories where (try? repository.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                do {
                    if let project = try loadProject(directory: repository) {
                        result.append(project)
                    }
                } catch {
                    // 单个 metadata 损坏不应让整个数据管理页失效；该目录不会进入删除范围。
                    continue
                }
            }
        }
        // 按最近访问时间倒序（lastAccessedAt 优先；为 nil 时退化到 generatedAt）。
        return result.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private func loadProject(directory: URL) throws -> RepoContextStoredProject? {
        let contextURL = directory.appendingPathComponent("context.xml")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let xmlSize = (try? contextURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileManager.fileExists(atPath: contextURL.path),
              fileManager.fileExists(atPath: metadataURL.path),
              xmlSize > 0 else {
            return nil
        }
        let decoder = JSONDecoder()
        let metadata = try decoder.decode(PackMetadata.self, from: Data(contentsOf: metadataURL))
        return RepoContextStoredProject(
            directoryURL: directory,
            contextURL: contextURL,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }
}
