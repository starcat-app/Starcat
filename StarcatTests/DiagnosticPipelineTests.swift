//
//  DiagnosticPipelineTests.swift
//  StarcatTests
//
//  验证事件关联、快照截点、有界队列、轮转和故障健康记录，不依赖业务库或 Keychain。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Diagnostic pipeline")
struct DiagnosticPipelineTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-\(UUID())")
    }

    @Test("新事件保留身份、类型字段和任务关联")
    func identity() async throws {
        let span = DiagnosticOperation(category: "test", name: "identity")
        let event = DiagnosticContext.$current.withValue(span) {
            DiagnosticEvent(level: .info, category: "test", operation: "nested", message: "safe",
                            fields: ["count": .integer(87), "available": .boolean(false),
                                     "prompt": .string("forbidden"), "stage": .string("ready")])
        }
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.operationID == span.id)
        #expect(decoded.sessionID != nil)
        #expect(decoded.fields["count"] == .integer(87))
        #expect(decoded.fields["available"] == .boolean(false))
        #expect(decoded.fields["prompt"] == nil)
        span.finish()
    }

    @Test("快照包含截点前的并发事件，后续事件继续写入")
    func consistentSnapshot() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory, queueLimit: 5000)
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<500 {
                group.addTask {
                    store.enqueue(DiagnosticEvent(level: .info, category: "test", operation: "parallel",
                        message: "safe", phase: "progress", fields: ["count": .integer(n)]))
                }
            }
        }
        let snapshot = await store.snapshot()
        store.enqueue(DiagnosticEvent(level: .info, category: "test", operation: "after", message: "safe"))
        let events = snapshot.text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        #expect(events.count == 500)
        #expect(Set(events.compactMap(\.sequence)).count == 500)
        #expect(events.allSatisfy { ($0.sequence ?? .max) <= snapshot.cutoffSequence })
        #expect(!snapshot.text.contains("\"operation\":\"after\""))
        #expect(await store.readAllText().contains("\"operation\":\"after\""))
    }

    @Test("磁盘不可写明确报告健康失败，不递归新增事件")
    func writeFailure() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("file".utf8).write(to: directory)
        let store = DiagnosticLogStore(directoryURL: directory)
        await store.record(DiagnosticEvent(level: .error, category: "test", operation: "failure", message: "safe"))
        let snapshot = await store.snapshot()
        #expect(snapshot.health["writeFailures"] == 1)
        #expect(snapshot.text.isEmpty)
    }

    @Test("轮转保持磁盘预算，事件仍可逐行解析")
    func rotationBudget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory, queueLimit: 5000, segmentBytes: 2048, segmentCount: 2)
        for n in 0..<100 {
            store.enqueue(DiagnosticEvent(level: .info, category: "test", operation: "rotate",
                message: "safe", phase: "progress", fields: ["count": .integer(n)]))
        }
        let snapshot = await store.snapshot()
        let files = await store.exportableFiles()
        #expect(files.count <= 3)
        let bytes = try files.reduce(0) { sum, url in
            sum + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0)
        }
        #expect(bytes <= 6144)
        #expect(snapshot.text.split(separator: "\n").allSatisfy {
            (try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8))) != nil
        })
    }

    @Test("取消不产生故障提醒，未知和可恢复错误仍有采集入口")
    func classification() {
        let cancelled = UserFacingError.map(CancellationError(), operation: "reload")
        #expect(cancelled.diagnosticOutcome == .cancelled)
        #expect(!cancelled.shouldRecordDiagnostic)
        #expect(DiagnosticFailure.isCancellation(URLError(.cancelled)))
        #expect(!DiagnosticFailure.isCancellation(URLError(.timedOut)))
    }
}
