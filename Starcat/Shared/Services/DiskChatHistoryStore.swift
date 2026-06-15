//
//  DiskChatHistoryStore.swift
//  Starcat
//
//  AI 对话历史磁盘存储（HOM-70 / 2026-06-15 dong4j 拍板「按 repo 多 session + 100MB LRU」）。
//
//  模块职责：
//  - 把 `(owner, repo)` 维度的多 session 对话历史以 JSON 落盘到
//    `~/Library/Application Support/com.starcat.app/chat-history/<owner>/<repo>/`；
//  - 给 `RepoAIChatViewModel` 提供 listSessions / loadSession / saveSession /
//    deleteSession / deleteAllForRepo / deleteEverything 六个接口；
//  - 暴露 `@Observable` 派生量给设置页存储 Tab 渲染「对话历史 N 项 · XX MB」；
//  - LRU 淘汰：总占用 > 100 MB 时按 session 文件 mtime 升序删（最久未访问优先），
//    每 N 次 saveSession 触发一次（不在 read 路径上跑）。
//
//  目录布局：
//      chat-history/
//        <owner>/
//          <repo>/
//            index.json               <-- session 索引（轻量列表，渲染 popover 用）
//            <session-id>.json        <-- 单个 session 的完整 messages + 元数据
//            <another-id>.json
//
//  关键约束（与 DiskReadmeTranslationCache / DiskAnySearchCache 的差异）：
//    1. **index.json 与 session 文件双源**：index 是性能优化（避免 list 时打开所有
//       session 文件），但**不是 source of truth**——任何对 session 的写入必须先
//       写 session.json 再更新 index.json，半失败时 index 可能跟 session 不一致；
//       `rebuildIndex(owner:repo:)` 提供自愈：扫所有 `<id>.json` 重建 index。
//       list 时若 index.json 不存在 / decode 失败，自动 fallback 到扫盘并重建。
//    2. **路径用 `<owner>/<repo>` 而非 `<repo_id>`**：与 DiskReadmeTranslationCache
//       同理——ephemeral repo（trending / activity）拿不到稳定 id；owner/repo 在
//       Finder 里也直观可读。
//    3. **session id 用 UUID**：避免 title 含路径非法字符或多个同名 session 撞名。
//       文件名直接是 `<uuid>.json`，UUID 是 ASCII 安全字符。
//    4. **不存 lastAccessedAt 字段**：与翻译缓存同款，用文件 mtime 表达"最近访问"。
//       loadSession 命中后 touch mtime → LRU sweep 看 mtime 升序删。
//    5. **保存粒度 = 整个 session**：每次发完一轮就把 session 整体 atomic 覆写。
//       单 session typical < 20 KB（30 轮对话 × ~600 字节），主线程 IO < 5 ms 不卡 UI。
//    6. **LRU 是全局的，不是按 repo**：100 MB 是整个 chat-history 的预算，不是每个
//       repo 100 MB。优先淘汰那些"长期没人访问"的 session，与用户「无过期时间」
//       约束不冲突：active session 持续 touch mtime 不会被删。
//    7. **@MainActor + 同步 IO**：与其它两个 Disk* 缓存同款。
//

import Foundation
import Observation

/// 对话历史存储错误。
enum DiskChatHistoryStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidPathComponent(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法定位对话历史目录，请重试或重启应用。"
        case .invalidPathComponent(let value):
            return "对话历史路径包含非法字符：\(value)。"
        }
    }
}

/// AI 对话历史磁盘存储（线程：所有公开方法 `@MainActor`）。
///
/// 单例由 `DiskChatHistoryStore.shared` 暴露；测试通过 `init(rootOverride:)` 隔离。
@MainActor
@Observable
final class DiskChatHistoryStore {

    /// 进程级单例。VM × N + 设置页 + tests 共用同一份 Observable 状态。
    static let shared = DiskChatHistoryStore()

    // MARK: - LRU 策略（dong4j 2026-06-15 拍板 100 MB）

    /// 总占用上限。超过即触发 LRU 删除（按 session 文件 mtime 升序删，直到 < limit）。
    private let maxTotalBytes: Int64 = 100 * 1024 * 1024 // 100 MB

