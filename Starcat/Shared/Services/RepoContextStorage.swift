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
//    - **文件系统是唯一信任源**：不维护内存索引；UI 渲染读 `summary` 缓存，
//      内部批量操作（如 deleteAllProjects、迁移）按需走 `scanProjects(root:)`。
//    - **@Observable + 单例**：和 CodeFlow 同款，让 SwiftUI 视图 (`StorageSettingsTab`)
//      直接观察 `storage.summary` 变化；单例避免在多处持有不同的 bookmark 状态。
//    - **写盘要先读旧 metadata**：W7 引入的 `generationCount` 字段语义是"累计次数"，
//      所以 `write` 内部要先 `loadProject(directory:)` 拿旧 `generationCount`，新值 +1。
//
//  关键约束（已踩过的坑级）：
//    1. HOM-203（2026-06-16）：PackMetadata.generatedAt 已改为 Date 类型，编解码
//       走 `PackMetadataCoder` 统一入口；写端 `.iso8601` 默认无 fractional seconds，
//       读端 lenient 兼容旧文件，杜绝早期版本的格式不对称导致 `.distantPast` 兜底。
//    2. Security-scoped bookmark 仅在 `startAccessingSecurityScopedResource` 期间有效；
//       任何 `FileManager` / `Data.write` / `JSONEncoder.encode().write` 都要在
//       `withOutputRoot { _ in ... }` 闭包内执行。
//    3. `deleteAllProjects` 不能直接 `removeItem(at: root)`——用户可能选择 `~/Documents`
//       作为根，整目录删会误删；必须先 `scanProjects` 得到识别的 owner/repo 子目录列表，
//       再逐个删（与 CodeFlow 同款防御）。
//    4. HOM-203：Summary 缓存（`.starcat-summary.json`）是 UI 渲染源，per-repo
//       metadata 仍是真源；写/touch/删/迁移时增量更新 summary，启动期一级目录数
//       不一致触发完整重建。详见 `loadOrRebuildSummary()`。
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

    /// 最近一次访问时间（W7 lastAccessedAt 字段；nil 时回退 `generatedAt`）。
    /// HOM-203：metadata 字段已是 Date 类型，不再需要二次解析。
    var lastActiveAt: Date {
        metadata.lastAccessedAt ?? metadata.generatedAt
    }

    /// 用户可见的"生成时间"（UI 列表行的副标题用）。
    var generatedAtDate: Date {
        metadata.generatedAt
    }

    private var metadataFileBytes: Int64 {
        let values = try? metadataURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    public static func == (lhs: RepoContextStoredProject, rhs: RepoContextStoredProject) -> Bool {
        lhs.directoryURL == rhs.directoryURL && lhs.metadata.commitSha == rhs.metadata.commitSha
    }
}

/// 知识库浏览器可直接消费的 RepoContext 文档快照。
///
/// UI 不持有 security-scoped URL，避免在授权 scope 已关闭后自行读文件；所有正文 IO
/// 仍由 `RepoContextStorage` 在 `withOutputRoot` 内完成。
struct RepoContextDocument: Sendable {
    let xml: String
    let metadata: PackMetadata

    var id: String { "\(metadata.owner)/\(metadata.repo)" }
}

/// HOM-203：产物根目录的汇总缓存（落盘为 `<root>/.starcat-summary.json`）。
///
/// 作用：让设置页 UI 一次磁盘读取拿到 4 个汇总数字（项目数 / 占用 / 累计生成 /
/// 最后生成时间），不再 O(n) 扫子目录、解析 n 份 metadata.json。
///
/// **不是真源**——per-repo `metadata.json` 仍然是产物的唯一权威。本文件只是 UI
/// 渲染的派生缓存，由 `RepoContextStorage` 在写/触/删/迁移路径上增量维护；启动期
/// 通过一级目录数比对兜底（用户在 Finder 里手动删/移产物时触发完整重建）。
struct RepoContextSummary: Codable, Sendable, Equatable {
    /// 模式版本，未来字段演进时 bump（不兼容时丢弃旧 summary 走完整重建）。
    let schemaVersion: Int
    /// 当前 owner/repo 项目数量（与 `scanProjects` 返回的数量对齐）。
    let projectCount: Int
    /// 全部产物字节累计（context.xml + metadata.json，与 `totalBytes` 对齐）。
    let totalBytes: Int64
    /// 全部 metadata.generationCount 累计（nil 项按 1 计）。
    let totalGenerationCount: Int
    /// 全部项目中最大的 generatedAt；空集合时为 nil。
    let latestGeneratedAt: Date?
    /// summary 自身落盘时间（用于调试 / 排查"是不是有人没更新 summary"）。
    let updatedAt: Date

