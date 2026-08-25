//
//  RepositorySpotlightEntityQuery.swift
//  Starcat
//
//  App Intents 在恢复持久化 Spotlight 实体时使用的查询入口。
//

import AppIntents

/// 按 GitHub repository ID 从当前用户数据库恢复实体。
///
/// 查询不提供全量 suggestions，避免 Shortcuts 或其它系统界面无请求地枚举全部私人
/// 仓库和笔记；Spotlight 自身只消费已经由用户开关授权并捐赠的实体。
struct RepositorySpotlightEntityQuery: EntityQuery {
    @Dependency private var spotlightService: RepositorySpotlightService

    func entities(for identifiers: [RepositorySpotlightEntity.ID]) async throws -> [RepositorySpotlightEntity] {
        await spotlightService.entities(for: identifiers)
    }

    func suggestedEntities() async throws -> [RepositorySpotlightEntity] {
        []
    }
}
