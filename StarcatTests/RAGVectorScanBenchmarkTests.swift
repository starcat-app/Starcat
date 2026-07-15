//
//  RAGVectorScanBenchmarkTests.swift
//  StarcatTests
//
//  使用显式指定的真实 Starcat 数据库测量 SQLite BLOB 向量扫描基线。
//  默认禁用，只有测试宿主容器内存在显式生成的只读快照时才运行，避免普通单测
//  读取开发者数据或把机器性能差异变成 CI 门禁。
//

import Darwin
import Foundation
import GRDB
import Testing
@testable import Starcat

private let ragVectorBenchmarkDatabasePath: String? = {
    guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    let snapshot = applicationSupport
        .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
        .appendingPathComponent("rag-vector-benchmark.sqlite")
    return FileManager.default.fileExists(atPath: snapshot.path) ? snapshot.path : nil
}()

@Suite("RAGVectorScanBenchmark", .serialized)
struct RAGVectorScanBenchmarkTests {
    @Test(
        "1 万+真实分片记录向量扫描 P50/P95、内存与取消延迟",
        .disabled(if: ragVectorBenchmarkDatabasePath == nil)
    )
    func realDatabaseBaseline() async throws {
        let path = try #require(ragVectorBenchmarkDatabasePath)
        let database = try ReadOnlyRAGBenchmarkDatabase(path: path)
        let repository = GRDBRAGChunkRepository(database: database)
        let provider = SQLiteRAGVectorSearchProvider(repository: repository)
        let fixture = try await loadFixture(database: database, repository: repository)

        #expect(fixture.readyCount >= 10_000)
        #expect(fixture.dimension > 0)

        // 两轮预热排除首次打开 SQLite page cache 和测试宿主懒加载成本。
        for _ in 0..<2 {
            let hits = try await provider.search(
                queryVector: fixture.queryVector,
                model: fixture.model,
                repoIDs: fixture.repoIDs,
                limit: 20
            )
            #expect(!hits.isEmpty)
        }

        let memoryBaseline = currentPhysicalFootprintBytes()
        let peakSampler = PeakMemorySampler(initialBytes: memoryBaseline)
        let samplerTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await peakSampler.record(currentPhysicalFootprintBytes())
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        var durations: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let hits = try await provider.search(
                queryVector: fixture.queryVector,
                model: fixture.model,
                repoIDs: fixture.repoIDs,
                limit: 20
            )
            durations.append(milliseconds(from: start.duration(to: .now)))
            #expect(hits.count == 20)
        }
        samplerTask.cancel()
        _ = await samplerTask.result
        let peakBytes = await peakSampler.peakBytes

        // 取消发生在扫描中段时，Provider 最多完成当前 400 行分页就应退出。
        let cancellationTask = Task {
            try await provider.search(
                queryVector: fixture.queryVector,
                model: fixture.model,
                repoIDs: fixture.repoIDs,
                limit: 20
            )
        }
        try await Task.sleep(for: .milliseconds(2))
        let cancellationStart = ContinuousClock.now
        cancellationTask.cancel()
        _ = await cancellationTask.result
        let cancellationMilliseconds = milliseconds(from: cancellationStart.duration(to: .now))
        #expect(cancellationMilliseconds < 1_000)

        let sorted = durations.sorted()
        let result: [String: Any] = [
            "chunk_count": fixture.readyCount,
            "dimension": fixture.dimension,
            "repo_count": fixture.repoIDs.count,
            "runs": durations.count,
            "p50_ms": percentile(sorted, 0.50),
            "p95_ms": percentile(sorted, 0.95),
            "peak_memory_delta_mb": Double(max(0, peakBytes - memoryBaseline)) / 1_048_576,
            "cancel_latency_ms": cancellationMilliseconds
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("RAG_VECTOR_SCAN_BASELINE \(String(decoding: data, as: UTF8.self))")
    }

    private func loadFixture(
        database: ReadOnlyRAGBenchmarkDatabase,
        repository: GRDBRAGChunkRepository
    ) async throws -> RAGVectorBenchmarkFixture {
        let model = try await database.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT embedding_model
                FROM rag_chunks
                WHERE embedding_status = 'ready' AND embedding_model IS NOT NULL
                GROUP BY embedding_model
                ORDER BY COUNT(*) DESC
                LIMIT 1
                """)
        }
        let resolvedModel = try #require(model)
        let summary = try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS ready_count, MAX(embedding_dim) AS dimension
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status = 'ready' AND c.embedding_model = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM rag_chunk_overrides o
                      WHERE o.chunk_id = c.id AND o.is_excluded = 1
                  )
                """, arguments: [resolvedModel])
            return (
                readyCount: row?["ready_count"] as Int? ?? 0,
                dimension: row?["dimension"] as Int? ?? 0
            )
        }
        let repoIDs = try await database.writer.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT DISTINCT c.repo_id
                FROM rag_chunks c
                JOIN repo_notes n ON n.repo_id = c.repo_id AND n.library_state = 'in_library'
                WHERE c.embedding_status = 'ready' AND c.embedding_model = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM rag_chunk_overrides o
                      WHERE o.chunk_id = c.id AND o.is_excluded = 1
                  )
                ORDER BY c.repo_id
                """, arguments: [resolvedModel])
        }
        let firstEmbedding = try #require(try await repository.fetchReadyEmbeddings(
            model: resolvedModel,
            repoIDs: repoIDs,
            afterID: nil,
            limit: 1
        ).first)
        return RAGVectorBenchmarkFixture(
            model: resolvedModel,
            repoIDs: repoIDs,
            queryVector: firstEmbedding.vector,
            readyCount: summary.readyCount,
            dimension: summary.dimension
        )
    }
}

private struct RAGVectorBenchmarkFixture {
    var model: String
    var repoIDs: [Int64]
    var queryVector: [Float]
    var readyCount: Int
    var dimension: Int
}

/// 真实基线只允许查询；不会运行 migration，也不会创建 WAL 或修改用户数据库。
private final class ReadOnlyRAGBenchmarkDatabase: DatabaseManaging, @unchecked Sendable {
    let databasePath: String?
    let currentUserId: Int64? = nil
    private let queue: DatabaseQueue
    var writer: any DatabaseWriter { queue }

    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        queue = try DatabaseQueue(path: path, configuration: configuration)
        databasePath = path
    }

    @MainActor
    func reopen(userId: Int64?) async throws {
        preconditionFailure("只读性能基线不支持切换数据库")
    }
}

private actor PeakMemorySampler {
    private(set) var peakBytes: Int64

    init(initialBytes: Int64) {
        peakBytes = initialBytes
    }

    func record(_ bytes: Int64) {
        peakBytes = max(peakBytes, bytes)
    }
}

private func currentPhysicalFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

private func milliseconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int(ceil(Double(sorted.count) * quantile)) - 1
    return sorted[min(max(index, 0), sorted.count - 1)]
}