    static let currentSchemaVersion: Int = 1
    static let filename: String = ".starcat-summary.json"

    static let empty: RepoContextSummary = .init(
        schemaVersion: currentSchemaVersion,
        projectCount: 0,
        totalBytes: 0,
        totalGenerationCount: 0,
        latestGeneratedAt: nil,
        updatedAt: .distantPast
    )

    func withUpdatedAt(_ date: Date) -> RepoContextSummary {
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

enum RepoContextStorageError: LocalizedError {
    case outputDirectoryUnavailable
    case invalidBookmark
    case invalidXML
    case invalidRootElement

    var errorDescription: String? {
        switch self {
        case .outputDirectoryUnavailable:
            return String.l10n("repoContext.storage.error.outputDirectoryUnavailable")
        case .invalidBookmark:
            return String.l10n("repoContext.storage.error.invalidBookmark")
        case .invalidXML:
            return String.l10n("repoContext.storage.error.invalidXML")
        case .invalidRootElement:
            return String.l10n("repoContext.storage.error.invalidRootElement")
        }
    }
}

/// 文件系统是 RepoContextPacker 产物的单一真源；本类型不建立数据库镜像。
@MainActor
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

    /// HOM-203：UI 渲染唯一来源。设置页只读取本字段，不再扫描 N 份 metadata.json。
    /// `nil` 表示尚未加载（首次进入设置页时由 `loadSummaryIfNeeded()` 触发加载）。
    private(set) var summary: RepoContextSummary?
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
        return (try? resolveOutputRoot().url.path) ?? String.l10n("storage.outputDirectory.bookmarkExpired")
    }

    /// 设置页 4 列汇总：项目占用字节累计。
    var totalBytes: Int64 { summary?.totalBytes ?? 0 }

    /// 设置页 4 列汇总：累计生成次数（W7 generationCount，nil 项按 1 计）。
    var totalGenerationCount: Int { summary?.totalGenerationCount ?? 0 }

    /// 设置页 4 列汇总：所有项目的最大 generatedAt；空集合时为 nil（UI 不渲染该列）。
    var latestGeneratedAt: Date? { summary?.latestGeneratedAt }

    /// 设置页 4 列汇总：项目数。也用于"全部清除"按钮的 disabled 判定。
    var projectCount: Int { summary?.projectCount ?? 0 }

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

    // MARK: - UI 刷新入口（HOM-203 改造）

    /// 设置页 `.task { reload() }` 入口。**优先走 summary 缓存**：
    ///   - summary 文件存在 + schemaVersion 匹配 + 一级目录数与 `projectCount` 偏差
    ///     ≤ 阈值 → 直接 decode 后塞进 `summary`，不扫子目录。
    ///   - 否则触发 `rebuildSummary()` 全量重扫，重写 summary 文件。
    ///
    /// 这是 HOM-203 性能优化的核心：用户有 576 个 repo 时，本方法 O(1) 完成；
    /// 旧版 `reload()` 会 O(n) decode 576 份 metadata.json，主线程明显卡顿。
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

    /// 强制完整重扫 + 重写 summary。手工调试 / "重建索引"调试入口可调用。
    /// 业务路径走 `reload()` 即可，无需直接调本方法。
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

