//
//  DatabaseManager.swift
//  Starcat
//
//  GRDB 数据库门面。
//
//  设计要点（2026-06-12 多账号 DB 隔离重构）：
//  ─────────────────────────────────────────────────────────────────────
//  - **不再是单例**：原 `static let shared` 已删除。生产 / 测试 / Preview
//    各自创建实例。AppDependencies 装配时 `try DatabaseManager(userId: nil)`，
//    启动期默认走 `users/_anonymous` 占位 DB。
//
//  - **按 GitHub User ID 物理隔离**：路径
//      Application Support/com.starcat.app/users/<userId>/starcat.sqlite
//    未登录态用 `users/_anonymous`。避免 Repository 加 nil 特判，所有时刻
//    `database.writer` 都拿得到一个可用 DB（空库即可）。
//
//  - **A-1 实施：内部切 writer，不重建 AppDependencies**：
//    DatabaseManager 持有 `var currentPool: DatabasePool`，协议 getter
//    `writer` 每次访问拿到当前 pool。Repository 通过 `database.writer.write`
//    访问 → 切账号时只换 `currentPool`，所有 Repository / Service 实例
//    完全不动（保留它们的 timer / observer / in-flight Task）。
//
//  - **场景定义**：dong4j 拍板的"先退出再登录另一个账号"语义。
//    不存在"登录态下硬切账号"的并发噩梦，因此 reopen 实现可以简单地
//    "释放旧 pool 强引用 → 建新 pool"，不需要 quiesce / cancel in-flight。
//    （但实施者仍需在 signOut 流程里确认所有后台任务已被停止；详见 plan §9 R1。）
//
//  - **持有 `any DatabaseWriter`，不锁死 DatabasePool 或 DatabaseQueue**：
//    生产环境：DatabasePool（文件 + WAL，多读单写）
//    测试环境：DatabaseQueue（内存）— 见 `InMemoryDatabaseManager`
//
//  - **启动期跑 Migration**；失败 throw，由 App 启动流程决定崩溃或提示
//
//  - **通过 DatabaseManaging 协议依赖**，测试可注入 InMemoryDatabaseManager
//
//  线程模型：DatabaseWriter 自身线程安全；`reopen(userId:)` 标 `@MainActor`
//  保证切换路径串行不并发。
//

import Foundation
import GRDB

/// 数据库错误。
enum DatabaseError: Error, LocalizedError {
    case applicationSupportNotFound
    case migrationFailed(underlying: Error)
    case openFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .applicationSupportNotFound:
            return String.l10n("database.error.applicationSupportNotFound")
        case .migrationFailed(let error):
            return String(format: String.l10n("database.error.migrationFailedFormat"), error.localizedDescription)
        case .openFailed(let error):
            return String(format: String.l10n("database.error.openFailedFormat"), error.localizedDescription)
        }
    }
}

/// 数据库门面协议，业务层通过此协议依赖数据库。
///
/// 同时支持文件库（生产）与内存库（测试），二者实现该协议。
///
/// **关键约束**：`writer` 是 getter 而非 let 字段——实现侧（DatabaseManager）
/// 可以在 reopen 时换内部 pool，调用方每次访问 `database.writer` 都拿到最新
/// 实例。Repository 必须以 `private let database: any DatabaseManaging`
/// 形式持有依赖、并在每次 query 时走 `database.writer.read/write`，
/// **不要** 把 `database.writer` 拷出来缓存为 `let writer`。
protocol DatabaseManaging: Sendable {
    /// 文件路径；内存库返回 nil。
    var databasePath: String? { get }

    /// 当前指向的 GitHub User ID；`nil` 表示未登录态（_anonymous DB）。
    /// 单元测试用于断言"切换到指定账号"是否成功。
    var currentUserId: Int64? { get }

    /// GRDB writer，封装了对应的 Pool 或 Queue。
    var writer: any DatabaseWriter { get }

