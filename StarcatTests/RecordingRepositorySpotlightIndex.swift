//
//  RecordingRepositorySpotlightIndex.swift
//  StarcatTests
//
//  Spotlight 生命周期测试使用的 actor spy；它只记录调用，不接触系统索引。
//

@testable import Starcat

/// 记录 RepositorySpotlightIndexing 调用的并发安全测试替身。
actor RecordingRepositorySpotlightIndex: RepositorySpotlightIndexing {
    private(set) var replacement: [RepositorySpotlightEntity] = []
    private(set) var replacementCallCount = 0
    private(set) var upserted: [RepositorySpotlightEntity] = []
    private(set) var removedIdentifiers: [RepositorySpotlightEntity.ID] = []
    private(set) var removeAllCallCount = 0

    func replaceAll(with entities: [RepositorySpotlightEntity]) async throws {
        replacementCallCount += 1
        replacement = entities
    }

    func upsert(_ entity: RepositorySpotlightEntity) async throws {
        upserted.append(entity)
    }

    func remove(identifiers: [RepositorySpotlightEntity.ID]) async throws {
        removedIdentifiers.append(contentsOf: identifiers)
    }

    func removeAll() async throws {
        removeAllCallCount += 1
        replacement = []
    }
}
