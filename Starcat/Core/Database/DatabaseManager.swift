//
//  DatabaseManager.swift
//  Starcat
//
//  GRDB 数据库门面。
//
//  设计要点：
//  - 持有 `any DatabaseWriter`，不锁死 DatabasePool 或 DatabaseQueue
//    生产环境：DatabasePool（文件 + WAL，多读单写）
//    测试环境：DatabaseQueue（内存）
//  - 启动期跑 Migration；失败直接 throw，由 App 启动流程决定崩溃或提示
//  - 通过 DatabaseManaging 协议依赖，测试可注入 InMemoryDatabaseManager
//
//  线程模型：DatabaseWriter 自身线程安全
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
            return "无法定位 Application Support 目录"
        case .migrationFailed(let error):
            return "数据库迁移失败：\(error.localizedDescription)"
        case .openFailed(let error):
            return "数据库打开失败：\(error.localizedDescription)"
        }
    }
}

/// 数据库门面协议，业务层通过此协议依赖数据库。
///
/// 同时支持文件库（生产）与内存库（测试），二者实现该协议。
protocol DatabaseManaging: Sendable {
    /// 文件路径；内存库返回 nil。
    var databasePath: String? { get }

    /// GRDB writer，封装了对应的 Pool 或 Queue。
    var writer: any DatabaseWriter { get }
}

/// 生产环境数据库管理器。
///
/// 单例，落地到沙盒 `Application Support/com.starcat.app/starcat.sqlite`。
final class DatabaseManager: DatabaseManaging, @unchecked Sendable {

    // MARK: - 单例

    /// 单例 lazy 初始化。
    /// 失败时 fatalError——数据库是核心数据载体，启动失败应当显式崩溃而非静默继续。
    /// 真实生产可替换为显式的 try? + 用户提示流程，MVP 阶段保持简单。
    static let shared: DatabaseManager = {
        do {
            return try DatabaseManager()
        } catch {
            fatalError("Failed to initialize DatabaseManager: \(error)")
        }
    }()

    // MARK: - 属性

    let writer: any DatabaseWriter
    let databasePath: String?

    // MARK: - 初始化

    private init() throws {
        let fileURL = try Self.databaseFileURL()
        let path = fileURL.path
        self.databasePath = path

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
        self.writer = pool

        try Self.runMigrations(on: pool)
        AppLog.database.info("Database initialized at \(path, privacy: .public)")
    }

    // MARK: - Migration（静态以便复用）

    /// 在指定 writer 上执行所有注册的迁移。
    /// 失败时抛 `DatabaseError.migrationFailed`。
    static func runMigrations(on writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        DatabaseMigrations.registerAll(into: &migrator)

        do {
            try migrator.migrate(writer)
            let applied = try writer.read { db in
                try migrator.appliedMigrations(db)
            }
            AppLog.database.info("Migrations applied: \(applied.joined(separator: ", "), privacy: .public)")
        } catch {
            AppLog.database.error("Migration failed: \(error.localizedDescription, privacy: .public)")
            throw DatabaseError.migrationFailed(underlying: error)
        }
    }

    // MARK: - 路径解析

    /// 解析沙盒 Application Support 下的数据库文件 URL，并保证父目录存在。
    static func databaseFileURL() throws -> URL {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DatabaseError.applicationSupportNotFound
        }

        // 沙盒下 Application Support 已是 app 私有；仍以 bundle id 建子目录，便于 Finder 观察
        let bundleDir = appSupport.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
        if !fm.fileExists(atPath: bundleDir.path) {
            try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        }
        return bundleDir.appendingPathComponent(AppConstants.databaseFileName)
    }

    // MARK: - 启动入口

    /// 显式触发单例初始化（含 Migration），用于 App 启动阶段。
    static func bootstrap() {
        _ = DatabaseManager.shared
    }
}

// MARK: - 内存实现（供单测使用）

/// 内存数据库管理器，每次实例化都是干净状态。
///
/// 用于 StarcatTests 中替代真实 DatabaseManager，不触碰沙盒文件。
final class InMemoryDatabaseManager: DatabaseManaging, @unchecked Sendable {

    let writer: any DatabaseWriter
    let databasePath: String? = nil

    init() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        do {
            // DatabaseQueue 不传 path 即为内存库
            self.writer = try DatabaseQueue(configuration: config)
        } catch {
            throw DatabaseError.openFailed(underlying: error)
        }

        try DatabaseManager.runMigrations(on: self.writer)
    }
}
