//
//  Logger.swift
//  Starcat
//
//  基于 Apple OSLog 的薄封装。
//
//  设计目标：
//  - 统一 subsystem (com.starcat.app)，按 category 拆分（database / network / sync / auth / ai / ui / keychain）
//  - 用 Swift 5.5+ 的 os.Logger 而不是旧的 OSLog/os_log 宏，享受 string interpolation 隐私级别控制
//  - 不引入第三方日志库（见开发前问题清单 5.8）
//
//  使用：
//      AppLog.database.info("Database initialized at \(path, privacy: .public)")
//      AppLog.network.error("Request failed: \(error.localizedDescription, privacy: .public)")
//
//  注意：
//  - 默认 privacy 为 .auto，对包含用户数据的字符串会被 Console.app 打码
//  - 显式 .public 仅用于不含 PII 的字符串（路径、状态码、版本号等）
//

import Foundation
import os

/// 应用日志门面，按 category 切分。
///
/// 不暴露 OSLog 实例，避免业务层直接持有；所有写入走 `AppLog.<category>.<level>(...)`。
enum AppLog {

    /// 数据库相关：Migration、CRUD 异常、FTS 重建等。
    static let database = Logger(subsystem: AppConstants.logSubsystem, category: "database")

    /// 网络层：URLSession 请求/响应、HTTP 错误、Rate Limit。
    static let network = Logger(subsystem: AppConstants.logSubsystem, category: "network")

    /// 同步管理：SyncManager 进度、断点续传。
    static let sync = Logger(subsystem: AppConstants.logSubsystem, category: "sync")

    /// 认证：OAuth 流程、Token 失效。
    static let auth = Logger(subsystem: AppConstants.logSubsystem, category: "auth")

    /// AI 服务：摘要、标签推荐、语义搜索（P1+）。
    static let ai = Logger(subsystem: AppConstants.logSubsystem, category: "ai")

    /// UI 行为：用户操作、导航、视图生命周期（按需）。
    static let ui = Logger(subsystem: AppConstants.logSubsystem, category: "ui")

    /// Keychain 操作：存取、自检。
    static let keychain = Logger(subsystem: AppConstants.logSubsystem, category: "keychain")

    /// 兜底日志：未分类的、临时调试。
    static let general = Logger(subsystem: AppConstants.logSubsystem, category: "general")
}
