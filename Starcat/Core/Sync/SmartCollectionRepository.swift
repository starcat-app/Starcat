//
//  SmartCollectionRepository.swift
//  Starcat
//
//  用户自定义智能集合 GRDB Repository。
//

import Foundation
import GRDB

/// 用户自定义智能集合持久化错误。
enum SmartCollectionRepositoryError: Error, LocalizedError, Equatable {
    case notFound(id: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return String(format: String.l10n("smartCollections.error.notFoundFormat"), id)
        }
    }
}

struct GRDBSmartCollectionRepository: SmartCollectionRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func fetchAll() async throws -> [UserSmartCollection] {
        try await database.writer.read { db in
            try UserSmartCollection
                .order(Column("sort_order").asc, Column("created_at").asc)
                .fetchAll(db)
        }
    }

    func find(id: String) async throws -> UserSmartCollection? {
        try await database.writer.read { db in
            try UserSmartCollection.fetchOne(db, key: id)
        }
    }

    func count() async throws -> Int {
        // 与 UI 列表共用 fetchAll 结果计数，避免 fetchCount 与可见集合不一致时
        // 免费版门控误拦（用户已删光卡片但仍被算进限额）。
        try await fetchAll().count
    }

    func create(_ collection: UserSmartCollection) async throws {
        try await database.writer.write { db in
            var copy = collection
            try copy.insert(db)
        }
    }

    func update(_ collection: UserSmartCollection) async throws {
        try await database.writer.write { db in
            try collection.update(db)
        }
    }

    func delete(id: String) async throws {
        try await database.writer.write { db in
            guard try UserSmartCollection.deleteOne(db, key: id) else {
                throw SmartCollectionRepositoryError.notFound(id: id)
            }
        }
    }
}
