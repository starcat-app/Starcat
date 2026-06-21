//
//  SmartCollectionRepository.swift
//  Starcat
//
//  用户自定义智能集合 GRDB Repository。
//

import Foundation
import GRDB

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
        try await database.writer.read { db in
            try UserSmartCollection.fetchCount(db)
        }
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
            _ = try UserSmartCollection.deleteOne(db, key: id)
        }
    }
}
