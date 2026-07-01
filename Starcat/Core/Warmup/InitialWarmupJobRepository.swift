//
//  InitialWarmupJobRepository.swift
//  Starcat
//
//  首次 README / Repo Health 预热作业 Repository。
//
//  模块级说明：
//  - 只负责 `initial_warmup_jobs` 的读写，不执行网络请求；
//  - 每次查询都通过 `DatabaseManaging.writer` 获取当前 DB，避免账号切换后写到旧库；
//  - 作业状态按 GitHub user_id 隔离，切账号不会复用另一位用户的预热进度。
//

import Foundation
import GRDB

struct InitialWarmupJobRepository: Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func job(userId: Int64) async throws -> InitialWarmupJobRecord? {
        try await database.writer.read { db in
            try InitialWarmupJobRecord.fetchOne(db, key: userId)
        }
    }

    func upsert(_ record: InitialWarmupJobRecord) async throws {
        try await database.writer.write { db in
            var copy = record
            try copy.save(db)
        }
    }
}
