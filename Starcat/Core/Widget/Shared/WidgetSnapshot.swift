//
//  WidgetSnapshot.swift
//  Starcat
//
//  App 与 Widget Extension 共用的版本化只读数据契约。
//  本文件只依赖 Foundation，避免 Extension 被迫链接 GRDB、网络或 Keychain。
//

import Foundation

/// Widget 当前可展示的账户状态。
///
/// 非 `ready` 状态必须使用空业务数据，防止登出、切换用户或构建失败时继续展示
/// 上一位用户的仓库和 Release。
enum WidgetAccountState: String, Codable, Equatable, Sendable {
    case preparing
    case ready
    case signedOut
    case unavailable
}

/// Widget 所需的最小仓库投影。
///
/// 不包含私有笔记、凭据、RAG 内容或数据库路径。`avatarFileName` 只能是 App Group
/// 头像目录中的相对文件名，不能保存主应用私有容器的绝对路径。
struct WidgetRepository: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let owner: String
    let name: String
    let description: String?
    let language: String?
    let starsCount: Int
    let tags: [String]
    let status: String?
    let avatarFileName: String?
    let openURL: URL
}

/// Widget 所需的最小未读 Release 投影。
///
/// Release body 和 assets 不进入共享快照，既降低文件体积，也避免桌面摘要持有
/// 不必要的长文本。
struct WidgetRelease: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let repositoryID: Int64
    let owner: String
    let repositoryName: String
    let tagName: String
    let displayName: String?
    let publishedAt: Date?
    let isPrerelease: Bool
    let avatarFileName: String?
    let openURL: URL
}

/// App Group 中 `widget-snapshot-v1.json` 的顶层契约。
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let accountState: WidgetAccountState
    let focusRepositories: [WidgetRepository]
    let rediscoveryRepository: WidgetRepository?
    let unreadReleaseCount: Int
    let unreadReleases: [WidgetRelease]

    /// 构造快照时集中执行账户隔离不变量。
    ///
    /// 即使调用方错误地给 `.signedOut` / `.preparing` 传入旧业务数据，这里也会
    /// 强制清空，避免某个新触发点漏做清理后把上一账号内容重新写回桌面。
    init(
        schemaVersion: Int = currentSchemaVersion,
        generatedAt: Date = Date(),
        accountState: WidgetAccountState,
        focusRepositories: [WidgetRepository] = [],
        rediscoveryRepository: WidgetRepository? = nil,
        unreadReleaseCount: Int = 0,
        unreadReleases: [WidgetRelease] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accountState = accountState

        if accountState == .ready {
            self.focusRepositories = Array(focusRepositories.prefix(6))
            self.rediscoveryRepository = rediscoveryRepository
            self.unreadReleaseCount = max(0, unreadReleaseCount)
            self.unreadReleases = Array(unreadReleases.prefix(6))
        } else {
            self.focusRepositories = []
            self.rediscoveryRepository = nil
            self.unreadReleaseCount = 0
            self.unreadReleases = []
        }
    }

    /// 登出、切库和故障路径统一使用本工厂，避免各调用方手写空数组。
    static func empty(state: WidgetAccountState, generatedAt: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: generatedAt, accountState: state)
    }
}
