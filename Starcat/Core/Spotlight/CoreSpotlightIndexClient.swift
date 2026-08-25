//
//  CoreSpotlightIndexClient.swift
//  Starcat
//
//  CSSearchableIndex 的 Swift 6 Sendable 桥接层。
//

import AppIntents
import CoreSpotlight
import Foundation

/// 封装 Apple 尚未标注 Sendable 的 CSSearchableIndex。
///
/// `@unchecked Sendable` 的安全前提不是假设系统类型天然线程安全，而是所有调用都只能由
/// `CoreSpotlightRepositoryIndex` 的串行任务链发起。不要把 `rawIndex` 暴露给其它调用方。
final class CoreSpotlightIndexClient: @unchecked Sendable {
    private let rawIndex: CSSearchableIndex

    init(name: String) {
        self.rawIndex = CSSearchableIndex(name: name, protectionClass: .complete)
    }

    func deleteAll() async throws {
        try await rawIndex.deleteAppEntities(ofType: RepositorySpotlightEntity.self)
    }

    func index(_ entities: [RepositorySpotlightEntity]) async throws {
        try await rawIndex.indexAppEntities(entities)
    }

    func delete(identifiers: [RepositorySpotlightEntity.ID]) async throws {
        try await rawIndex.deleteAppEntities(
            identifiedBy: identifiers,
            ofType: RepositorySpotlightEntity.self
        )
    }
}
