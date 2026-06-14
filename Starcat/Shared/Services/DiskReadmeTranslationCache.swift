//
//  DiskReadmeTranslationCache.swift
//  Starcat
//
//  README AI 翻译磁盘缓存（HOM-68 v2 / 2026-06-15 砍 DB 走纯磁盘）。
//
//  模块职责：
//  - 把 LLM 翻译产物落盘到 `~/Library/Application Support/com.starcat.app/translations-cache/<owner>/<repo>/<lang>.{html,json}`；
//  - 提供 find / upsert / delete / deleteAll(repo) / deleteEverything（4+1）接口给
//    `ReadmeTranslationService` 走业务；
//  - 暴露 `totalBytes` / `itemCount` / `latestCreatedAt` 三个 `@Observable` 派生量
//    给设置页存储 Tab 渲染「翻译缓存 xxx」用量行；
//  - LRU 淘汰：总占用 > 50 MB 或单条 `.json` 文件 mtime 超过 60 天的，由 `lruSweep`
//    清掉（在每 N 次 upsert 后由 service 主动触发，不在 read 路径里跑）。
//
//  关键约束（与历史 DB 方案的差异 / 已踩过的坑）：
//    1. **路径用 `<owner>/<repo>/<lang>` 而非 `<repo_id>/<lang>`**：trending / activity
//       这类 ephemeral repo 拿不到稳定 GitHub repo id（`makeEphemeralRepo()` 兜底为 0
//       或 0），而 owner/repo 在 trending DTO 里始终是真值。同时 owner/repo 命名让
//       Finder 用户可读。重命名失效是可接受代价：GitHub 重命名极少，且 301 跳转后下次
//       打开会按新 owner/repo 重新翻译生成新缓存。
//    2. **`lastAccessedAt` 用文件 mtime 表达，不存进 JSON**：每次 `find` 命中后调
//       `setAttributes(.modificationDate)` 更新 `<lang>.json` 的 mtime。这样 LRU
//       sweep 不需要解析 JSON 就能判过期，read 路径也不需要 rewrite JSON 重写整文件。
//    3. **`.html` + `.json` 双文件**：HTML 体积大（最大几百 KB），JSON 仅 ~300 字节。
//       拆开让 list / lruSweep 只需要扫 JSON，体积小快；UI 显示用量需要文件大小时
//       再读 `.html` 的 `.fileSizeKey`。
//    4. **写入原子性**：`Data.write(to:options:.atomic)` 已经保证原子重命名，不会出
//       现 .json 写完但 .html 半截的状况。但写 HTML 失败时要清掉同 dir 的 .json
//       残留——这通过"先写 HTML 后写 JSON"的顺序保证：若 HTML 写挂，JSON 还没写，
//       自然不会留半残；若 JSON 写挂，HTML 已就位但 metadata 缺失，下次 find 会按
//       "JSON 不存在 → 无缓存"处理，并不会上屏错乱译文。
//    5. **目录扫描容错**：第三方工具误塞文件 / metadata JSON 损坏 → 跳过该条不
//       crash，由 `AppLog` warning 提示开发者。生产用户不会看到。
//    6. **@MainActor + 同步 IO**：与 `RepoContextStorage` 同款。翻译写入是 LLM 流
//       式完成后的一次性 < 200 KB 写操作，主线程 IO < 10 ms 不卡 UI；read 类似。
//

import Foundation
import Observation

/// 翻译磁盘缓存错误。
enum DiskReadmeTranslationCacheError: LocalizedError {
    /// `Application Support` 目录获取失败（macOS 沙盒下极少发生）。
    case applicationSupportUnavailable
    /// 路径中 owner / repo 含非法字符（用作目录名时）。
    case invalidPathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法定位翻译缓存目录，请重试或重启应用。"
        case .invalidPathComponent(let value):
            return "翻译缓存路径包含非法字符：\(value)。"
        }
    }
}

/// README 翻译磁盘缓存（线程：所有公开方法 `@MainActor`）。
///
/// **为什么不是 `actor`**：service / VM / Settings UI 都在 `@MainActor` 上；做成
/// actor 反而多一次 hop 没收益。IO 体积小（< 200 KB），主线程同步写不卡 UI。
@MainActor
@Observable
final class DiskReadmeTranslationCache: ReadmeTranslationRepositoryProtocol {

    /// 进程级单例。设置页 + service + tests 都共用同一份 Observable 状态，避免双源
    /// 不同步。**测试场景**通过 `init(rootOverride:)` 注入临时目录绕过单例，详见
    /// 同名 init doc-comment。
    static let shared = DiskReadmeTranslationCache()

    // MARK: - LRU 策略（HOM-68 v2 / dong4j 2026-06-15 拍板 50 MB / 60 天）