    // MARK: - Observable 派生量（设置页存储 Tab 渲染用）

    /// 全部 chat-history（含 index.json + session.json）总字节数。
    private(set) var totalBytes: Int64 = 0

    /// session 总数（按所有 `<id>.json` 计；不算 index.json）。
    private(set) var sessionCount: Int = 0

    /// 已使用 chat 的仓库数（owner/repo 目录数）。
    private(set) var repoCount: Int = 0

    // MARK: - 内部状态

    private let fileManager: FileManager
    private let rootOverride: URL?

    /// saveSession 计数（每 5 次触发一次 LRU sweep）。
    private var saveCountSinceLastSweep: Int = 0
    private let saveCountSweepThreshold: Int = 5

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
        reload()
    }

    // MARK: - Session 增删查改

    /// 列出某 repo 的所有 session 概要，按 `updatedAt` 倒序（最新在前）。
    ///
    /// 优先读 `index.json`，缺失或损坏时自动 fallback 扫盘并重建 index。
    /// 返回空列表代表该 repo 还从未开过对话。
    func listSessions(owner: String, repo: String) throws -> [ChatSessionSummary] {
        let indexURL = try indexFile(owner: owner, repo: repo)

        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let index = try? decoder.decode(ChatSessionIndex.self, from: data) {
            return index.sessions.sorted { $0.updatedAt > $1.updatedAt }
        }

        // index 缺失 / 损坏：自愈，从所有 session 文件重建。
        AppLog.ai.warning("Chat history: index missing/corrupted, rebuilding owner=\(owner, privacy: .public) repo=\(repo, privacy: .public)")
        let rebuilt = try rebuildIndex(owner: owner, repo: repo)
        return rebuilt.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 常规命中路径在后台线程读取并解码 index，避免首次进入聊天面板时阻塞主线程。
    /// index 缺失或损坏仍回到主 actor 执行原有自愈逻辑；该路径属于低频异常路径。
    func listSessionsAsync(owner: String, repo: String) async throws -> [ChatSessionSummary] {
        let indexURL = try indexFile(owner: owner, repo: repo)
        let indexed = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: indexURL.path),
                  let data = try? Data(contentsOf: indexURL) else {
                return Optional<[ChatSessionSummary]>.none
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(ChatSessionIndex.self, from: data).sessions
        }.value

        if let indexed {
            return indexed.sorted { $0.updatedAt > $1.updatedAt }
        }
        return try listSessions(owner: owner, repo: repo)
    }

    /// 读单个 session 的完整内容（messages + carriedOverSummary 等）。
    /// 文件不存在 / 解码失败 → 返回 nil（解码失败时同时删除损坏文件，避免长期占空间）。
    /// 命中时 touch 文件 mtime 让 LRU 视其为"最近访问"。
    func loadSession(owner: String, repo: String, sessionId: UUID) throws -> ChatSession? {
        let fileURL = try sessionFile(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            AppLog.ai.warning("Chat history: read failed owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            let session = try decoder.decode(ChatSession.self, from: data)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return session
        } catch {
            AppLog.ai.warning("Chat history: decode failed, removing owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: fileURL)
            try? syncIndexAfterRemove(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

    /// 后台读取并解码完整 session。聊天历史增长后，JSON 大小不再影响主线程输入和动画。
    /// 解码失败沿用同步入口的清理语义，确保损坏文件和 index 能继续自愈。
    func loadSessionAsync(owner: String, repo: String, sessionId: UUID) async throws -> ChatSession? {
        let fileURL = try sessionFile(owner: owner, repo: repo, sessionId: sessionId)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: fileURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let session = try decoder.decode(ChatSession.self, from: data)
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: fileURL.path
                )
                return session
            }.value
        } catch {
            AppLog.ai.warning("Chat history: async read/decode failed, removing owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) sid=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            try? fileManager.removeItem(at: fileURL)
            try? syncIndexAfterRemove(owner: owner, repo: repo, sessionId: sessionId)
            return nil
        }
    }

    /// 写入 / 覆盖整个 session。同时更新 `index.json`。
    ///
    /// 顺序：先写 `<id>.json` 再更新 `index.json`——半失败时 index 还停留在旧状态，
    /// 下次 listSessions 自愈重建即可。
    func saveSession(owner: String, repo: String, session: ChatSession) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("\(session.id.uuidString).json")
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)

        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? Int64(data.count)
        try upsertIndex(
            owner: owner,
            repo: repo,
            summary: ChatSessionSummary(
                id: session.id,
                title: session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                messageCount: session.messages.count,
                bytes: size
            )
        )

        saveCountSinceLastSweep += 1
        reload()
        try maybeTriggerLRUSweep()
    }

    /// 删某 session（用户主动"删对话"入口）。
    func deleteSession(owner: String, repo: String, sessionId: UUID) throws {
        let fileURL = try sessionFile(owner: owner, repo: repo, sessionId: sessionId)
        try? fileManager.removeItem(at: fileURL)
        try syncIndexAfterRemove(owner: owner, repo: repo, sessionId: sessionId)
        try? removeEmptyProjectDirectory(owner: owner, repo: repo)
        reload()
    }

    /// 删某 repo 全部 session（AI 窗口右上角"清除当前 repo 对话"入口）。
    func deleteAllForRepo(owner: String, repo: String) throws {
        let dir = try projectDirectory(owner: owner, repo: repo)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
        try? removeEmptyOwnerDirectory(owner: owner)
        reload()
    }

    /// 清掉全部 chat-history（设置页"清除全部对话历史"按钮入口）。
    func deleteEverything() throws {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        saveCountSinceLastSweep = 0
        reload()
    }

    // MARK: - LRU sweep

    /// 触发 LRU 淘汰：若总量 > 100 MB 则按 session 文件 mtime 升序删（最久未访问优先）。
    ///
    /// **与翻译缓存差异**：chat-history 无 TTL（用户"无过期时间"约束），仅按总量裁剪。
    /// **不在 read 路径触发**：由 saveSession 累计 5 次后调一次。
    func lruSweep() throws {
        let root = try rootURL()
        guard fileManager.fileExists(atPath: root.path) else { return }

        var entries: [(url: URL, owner: String, repo: String, sessionId: UUID, mtime: Date, size: Int64)] = []

        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let owner = ownerDir.lastPathComponent
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                let repo = repoDir.lastPathComponent
                let files = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
                    guard let sid = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    entries.append((file, owner, repo, sid, mtime, size))
                }
            }
        }

        var totalBytes: Int64 = entries.reduce(0) { $0 + $1.size }
        guard totalBytes > maxTotalBytes else {
            saveCountSinceLastSweep = 0
            return
        }

        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            guard totalBytes > maxTotalBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            try? syncIndexAfterRemove(owner: entry.owner, repo: entry.repo, sessionId: entry.sessionId)
            totalBytes -= entry.size
        }

        cleanEmptyDirectories()
        saveCountSinceLastSweep = 0
        reload()
    }

    // MARK: - 索引维护

    /// 从某 repo 的 session 文件全量重建 index.json，返回重建后的 summary 列表。
    /// 用于 `listSessions` 在 index 缺失 / 损坏时自愈。
    @discardableResult
    func rebuildIndex(owner: String, repo: String) throws -> [ChatSessionSummary] {
        let dir = try projectDirectory(owner: owner, repo: repo)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }

        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var summaries: [ChatSessionSummary] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "index.json" {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(ChatSession.self, from: data)
            else { continue }
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            summaries.append(ChatSessionSummary(
                id: session.id,
                title: session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                messageCount: session.messages.count,
                bytes: size
            ))
        }

        let index = ChatSessionIndex(sessions: summaries)
        let indexURL = try indexFile(owner: owner, repo: repo)
        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
        return summaries
    }

    /// 单条 upsert：读 index.json → 替换 / 追加 → 写回。
    private func upsertIndex(owner: String, repo: String, summary: ChatSessionSummary) throws {
        let indexURL = try indexFile(owner: owner, repo: repo)
        var index: ChatSessionIndex
        if fileManager.fileExists(atPath: indexURL.path),
           let data = try? Data(contentsOf: indexURL),
           let existing = try? decoder.decode(ChatSessionIndex.self, from: data) {
            index = existing
        } else {
            index = ChatSessionIndex(sessions: [])
        }

        if let pos = index.sessions.firstIndex(where: { $0.id == summary.id }) {
            index.sessions[pos] = summary
        } else {
            index.sessions.append(summary)
        }

        let data = try encoder.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    /// 删 session 后从 index 移除对应项；index 为空时连 index.json 一起删。
    private func syncIndexAfterRemove(owner: String, repo: String, sessionId: UUID) throws {
        let indexURL = try indexFile(owner: owner, repo: repo)
        guard fileManager.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              var index = try? decoder.decode(ChatSessionIndex.self, from: data)
        else { return }

        index.sessions.removeAll { $0.id == sessionId }
        if index.sessions.isEmpty {
            try? fileManager.removeItem(at: indexURL)
        } else {
            let newData = try encoder.encode(index)
            try newData.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: - 重扫盘：刷新 totalBytes / sessionCount / repoCount

    /// 扫盘更新派生量。**与 lruSweep 不同**：reload 不删任何文件，纯只读统计。
    func reload() {
        var totalBytes: Int64 = 0
        var sessionCount: Int = 0
        var repoCount: Int = 0

        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path) else {
            self.totalBytes = 0
            self.sessionCount = 0
            self.repoCount = 0
            return
        }

        let ownerDirs = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ownerDir in ownerDirs where ownerDir.hasDirectoryPath {
            let repoDirs = (try? fileManager.contentsOfDirectory(at: ownerDir, includingPropertiesForKeys: nil)) ?? []
            for repoDir in repoDirs where repoDir.hasDirectoryPath {
                var hasSessionInThisRepo = false
                let files = (try? fileManager.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for file in files where file.pathExtension == "json" {
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalBytes += Int64(size)
                    }
                    if file.lastPathComponent != "index.json",
                       UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                        sessionCount += 1
                        hasSessionInThisRepo = true
                    }
                }
                if hasSessionInThisRepo { repoCount += 1 }
            }
        }

        self.totalBytes = totalBytes
        self.sessionCount = sessionCount
        self.repoCount = repoCount
    }

    // MARK: - 私有

    private func maybeTriggerLRUSweep() throws {
        guard saveCountSinceLastSweep >= saveCountSweepThreshold else { return }
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

    // MARK: - 路径构造

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiskChatHistoryStoreError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("chat-history", isDirectory: true)
    }

    private func ownerDirectory(owner: String) throws -> URL {
        try assertSafePathComponent(owner)
        return try rootURL().appendingPathComponent(owner, isDirectory: true)
    }

    private func projectDirectory(owner: String, repo: String) throws -> URL {
        try assertSafePathComponent(repo)
        return try ownerDirectory(owner: owner).appendingPathComponent(repo, isDirectory: true)
    }

    private func indexFile(owner: String, repo: String) throws -> URL {
        try projectDirectory(owner: owner, repo: repo).appendingPathComponent("index.json")
    }

    private func sessionFile(owner: String, repo: String, sessionId: UUID) throws -> URL {
        try projectDirectory(owner: owner, repo: repo)
            .appendingPathComponent("\(sessionId.uuidString).json")
    }

    /// 防御 path traversal：禁止 `.` / `..` / `/` 出现在 path component 中。
    private func assertSafePathComponent(_ value: String) throws {
        if value.isEmpty || value.contains("/") || value == "." || value == ".." {
            throw DiskChatHistoryStoreError.invalidPathComponent(value)
        }
    }
}

// MARK: - 内部 schema

/// `index.json` 文件实际编解码用的结构。
///
/// 单字段 wrapper 是为将来扩展留口子（如 `schemaVersion` / `lastRebuiltAt`）——
/// 直接序列化 `[ChatSessionSummary]` 顶层数组会让加字段成为破坏性变更。
private struct ChatSessionIndex: Codable {
    var sessions: [ChatSessionSummary]
}
