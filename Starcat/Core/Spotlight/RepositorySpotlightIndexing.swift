//
//  RepositorySpotlightIndexing.swift
//  Starcat
//
//  Spotlight 系统索引的最小可替换边界，便于单元测试验证生命周期而不写真实系统索引。
//

/// RepositorySpotlightService 唯一依赖的系统索引能力。
protocol RepositorySpotlightIndexing: Sendable {
    func replaceAll(with entities: [RepositorySpotlightEntity]) async throws
    func upsert(_ entity: RepositorySpotlightEntity) async throws
    func remove(identifiers: [RepositorySpotlightEntity.ID]) async throws
    func removeAll() async throws
}
