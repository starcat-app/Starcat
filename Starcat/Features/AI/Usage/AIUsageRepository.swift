//
//  AIUsageRepository.swift
//  Starcat
//
//  AI 用量事件的 GRDB 写入与基础读取入口。
//

import Foundation
import GRDB

protocol AIUsageRepositoryProtocol: Sendable {
    func insert(_ event: AIUsageEvent) async throws
    func fetchRecent(limit: Int) async throws -> [AIUsageEvent]
}

/// 仓储每次通过 `database.writer` getter 访问当前账号数据库，账号切换后不会写回旧用户库。
struct GRDBAIUsageRepository: AIUsageRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func insert(_ event: AIUsageEvent) async throws {
        try await database.writer.write { db in
            try event.insert(db)
        }
    }

    func fetchRecent(limit: Int) async throws -> [AIUsageEvent] {
        guard limit > 0 else { return [] }
        return try await database.writer.read { db in
            try AIUsageEvent
                .order(Column("completed_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}