    /// 一次性读取 XML 与 metadata，供知识库浏览器构建特殊托管分片。
    ///
    /// 不能让 ViewModel 先查项目再拿 URL 读取正文：自定义输出目录的 security scope
    /// 会在第一次调用返回时关闭。这里把两份真源放在同一个授权闭包内读取。
    func loadDocument(owner: String, repo: String) throws -> RepoContextDocument? {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            guard let project = try loadProject(directory: directory) else { return nil }
            let xml = try String(contentsOf: project.contextURL, encoding: .utf8)
            guard !xml.isEmpty else { return nil }
            return RepoContextDocument(xml: xml, metadata: project.metadata)
        }
    }

    /// 保存用户在知识库分片编辑器中修改的真实 `context.xml`。
    ///
    /// 手工编辑不是一次重新生成，因此保留 `generatedAt` / `generationCount`，只刷新
    /// 正文派生的 token、字节数与最近访问时间。校验和 metadata 编码都在任何写入前
    /// 完成，非法草稿不会破坏已有缓存。
    func saveEditedContextXML(_ xml: String, owner: String, repo: String) throws -> RepoContextDocument {
        try Self.validateContextXML(xml)
        let xmlData = Data(xml.utf8)

        return try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            guard let existing = try loadProject(directory: directory) else {
                throw RepoContextStorageError.outputDirectoryUnavailable
            }

            let updatedStats = PackStats(
                totalFiles: existing.metadata.stats.totalFiles,
                tier0Count: existing.metadata.stats.tier0Count,
                tier1Count: existing.metadata.stats.tier1Count,
                tier2Count: existing.metadata.stats.tier2Count,
                estimatedTokens: existing.metadata.stats.estimatedTokens,
                actualTokens: TokenEstimator.estimate(text: xml),
                contextXmlBytes: xmlData.count
            )
            let updatedMetadata = PackMetadata(
                schemaVersion: existing.metadata.schemaVersion,
                tierRulesVersion: existing.metadata.tierRulesVersion,
                tokenEstimatorVersion: existing.metadata.tokenEstimatorVersion,
                owner: existing.metadata.owner,
                repo: existing.metadata.repo,
                ref: existing.metadata.ref,
                commitSha: existing.metadata.commitSha,
                generatedAt: existing.metadata.generatedAt,
                tokenBudget: existing.metadata.tokenBudget,
                stats: updatedStats,
                skippedFiles: existing.metadata.skippedFiles,
                warnings: existing.metadata.warnings,
                tier1MaxLines: existing.metadata.tier1MaxLines,
                lastAccessedAt: .now,
                generationCount: existing.metadata.generationCount
            )
            // 两份新数据都先在内存构建成功，再进入原子替换；如果第二次写入失败，尽力
            // 回滚原数据，避免 context.xml 与 metadata.json 长期错配。
            let metadataData = try PackMetadataCoder.encoder.encode(updatedMetadata)
            let originalXML = try Data(contentsOf: existing.contextURL)
            let originalMetadata = try Data(contentsOf: existing.metadataURL)
            do {
                try xmlData.write(to: existing.contextURL, options: .atomic)
                try metadataData.write(to: existing.metadataURL, options: .atomic)
            } catch {
                try? originalXML.write(to: existing.contextURL, options: .atomic)
                try? originalMetadata.write(to: existing.metadataURL, options: .atomic)
                throw error
            }

            guard let updated = try loadProject(directory: directory) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            updateSummaryAfterEdit(root: root, oldProject: existing, newProject: updated)
            return RepoContextDocument(xml: xml, metadata: updated.metadata)
        }
    }

    /// Foundation XMLDocument 同时负责语法与根节点校验；不做字符级“看起来像 XML”判断。
    private static func validateContextXML(_ xml: String) throws {
        let document: XMLDocument
        do {
            document = try XMLDocument(xmlString: xml, options: [])
        } catch {
            throw RepoContextStorageError.invalidXML
        }
        guard document.rootElement()?.name == "repository" else {
            throw RepoContextStorageError.invalidRootElement
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
            let now = Date()
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
                lastAccessedAt: now,
                generationCount: nextGenerationCount
            )

            try PackMetadataCoder.encoder.encode(finalMetadata).write(to: metadataURL, options: .atomic)

            guard let project = try loadProject(directory: directory) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // HOM-203：summary 增量更新。新建 repo → projectCount/totalBytes/
            // totalGenerationCount 都增；已有 repo 重 pack → projectCount 不变，
            // totalBytes 按差额加减、generationCount += 1。
            updateSummaryAfterWrite(root: root, newProject: project, oldProject: existing)
            // 这里**不**调 reload()——W8 ContextWriter 外层会在写盘完成后统一调一次，
            // 避免重复扫描整棵目录（写完单个 repo 后再扫所有 owners 浪费）。
            return project
        }
    }

    /// W3 缓存命中后刷新 lastAccessedAt（让 UI 列表能按"最近使用"排序）。
    /// HOM-203：lastAccessedAt 不影响 summary（只关心 generatedAt），所以本方法
    /// 不动 summary，只更新 per-repo metadata.json。
    func touch(owner: String, repo: String) throws {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            guard let existing = try loadProject(directory: directory) else { return }
            let now = Date()
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
                lastAccessedAt: now,
                generationCount: existing.metadata.generationCount
            )
            try PackMetadataCoder.encoder.encode(updated).write(to: existing.metadataURL, options: .atomic)
        }
    }

    // MARK: - 删除入口

    func deleteProject(owner: String, repo: String) throws {
        try withOutputRoot { root in
            let directory = projectDirectory(root: root, owner: owner, repo: repo)
            // HOM-203：删除前先取一份 stored 用于 summary 反推（拿 totalBytes /
            // generationCount / generatedAt 才能正确扣减）。
            let removedProject = try? loadProject(directory: directory)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
                // owner 目录如果空了一起清掉（与 CodeFlow 同款）。
                let ownerDirectory = directory.deletingLastPathComponent()
                if (try? fileManager.contentsOfDirectory(atPath: ownerDirectory.path).isEmpty) == true {
                    try? fileManager.removeItem(at: ownerDirectory)
                }
            }
            updateSummaryAfterDelete(root: root, removed: removedProject)
        }
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
            // HOM-203：summary 直接清零并落盘。
            writeSummary(.empty.withUpdatedAt(.now), root: root)
            summary = .empty.withUpdatedAt(.now)
        }
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

    // MARK: - 内部：summary 缓存读写（HOM-203）

    /// `reload()` 主路径：优先用 summary，必要时降级重建。
    ///
    /// 偏差阈值用 ±10%（对 576 项目约 ±58 个的容忍度），平衡"用户在 Finder 删了
    /// 个别项目时是否触发重建"vs"误报抖动"。极端边界（< 10 项目）始终重建，让
    /// 小数据集走严格模式。
    private func loadOrRebuildSummary(root: URL) throws {
        guard fileManager.fileExists(atPath: root.path) else {
            // 输出根尚不存在（用户从未生成过）→ 写入空 summary 即可，不报错。
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let empty = RepoContextSummary.empty.withUpdatedAt(.now)
            writeSummary(empty, root: root)
            summary = empty
            return
        }

        if let cached = readSummary(root: root) {
            // schemaVersion 不匹配 → 旧版结构，丢弃重建。
            if cached.schemaVersion != RepoContextSummary.currentSchemaVersion {
                try rebuildSummaryOnDisk(root: root)
                return
            }
            // 一级目录数与 cached.projectCount 偏差校验：用户可能在 Finder 里手动
            // 删/移产物。这里只数 owner/repo 目录数（不解析 JSON），代价 O(owners)。
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

    /// 全量重扫并落盘 summary。
    private func rebuildSummaryOnDisk(root: URL) throws {
        let scanned = try scanProjects(root: root)
        let computed = RepoContextSummary(
            schemaVersion: RepoContextSummary.currentSchemaVersion,
            projectCount: scanned.count,
            totalBytes: scanned.reduce(0) { $0 + $1.totalBytes },
            totalGenerationCount: scanned.reduce(0) { $0 + ($1.metadata.generationCount ?? 1) },
            latestGeneratedAt: scanned.map(\.generatedAtDate).max(),
            updatedAt: .now
        )
        writeSummary(computed, root: root)
        summary = computed
    }

    /// 写盘后增量更新 summary。
    /// - oldProject 为 nil：新增 repo → projectCount +1、totalBytes +new、count +new.gen。
    /// - oldProject 非 nil：重 pack → projectCount 不变、totalBytes 用差额、count +1。
    ///
    /// **关键边界**：如果当前 `summary` 还是 nil（用户没打开过设置页就直接生成了
    /// 上下文），不能从 `.empty` 起增量——线上磁盘可能已有 N 个老项目。这种情况
    /// 直接走 `rebuildSummaryOnDisk` 全量重扫，扫描结果天然包含本次新写的 metadata。
    private func updateSummaryAfterWrite(
        root: URL,
        newProject: RepoContextStoredProject,
        oldProject: RepoContextStoredProject?
    ) {
        guard let base = summary ?? readSummary(root: root) else {
            try? rebuildSummaryOnDisk(root: root)
            return
        }
        let projectCount = base.projectCount + (oldProject == nil ? 1 : 0)
        let totalBytes = base.totalBytes + (newProject.totalBytes - (oldProject?.totalBytes ?? 0))
        let totalGenerationCount = base.totalGenerationCount + 1
        let latestGeneratedAt: Date? = {
            let candidate = newProject.generatedAtDate
            if let existing = base.latestGeneratedAt {
                return max(existing, candidate)
            }
            return candidate
        }()
        let updated = RepoContextSummary(
            schemaVersion: RepoContextSummary.currentSchemaVersion,
            projectCount: projectCount,
            totalBytes: totalBytes,
            totalGenerationCount: totalGenerationCount,
            latestGeneratedAt: latestGeneratedAt,
            updatedAt: .now
        )
        writeSummary(updated, root: root)
        summary = updated
    }

    /// 手工编辑只改变项目占用，不增加“累计生成次数”或生成时间。
    private func updateSummaryAfterEdit(
        root: URL,
        oldProject: RepoContextStoredProject,
        newProject: RepoContextStoredProject
    ) {
        guard let base = summary ?? readSummary(root: root) else {
            try? rebuildSummaryOnDisk(root: root)
            return
        }
        let updated = RepoContextSummary(
            schemaVersion: RepoContextSummary.currentSchemaVersion,
            projectCount: base.projectCount,
            totalBytes: max(0, base.totalBytes + newProject.totalBytes - oldProject.totalBytes),
            totalGenerationCount: base.totalGenerationCount,
            latestGeneratedAt: base.latestGeneratedAt,
            updatedAt: .now
        )
        writeSummary(updated, root: root)
        summary = updated
    }

    /// 删除后增量更新 summary。
    /// - removed 为 nil：原本就找不到该项目（损坏 / 不存在），summary 不变只刷 updatedAt。
    /// - summary 与磁盘 summary 都缺失时（首次场景）：走全量重建，重建结果已经
    ///   反映"项目已删"。
    private func updateSummaryAfterDelete(
        root: URL,
        removed: RepoContextStoredProject?
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
        let nextGen = max(0, base.totalGenerationCount - (removed.metadata.generationCount ?? 1))
        // 删掉的恰好是"最后生成时间持有者"时，无法 O(1) 找出新的最大值——这里直接
        // 把 latestGeneratedAt 标记为 nil，下次 `reload()` 走 summary 命中路径仍能
        // 用旧值；除非用户手动重建，否则只在删完所有项目时显示空。这是为了避免
        // 单删触发全量扫描的代价；可接受的精度损失。
        let nextLatest: Date? = {
            if nextCount == 0 { return nil }
            return base.latestGeneratedAt
        }()
        let updated = RepoContextSummary(
            schemaVersion: RepoContextSummary.currentSchemaVersion,
            projectCount: nextCount,
            totalBytes: nextBytes,
            totalGenerationCount: nextGen,
            latestGeneratedAt: nextLatest,
            updatedAt: .now
        )
        writeSummary(updated, root: root)
        summary = updated
    }

    /// 读 summary.json；不存在 / decode 失败 → nil（让上层走重建）。
    private func readSummary(root: URL) -> RepoContextSummary? {
        let url = root.appendingPathComponent(RepoContextSummary.filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? PackMetadataCoder.decoder.decode(RepoContextSummary.self, from: data)
    }

    /// 写 summary.json；I/O 错误 best-effort 吞掉并打 log——summary 是缓存，
    /// 写失败不能阻止真源（per-repo metadata.json）落盘。
    private func writeSummary(_ summary: RepoContextSummary, root: URL) {
        let url = root.appendingPathComponent(RepoContextSummary.filename, isDirectory: false)
        do {
            let data = try PackMetadataCoder.encoder.encode(summary)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.ai.error("[RepoContextStorage] summary write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 一级目录数估算：仅遍历 root 的 owner 子目录然后 list 一层 repo 目录，**不解析
    /// 任何 JSON**。复杂度 O(owners + repos)，绝大多数情况比 `scanProjects` 快两个数量级。
    private func approximateProjectCount(root: URL) throws -> Int {
        let owners = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var count = 0
        for owner in owners where (try? owner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let repos = try fileManager.contentsOfDirectory(
                at: owner,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            count += repos.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.count
        }
        return count
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
                // HOM-203：源端 summary 也清掉，避免下次切回时被旧缓存误导
                // （loadOrRebuildSummary 会重建，但提前删 summary 让用户在 Finder 里
                // 看到的目录状态更干净）。
                let sourceSummary = sourceRoot.appendingPathComponent(RepoContextSummary.filename, isDirectory: false)
                try? fileManager.removeItem(at: sourceSummary)
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
        // HOM-203：用 PackMetadataCoder.decoder（lenient ISO-8601 策略），让带/不带
        // fractional seconds 的旧文件都能正确解析为 Date。
        let metadata = try PackMetadataCoder.decoder.decode(PackMetadata.self, from: Data(contentsOf: metadataURL))
        return RepoContextStoredProject(
            directoryURL: directory,
            contextURL: contextURL,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }
}