    /// 切换到指定 GitHub User ID 对应的数据库。`nil` 表示切到未登录占位库。
    ///
    /// 调用方（AppDependencies.switchUserDatabase → AuthSession 4 个钩子点）
    /// 在登录成功 / 登出 / 401 失效时触发。生产实现：关老 pool → 开新 pool → migrate。
    /// 内存实现：建新空 queue + migrate（模拟"切到新账号 = 空库"语义）。
    @MainActor
    func reopen(userId: Int64?) async throws
}

/// 生产环境数据库管理器。
///
/// 不再是单例。AppDependencies 启动期构造一次（用 `userId: nil` 走 anonymous），
/// 登录 / 登出时调用 `reopen(userId:)` 切换到对应账号的 DB 文件。
final class DatabaseManager: DatabaseManaging, @unchecked Sendable {

    // MARK: - 属性

    /// 当前 DatabasePool。`reopen` 时替换；Repository 通过协议 getter `writer`
    /// 间接访问，永远看到最新实例。
    private var currentPool: DatabasePool

    private(set) var currentUserId: Int64?

    /// 当前 DB 文件路径（含 `starcat.sqlite` 文件名）。reopen 时更新。
    private(set) var databasePath: String?

    /// 测试可注入的根目录；生产为 `nil` 走沙盒 Application Support。
    private let basePathOverride: URL?

    /// 协议 getter：每次访问拿到当前 pool。**不可缓存**！
    var writer: any DatabaseWriter { currentPool }

    // MARK: - 初始化

    /// 生产入口：启动期 AppDependencies 调用 `init(userId: nil)`，默认 anonymous DB。
    /// 登录成功后调 `reopen(userId:)` 切到 user-specific DB。
    ///
    /// - Parameters:
    ///   - userId: GitHub User ID；`nil` 走 `users/_anonymous` 占位 DB。
    ///   - basePathOverride: 测试用。默认 nil 走沙盒 Application Support。
    init(userId: Int64?, basePathOverride: URL? = nil) throws {
        self.basePathOverride = basePathOverride

        let fileURL = try Self.databaseFileURL(userId: userId, basePathOverride: basePathOverride)
        let path = fileURL.path

        var config = Configuration()
        config.prepareDatabase { db in
            // SQLite 默认 foreign_keys = OFF，必须显式开启
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: config)
        } catch {
            throw DatabaseError.openFailed(underlying: error)
        }
        self.currentPool = pool
        self.databasePath = path
        self.currentUserId = userId

