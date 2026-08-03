//
//  FocusWidgetConfigurationIntent.swift
//  Starcat
//
//  Focus Widget 的 AppIntent 配置与动态仓库实体。
//
//  本文件必须同时进入宿主 App 和 Widget Extension target。macOS 的 chronod 会从
//  宿主 bundle 解析 WidgetConfigurationIntent 元数据；如果只编译进 Extension，
//  StaticConfiguration Widget 仍可运行，但 AppIntentConfiguration 会因找不到默认
//  Intent 以 CHSErrorDomain 1103 失败。
//

import AppIntents
import Foundation

/// Focus Widget 的用户配置；仓库为空时按快照原顺序展示默认关注列表。
struct FocusWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.focus.configuration.title"
    static let description = IntentDescription("widget.focus.configuration.description")

    @Parameter(title: "widget.focus.configuration.repository")
    var repository: WidgetRepositoryEntity?

    init() {}
}

/// 暴露给 AppIntents 配置界面的最小仓库实体，不携带笔记、凭据或数据库路径。
struct WidgetRepositoryEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "widget.focus.entity.type"
    )
    static let defaultQuery = WidgetRepositoryEntityQuery()

    let id: String
    let repositoryID: Int64
    let owner: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(owner)/\(name)")
    }
}

/// 从 App Group 快照提供 Focus Widget 配置界面的动态仓库候选项。
struct WidgetRepositoryEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetRepositoryEntity] {
        let identifierSet = Set(identifiers)
        return Self.availableEntities().filter { identifierSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetRepositoryEntity] {
        Self.availableEntities()
    }

    /// 保留快照顺序并按 GitHub repository ID 去重；该纯映射也是单元测试入口。
    static func entities(from repositories: [WidgetRepository]) -> [WidgetRepositoryEntity] {
        var seen = Set<Int64>()
        return repositories.compactMap { repository in
            guard seen.insert(repository.id).inserted else { return nil }
            return WidgetRepositoryEntity(
                id: String(repository.id),
                repositoryID: repository.id,
                owner: repository.owner,
                name: repository.name
            )
        }
    }

    private static func availableEntities() -> [WidgetRepositoryEntity] {
        do {
            let groupIdentifier = try WidgetSharedConfiguration.appGroupIdentifier()
            let containerURL = try WidgetSharedConfiguration.containerURL(
                groupIdentifier: groupIdentifier
            )
            let snapshot = try WidgetSnapshotStore(containerURL: containerURL).load()
            guard snapshot.accountState == .ready else { return [] }
            return entities(from: snapshot.focusRepositories)
        } catch {
            // 配置候选项允许暂时为空；系统稍后会再次查询，不能因快照尚未生成而让
            // WidgetConfigurationIntent 元数据解析失败。
            return []
        }
    }
}
