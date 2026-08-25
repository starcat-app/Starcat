//
//  CoreSpotlightRepositoryIndex.swift
//  Starcat
//
//  RepositorySpotlightIndexing 的 Core Spotlight 生产实现。
//

import Foundation

/// 串行拥有自定义 CSSearchableIndex，避免并发任务同时修改同一个具名索引。
///
/// Apple 明确要求 custom index 只能由一个线程或 task 修改。actor 在这里不是为了并行，
/// 而是把删除、批量写入和单项更新收敛成严格顺序；否则同步完成、笔记保存与设置切换
/// 可能交错，留下已关闭功能仍可搜索的条目。
actor CoreSpotlightRepositoryIndex: RepositorySpotlightIndexing {
    static let indexName = "StarcatRepositories"
    private static let batchSize = 500

    private let client: CoreSpotlightIndexClient
    private var latestOperation: Task<Void, any Error>?

    init() {
        // `.complete` 让支持该 protection class 的系统在设备锁定时保护索引内容；
        // Spotlight 仍由 macOS 管理展示，Starcat 不把它描述为应用级端到端加密。
        self.client = CoreSpotlightIndexClient(name: Self.indexName)
    }

    func replaceAll(with entities: [RepositorySpotlightEntity]) async throws {
        try await enqueue { client in
            try await client.deleteAll()
            for start in stride(from: 0, to: entities.count, by: Self.batchSize) {
                let end = min(start + Self.batchSize, entities.count)
                try Task.checkCancellation()
                try await client.index(Array(entities[start..<end]))
            }
        }
    }

    func upsert(_ entity: RepositorySpotlightEntity) async throws {
        try await enqueue { client in
            try await client.index([entity])
        }
    }

    func remove(identifiers: [RepositorySpotlightEntity.ID]) async throws {
        guard !identifiers.isEmpty else { return }
        try await enqueue { client in
            try await client.delete(identifiers: identifiers)
        }
    }

    func removeAll() async throws {
        try await enqueue { client in
            try await client.deleteAll()
        }
    }

    /// actor 会在 await 时重入，因此仅把 CSSearchableIndex 放进 actor 仍可能重叠调用。
    /// 显式任务链让每个操作等待上一个操作真正完成；前一个失败不阻断后续清理请求。
    private func enqueue(
        _ operation: @escaping @Sendable (CoreSpotlightIndexClient) async throws -> Void
    ) async throws {
        let previous = latestOperation
        let client = self.client
        let task = Task {
            if let previous {
                _ = try? await previous.value
            }
            try Task.checkCancellation()
            try await operation(client)
        }
        latestOperation = task
        try await task.value
    }
}