    /// 总占用上限。超过即触发 LRU 删除（按 `.json` 文件 mtime 升序删，直到 < limit）。
    private let maxTotalBytes: Int64 = 50 * 1024 * 1024 // 50 MB

    /// 单条最长不访问时长。超过即在下一次 `lruSweep` 时被删（无论是否触及总量上限）。
    private let maxIdleInterval: TimeInterval = 60 * 24 * 60 * 60 // 60 天

    // MARK: - Observable 派生量（设置页存储 Tab 渲染用）
    //
    // 通过 `reload()` 同步扫盘更新；`upsert` / `delete*` 写入后自动调 `reload()`，
    // 让 UI 立即看到最新数字。

    /// 全部翻译产物（含 .html + .json）总字节数。
    private(set) var totalBytes: Int64 = 0

    /// 缓存条目数（按 `(owner, repo, lang)` 元组计）。
    private(set) var itemCount: Int = 0

    /// 最近一次创建时间（取所有条目 metadata.createdAt 的最大值）。nil 表示空缓存。
    private(set) var latestCreatedAt: Date?

    // MARK: - 内部状态

    private let fileManager: FileManager
    private let rootOverride: URL?

    /// upsert 计数（每 5 次触发一次 LRU sweep）。详见 `maybeTriggerLRUSweep()`。
    private var upsertCountSinceLastSweep: Int = 0
    private let upsertCountSweepThreshold: Int = 5

    /// 编解码器（拒绝转义中文等 ASCII 友好策略，便于开发者直接 cat 看 JSON）。
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    private let decoder = JSONDecoder()

    /// 默认走 `Application Support/com.starcat.app/translations-cache/`，shared 单例
    /// 与 `RepoContextStorage` 同款逻辑。
    ///
    /// `rootOverride` 仅给单元测试用——传一个 `URL(fileURLWithPath: tmpDir)` 让每个
    /// 用例隔离不污染真实目录。**生产路径绝不要传**。
    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    // MARK: - ReadmeTranslationRepositoryProtocol

    /// 查 `<owner>/<repo>/<targetLanguage>.json` + `<targetLanguage>.html`，命中时
    /// 重组 `ReadmeTranslation` 返回；同时 `touch` JSON 文件的 mtime（标记"最近访问"）。
    ///
    /// **为什么不存 lastAccessedAt 字段**：那样每次命中都要重写 ~300B JSON，IO 浪费；
    /// 用文件 mtime 表达"最近访问"是 POSIX 标准做法，0 解析成本。
    func find(owner: String, repo: String, targetLanguage: String) async throws -> ReadmeTranslation? {
        let metadataURL = try metadataFile(owner: owner, repo: repo, targetLanguage: targetLanguage)
        let htmlURL = try htmlFile(owner: owner, repo: repo, targetLanguage: targetLanguage)

        guard fileManager.fileExists(atPath: metadataURL.path),
              fileManager.fileExists(atPath: htmlURL.path) else {
            return nil
        }

        let metadataData: Data
        let html: String
        do {
            metadataData = try Data(contentsOf: metadataURL)
            html = try String(contentsOf: htmlURL, encoding: .utf8)
        } catch {
            AppLog.ai.warning("Translation disk cache: read failed owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) lang=\(targetLanguage, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        let stored: StoredMetadata
        do {
            stored = try decoder.decode(StoredMetadata.self, from: metadataData)
        } catch {
            // 损坏的 metadata → 删掉这对文件让下次重翻覆盖，避免一直返回 nil 又一直
            // 占空间。删除失败也不抛错，最坏情况是占着位等下次 lruSweep 兜底清。
            AppLog.ai.warning("Translation disk cache: metadata decode failed, removing pair owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) lang=\(targetLanguage, privacy: .public)")
            try? fileManager.removeItem(at: metadataURL)
            try? fileManager.removeItem(at: htmlURL)
            return nil
        }

        // touch mtime 表达 "最近访问"，LRU sweep 用这个字段决定淘汰顺序。
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: metadataURL.path)

        return ReadmeTranslation(
            repoId: stored.repoId,
            targetLanguage: stored.targetLanguage,
            model: stored.model,
            sourceHash: stored.sourceHash,
            translatedHtml: html,
            size: stored.size,
            createdAt: stored.createdAt
        )
    }

    /// 写入 `<owner>/<repo>/<targetLanguage>.{html,json}`。先写 HTML 后写 JSON，
    /// 半失败的最坏情况是 HTML 在 JSON 缺失，`find` 会按"无缓存"处理（不上屏脏数据）。
    func upsert(_ translation: ReadmeTranslation, owner: String, repo: String) async throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let htmlURL = dir.appendingPathComponent("\(translation.targetLanguage).html")
        let metadataURL = dir.appendingPathComponent("\(translation.targetLanguage).json")

        let htmlData = Data(translation.translatedHtml.utf8)
        try htmlData.write(to: htmlURL, options: .atomic)

        let stored = StoredMetadata(
            repoId: translation.repoId,
            owner: owner,
            repo: repo,
            targetLanguage: translation.targetLanguage,
            model: translation.model,
            sourceHash: translation.sourceHash,
            size: translation.size,
            createdAt: translation.createdAt
        )
        let metadataData = try encoder.encode(stored)
        try metadataData.write(to: metadataURL, options: .atomic)

        upsertCountSinceLastSweep += 1
        reload()
        try maybeTriggerLRUSweep()
    }