        try Self.runMigrations(on: pool)
        Self.writeUserMeta(userId: userId, basePathOverride: basePathOverride)
        AppLog.database.info("Database initialized at \(path, privacy: .public) (userId=\(userId.map(String.init) ?? "anonymous", privacy: .public))")
    }

    // MARK: - 切换账号

    /// 切到指定 GitHub User ID 的数据库。`nil` 切到 `_anonymous`。
    ///
    /// **实现策略**：先建好新 pool 再赋值，失败时仍保持旧 pool 可用。
    /// 旧 pool 的强引用被替换后，GRDB 在 in-flight 操作完成后自动 deinit。
    ///
    /// **场景约束**：仅在"先退出再登录"场景下被调用——signOut 应保证所有后台
    /// 任务已停（SyncManager / AutoTidyScheduler / Release poller 等），
    /// 因此切换瞬间通常无 in-flight 操作。即便有少量 in-flight，旧 pool
    /// 会在它们完成后自然清理，新查询全部走新 pool，互不干扰。
    ///
    /// **@MainActor**：保证 reopen 串行，避免并发 reopen 撕裂状态。
    @MainActor
    func reopen(userId: Int64?) async throws {
        if userId == currentUserId {
            AppLog.database.debug("reopen: same userId (\(userId.map(String.init) ?? "anonymous", privacy: .public)), skip")
            return
        }

        let fileURL = try Self.databaseFileURL(userId: userId, basePathOverride: basePathOverride)
        let path = fileURL.path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let newPool: DatabasePool
        do {
            newPool = try DatabasePool(path: path, configuration: config)
        } catch {
            AppLog.database.error("reopen: failed to open new pool at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw DatabaseError.openFailed(underlying: error)
        }

        try Self.runMigrations(on: newPool)

        let oldUserId = self.currentUserId
        let oldPath = self.databasePath
        self.currentPool = newPool
        self.databasePath = path
        self.currentUserId = userId

        Self.writeUserMeta(userId: userId, basePathOverride: basePathOverride)

        AppLog.database.info(
            "Database reopened: userId \(oldUserId.map(String.init) ?? "anonymous", privacy: .public) -> \(userId.map(String.init) ?? "anonymous", privacy: .public), path \(oldPath ?? "?", privacy: .public) -> \(path, privacy: .public)"
        )
    }

    // MARK: - Migration（静态以便复用）

    /// 在指定 writer 上执行所有注册的迁移。
    /// 失败时抛 `DatabaseError.migrationFailed`。
    static func runMigrations(on writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)

        do {
            try migrator.migrate(writer)
            try repairPrelaunchDevelopmentSchema(on: writer)
            let applied = try writer.read { db in
                try migrator.appliedMigrations(db)
            }
            AppLog.database.info("Migrations applied: \(applied.joined(separator: ", "), privacy: .public)")
        } catch {
            AppLog.database.error("Migration failed: \(error.localizedDescription, privacy: .public)")
            throw DatabaseError.migrationFailed(underlying: error)
        }
    }

    /// 修正未上线阶段本地开发库的 schema 形态。
    ///
    /// `repo_health_snapshots` 被并入 v1-initial 后，新库没有问题；但已经跑过 v1-initial
    /// 的本机开发库不会再次执行该迁移闭包。项目尚未上线、无线上数据，这里直接补齐当前
    /// 期望表结构，让派生缓存能被重新生成。
    private static func repairPrelaunchDevelopmentSchema(on writer: any DatabaseWriter) throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS repo_health_snapshots (
                    repo_id INTEGER PRIMARY KEY REFERENCES repos(id) ON DELETE CASCADE,
                    overall_score DOUBLE NOT NULL,
                    grade TEXT NOT NULL,
                    maintenance_score DOUBLE NOT NULL,
                    popularity_score DOUBLE NOT NULL,
                    quality_score DOUBLE NOT NULL,
                    security_score DOUBLE NOT NULL,
                    payload_json TEXT NOT NULL,
                    computed_at TEXT NOT NULL,
                    stale_after TEXT NOT NULL,
                    fetch_status TEXT NOT NULL,
                    last_error TEXT
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_repo_health_stale_after
                ON repo_health_snapshots(stale_after)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_repo_health_overall_score
                ON repo_health_snapshots(overall_score)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS smart_collections (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    icon TEXT NOT NULL DEFAULT 'line.3.horizontal.decrease.circle',
                    color TEXT,
                    rule_json TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_smart_collections_sort
                ON smart_collections(sort_order, created_at)
                """)
        }
    }

    // MARK: - 路径解析

    /// 解析当前 userId 对应的数据库文件 URL，保证父目录存在。
    ///
    /// - Parameters:
    ///   - userId: GitHub User ID；nil 走 `users/_anonymous`。
    ///   - basePathOverride: 测试可注入；nil 走沙盒 Application Support。
    /// - Returns: 形如 `<root>/users/12345/starcat.sqlite` 的完整 URL。
    static func databaseFileURL(userId: Int64?, basePathOverride: URL? = nil) throws -> URL {
        let fm = FileManager.default

        let rootDir: URL
        if let override = basePathOverride {
            // 测试路径：basePathOverride 是测试 tmpDir 根（如 `<tmp>/StarcatTest_XXX`）
            rootDir = override
        } else {
            // 沙盒下 Application Support 已是 app 私有；仍以 bundle id 建子目录，便于 Finder 观察
            guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw DatabaseError.applicationSupportNotFound
            }
            rootDir = appSupport.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
        }

        if !fm.fileExists(atPath: rootDir.path) {
            try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        }

        // `users/_anonymous` 或 `users/<id>`
        let usersDir = rootDir.appendingPathComponent(AppConstants.usersDirectoryName, isDirectory: true)
        let userDirName: String = if let userId {
            String(userId)
        } else {
            AppConstants.anonymousUserDirectoryName
        }
        let userDir = usersDir.appendingPathComponent(userDirName, isDirectory: true)
        if !fm.fileExists(atPath: userDir.path) {
            try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        }

        return userDir.appendingPathComponent(AppConstants.databaseFileName)
    }

    // MARK: - 用户元信息（诊断用）

    /// 写 `_meta.json` 到 user 目录，便于 Finder 查看时识别哪个目录属于哪个 login。
    /// 失败仅记日志（这只是诊断辅助，不影响 DB 正确性）。
    private static func writeUserMeta(userId: Int64?, basePathOverride: URL?) {
        guard let userId else { return }   // anonymous 不写

        do {
            let fm = FileManager.default

            let rootDir: URL
            if let override = basePathOverride {
                rootDir = override
            } else {
                guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    return
                }
                rootDir = appSupport.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            }
            let userDir = rootDir
                .appendingPathComponent(AppConstants.usersDirectoryName, isDirectory: true)
                .appendingPathComponent(String(userId), isDirectory: true)

            // 写 _meta.json：仅写 userId + 时间戳；login 在调用方（AppDependencies）
            // 拿不到（DatabaseManager 不依赖 AuthSession），只能后续扩展。
            // 第一版只写 user id + 最后打开时间，已经足够 Finder 排错。
            let nowISO = ISO8601DateFormatter().string(from: Date())
            let meta: [String: String] = [
                "user_id": String(userId),
                "last_at": nowISO
            ]
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            let metaURL = userDir.appendingPathComponent(AppConstants.userMetaFileName)
            try data.write(to: metaURL, options: [.atomic])
        } catch {
            AppLog.database.debug("writeUserMeta failed (non-fatal): \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - 内存实现（供单测使用）

/// 内存数据库管理器，每次实例化都是干净状态。
///
/// 用于 StarcatTests 中替代真实 DatabaseManager，不触碰沙盒文件。
///
/// **多账号 DB 隔离的内存语义**：`reopen(userId:)` 会建一个全新的空 DatabaseQueue。
/// 这与磁盘语义不同（磁盘上同一 userId 多次切回应能看到之前的数据），但内存测试
/// 的目标只是验证"切换到不同 userId 后，旧库的数据不可见"，新建空 queue 已足够。
/// 若测试需要验证"持久化"语义，应使用真磁盘 DatabaseManager + tmpDir basePathOverride。
final class InMemoryDatabaseManager: DatabaseManaging, @unchecked Sendable {

    private var currentQueue: DatabaseQueue
    private(set) var currentUserId: Int64?
    let databasePath: String? = nil

    var writer: any DatabaseWriter { currentQueue }

    init(userId: Int64? = nil) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        do {
            // DatabaseQueue 不传 path 即为内存库
            self.currentQueue = try DatabaseQueue(configuration: config)
        } catch {
            throw DatabaseError.openFailed(underlying: error)
        }
        self.currentUserId = userId

        try DatabaseManager.runMigrations(on: self.currentQueue)
    }

    @MainActor
    func reopen(userId: Int64?) async throws {
        if userId == currentUserId { return }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let newQueue: DatabaseQueue
        do {
            newQueue = try DatabaseQueue(configuration: config)
        } catch {
            throw DatabaseError.openFailed(underlying: error)
        }

        try DatabaseManager.runMigrations(on: newQueue)

        self.currentQueue = newQueue
        self.currentUserId = userId
    }
}