    /// 删某仓库的某个语言版本（用户主动"丢弃译文"入口；当前 UI 暂不接，但留接口）。
    func delete(owner: String, repo: String, targetLanguage: String) async throws {
        let htmlURL = try htmlFile(owner: owner, repo: repo, targetLanguage: targetLanguage)
        let metadataURL = try metadataFile(owner: owner, repo: repo, targetLanguage: targetLanguage)
        try? fileManager.removeItem(at: htmlURL)
        try? fileManager.removeItem(at: metadataURL)
        try? removeEmptyProjectDirectory(owner: owner, repo: repo)
        reload()
    }

    /// 删某仓库所有语言译文（CASCADE 同义，当前业务无人调；保留接口与 protocol 对齐）。
    func deleteAll(owner: String, repo: String) async throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        // 删完该仓库目录后，再尝试清掉空的 owner 目录（递归到根之前停）。
        try? removeEmptyOwnerDirectory(owner: owner)
        reload()
    }

    /// 清掉全部翻译缓存（设置页"清除翻译缓存"按钮入口）。
    ///
    /// 实现：删完整个 `<root>/translations-cache/` 目录后立即 reload。
    func deleteEverything() async throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        upsertCountSinceLastSweep = 0
        reload()
    }

    // MARK: - LRU sweep

    /// 触发 LRU 淘汰：先删 60 天未访问的条目，若总量仍 > 50 MB 则继续按 mtime
    /// 升序删到 < limit 为止。
    ///
    /// **不在 read 路径触发**：避免命中即扫盘的性能浪费。由 `upsert` 累计 5 次后
    /// 调一次 + 设置页打开时手动调一次（前者由 service 触发；后者待 UI 上点"清除"
    /// 时手动覆盖）。
    func lruSweep() throws {
        let root = try rootURL()
        guard fileManager.fileExists(atPath: root.path) else { return }

        let now = Date()
        var entries: [(metadataURL: URL, htmlURL: URL, mtime: Date, size: Int64)] = []

        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let files = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "json" {
                    let html = file.deletingPathExtension().appendingPathExtension("html")
                    let metaSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let htmlSize = (try? html.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    entries.append((file, html, mtime, Int64(metaSize + htmlSize)))
                }
            }
        }

        // 1) 删 60 天未访问的
        var totalBytes: Int64 = entries.reduce(0) { $0 + $1.size }
        var remaining: [(metadataURL: URL, htmlURL: URL, mtime: Date, size: Int64)] = []
        for entry in entries {
            if now.timeIntervalSince(entry.mtime) > maxIdleInterval {
                try? fileManager.removeItem(at: entry.metadataURL)
                try? fileManager.removeItem(at: entry.htmlURL)
                totalBytes -= entry.size
            } else {
                remaining.append(entry)
            }
        }

        // 2) 若仍超 50 MB，按 mtime 升序（最久未访问优先）继续删
        if totalBytes > maxTotalBytes {
            remaining.sort { $0.mtime < $1.mtime }
            for entry in remaining {
                guard totalBytes > maxTotalBytes else { break }
                try? fileManager.removeItem(at: entry.metadataURL)
                try? fileManager.removeItem(at: entry.htmlURL)
                totalBytes -= entry.size
            }
        }

        // 3) 收拾空目录（不强制；下次 reload 也能正常派生数字）
        cleanEmptyDirectories()
        upsertCountSinceLastSweep = 0
        reload()
    }

    // MARK: - 重扫盘：刷新 totalBytes / itemCount / latestCreatedAt

    /// 扫盘更新派生量。**与 `lruSweep` 不同**：reload 不删任何文件，纯只读统计。
    ///
    /// 公开是为了让设置页 `.task { cache.reload() }` 在 Tab 出现时强制刷一遍数字。
    func reload() {
        var totalBytes: Int64 = 0
        var itemCount: Int = 0
        var latestCreatedAt: Date?

        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path) else {
            self.totalBytes = 0
            self.itemCount = 0
            self.latestCreatedAt = nil
            return
        }

        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let files = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for file in files where file.pathExtension == "json" {
                    let html = file.deletingPathExtension().appendingPathExtension("html")
                    guard fileManager.fileExists(atPath: html.path) else { continue }
                    itemCount += 1
                    if let metaSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalBytes += Int64(metaSize)
                    }
                    if let htmlSize = try? html.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalBytes += Int64(htmlSize)
                    }
                    if let data = try? Data(contentsOf: file),
                       let stored = try? decoder.decode(StoredMetadata.self, from: data),
                       let created = ISO8601DateFormatter.shared.date(from: stored.createdAt) {
                        if latestCreatedAt == nil || created > latestCreatedAt! {
                            latestCreatedAt = created
                        }
                    }
                }
            }
        }

        self.totalBytes = totalBytes
        self.itemCount = itemCount
        self.latestCreatedAt = latestCreatedAt
    }

    // MARK: - 私有：路径 / 触发 / 清扫

    private func maybeTriggerLRUSweep() throws {
        guard upsertCountSinceLastSweep >= upsertCountSweepThreshold else { return }
        try lruSweep()
    }

    private func cleanEmptyDirectories() {
        guard let root = try? rootURL() else { return }
        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let files = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil)) ?? []
                if files.isEmpty {
                    try? fileManager.removeItem(at: repoDir)
                }
            }
            let remainingRepos = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            if remainingRepos.isEmpty {
                try? fileManager.removeItem(at: ownerDir)
            }
        }
    }

    private func removeEmptyProjectDirectory(owner: String, repo: String) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if files.isEmpty {
            try? fileManager.removeItem(at: dir)
        }
        try? removeEmptyOwnerDirectory(owner: owner)
    }

    private func removeEmptyOwnerDirectory(owner: String) throws {
        let owners = try ownerDirectory(owner: owner)
        let children = (try? fileManager.contentsOfDirectory(at: owners, includingPropertiesForKeys: nil)) ?? []
        if children.isEmpty {
            try? fileManager.removeItem(at: owners)
        }
    }

    // MARK: - 私有：路径构造

    /// `~/Library/Application Support/com.starcat.app/translations-cache/` 或测试目录。
    ///
    /// **路径选择理由**：与 `RepoContextStorage` / `CodeFlowStorage` 同级，便于
    /// dong4j Finder 排查；不挂在多账号 `users/<id>/` 下面是因为翻译不携带用户私密
    /// 数据，跨账号共享同一份缓存能省 LLM 重复调用成本。
    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskReadmeTranslationCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("translations-cache", isDirectory: true)
    }

    private func ownerDirectory(owner: String) throws -> URL {
        try assertSafePathComponent(owner)
        return try rootURL().appendingPathComponent(owner, isDirectory: true)
    }

    private func projectDirectory(owner: String, repo: String) throws -> URL {
        try assertSafePathComponent(repo)
        return try ownerDirectory(owner: owner).appendingPathComponent(repo, isDirectory: true)
    }

    private func htmlFile(owner: String, repo: String, targetLanguage: String) throws -> URL {
        try assertSafePathComponent(targetLanguage)
        return try projectDirectory(owner: owner, repo: repo)
            .appendingPathComponent("\(targetLanguage).html")
    }

    private func metadataFile(owner: String, repo: String, targetLanguage: String) throws -> URL {
        try assertSafePathComponent(targetLanguage)
        return try projectDirectory(owner: owner, repo: repo)
            .appendingPathComponent("\(targetLanguage).json")
    }

    /// 防御 path traversal：禁止 `.` / `..` / `/` 出现在 path component 中。
    /// GitHub owner / repo 命名规则不含这些字符，命中即是恶意 / 异常输入。
    private func assertSafePathComponent(_ value: String) throws {
        if value.isEmpty || value.contains("/") || value == "." || value == ".." {
            throw DiskReadmeTranslationCacheError.invalidPathComponent(value)
        }
    }
}

// MARK: - 磁盘 JSON metadata schema

/// `<lang>.json` 文件实际编解码用的结构。
///
/// **不直接用 `ReadmeTranslation`**：那个类型代表"上层业务模型"，含 `translatedHtml`
/// 字段（HTML 体积大）。disk 把 HTML 与 metadata 拆两文件，metadata 单独这个 struct
/// 体积小，扫盘只 decode metadata 即可（不必载入 HTML 进内存）。
private struct StoredMetadata: Codable {
    let repoId: Int64?
    let owner: String
    let repo: String
    let targetLanguage: String
    let model: String
    let sourceHash: String
    let size: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case owner
        case repo
        case targetLanguage = "target_language"
        case model
        case sourceHash = "source_hash"
        case size
        case createdAt = "created_at"
    }
}
