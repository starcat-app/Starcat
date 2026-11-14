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

    /// 队列/轮转测试只投递符合业务准入的独立失败；阶段和成功记录另测拒绝路径。
    private static func fault(_ operation: String, count: Int = 0, timestamp: Date = Date()) -> DiagnosticEvent {
        DiagnosticEvent(timestamp: timestamp, level: .error, visibility: .issue,
            category: "test", operation: operation, message: "Feature request failed",
            summaryKey: DiagnosticIssue.generic.rawValue, phase: "finished",
            outcome: .failed, impact: .blocked, fields: ["count": .integer(count)])
    }

    @Test("新事件保留身份、类型字段和任务关联")
    func identity() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory)
        let span = DiagnosticOperation(category: "test", name: "identity", store: store)
        let event = DiagnosticContext.$current.withValue(span) {
            DiagnosticEvent(level: .info, category: "test", operation: "nested", message: "safe",
                            fields: ["count": .integer(87), "available": .boolean(false),
                                     "prompt": .string("forbidden"), "stage": .string("ready"),
                                     "arbitraryPrivateField": .integer(7), "cacheAgeSeconds": .decimal(.infinity)])
        }
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.operationID == span.id)
        #expect(decoded.sessionID != nil)
        #expect(decoded.fields["count"] == .integer(87))
        #expect(decoded.fields["available"] == .boolean(false))
        #expect(decoded.fields["prompt"] == nil)
        #expect(decoded.fields["arbitraryPrivateField"] == nil)
        #expect(decoded.fields["cacheAgeSeconds"] == nil)
        span.finish()
        _ = await store.snapshot()
    }

    @Test("快照包含截点前的并发事件，后续事件继续写入")
    func consistentSnapshot() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory, queueLimit: 5000)
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<500 {
                group.addTask {
                    store.enqueue(Self.fault("parallel", count: n))
                }
            }
        }
        let snapshot = await store.snapshot()
        store.enqueue(Self.fault("after"))
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
        await store.record(Self.fault("failure"))
        let snapshot = await store.snapshot()
        #expect(snapshot.health["writeFailures"] == 1)
        #expect(snapshot.text.isEmpty)
        #expect(await store.issueSummary().storageUnavailable)
    }

    @Test("轮转保持磁盘预算，事件仍可逐行解析")
    func rotationBudget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory, queueLimit: 5000, segmentBytes: 2048, segmentCount: 2)
        for n in 0..<100 {
            store.enqueue(Self.fault("rotate", count: n))
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

    @Test("操作终态幂等、底层错误链有界且不包含 userInfo 正文")
    func terminalAndCauses() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory)
        let root = DiagnosticOperation(category: "test", name: "root", store: store)
        let child = DiagnosticContext.$current.withValue(root) {
            DiagnosticOperation(category: "test", name: "child", store: store)
        }
        let error = NSError(domain: "fixture", code: 1, userInfo: [
            NSUnderlyingErrorKey: URLError(.timedOut), NSLocalizedDescriptionKey: "customer-private-body"
        ])
        child.finish(.failed, error: error, impact: .blocked, summary: .databaseUnavailable)
        child.finish()
        root.finish(.partial)
        let snapshot = await store.snapshot()
        let events = try snapshot.text.split(separator: "\n").map {
            try JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        let terminal = try #require(events.first)
        #expect(terminal.operationID == root.id)
        #expect(terminal.parentOperationID == nil)
        #expect(terminal.errorChain.count == 2)
        #expect(events.count == 1)
        #expect(terminal.breadcrumbs.contains { $0.operationID == child.id && $0.outcome == .failed })
        #expect(!snapshot.text.contains("customer-private-body"))
    }

    @Test("正常退出先写完已入队事件并保留未知结束的上一会话")
    func sessionBarrier() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = DiagnosticSessionRecord(sessionID: "previous",
            startedAt: "2026-11-09T00:00:00Z", lastUpdatedAt: "2026-11-09T00:01:00Z",
            lastCategory: "startup", lastOperation: "bootstrap", lastPhase: "database",
            endedNormally: false, environment: .current())
        try JSONEncoder().encode([previous]).write(to: directory.appendingPathComponent("sessions.json"))
        let store = DiagnosticLogStore(directoryURL: directory)
        for n in 0..<40 {
            store.enqueue(Self.fault("end", count: n))
        }
        store.endSession()
        let snapshot = await store.snapshot()
        let sessions = try JSONDecoder().decode([DiagnosticSessionRecord].self, from: #require(snapshot.sessions))
        #expect(snapshot.text.split(separator: "\n").count == 40)
        #expect(sessions.last?.endedNormally == true)
        #expect(sessions.first?.endedNormally == false)
        #expect(sessions.first?.lastPhase == "database")
    }

    @Test("增强复现容量、自动到期及新录制代次互不干扰")
    func reproductionLimits() async throws {
        let recording = DiagnosticRecording(byteLimit: 10, lifecycleEvents: false)
        recording.start(duration: 1)
        #expect(recording.consume(10))
        #expect(!recording.consume(1))
        #expect(recording.expiresAt == nil)
        recording.start(duration: 1)
        recording.start(duration: 3)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(recording.expiresAt != nil)
        recording.stop()
        #expect(recording.expiresAt == nil)
        let expiry = DiagnosticRecording(lifecycleEvents: false)
        expiry.start(duration: 1)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(expiry.expiresAt == nil)
        #expect(!expiry.consume(1))
    }

    @Test("不同固定原因和错误类型不会合并为同一故障")
    func aggregationReasons() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory)
        store.enqueue(DiagnosticEvent(level: .error, visibility: .issue, category: "test", operation: "same",
            message: "Failure A", summaryKey: DiagnosticIssue.databaseUnavailable.rawValue,
            underlying: "GRDB.DatabaseError code=11", outcome: .failed, impact: .blocked))
        store.enqueue(DiagnosticEvent(level: .error, visibility: .issue, category: "test", operation: "same",
            message: "Failure B", summaryKey: DiagnosticIssue.contentUnavailable.rawValue,
            underlying: "Foundation.URLError code=-1001", outcome: .failed, impact: .blocked))
        let snapshot = await store.snapshot()
        #expect(snapshot.text.split(separator: "\n").count == 2)
        #expect(!snapshot.text.contains("\"phase\":\"repeated\""))
    }

    @Test("忽略提醒后同一故障再次发生仍产生新提醒")
    func repeatedFailureAfterAcknowledgement() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory)
        let initial = Date().addingTimeInterval(-10)
        for offset in 0..<3 {
            store.enqueue(DiagnosticEvent(timestamp: initial.addingTimeInterval(Double(offset)),
                level: .error, visibility: .issue, category: "test", operation: "repeated", message: "Failure",
                summaryKey: DiagnosticIssue.generic.rawValue, outcome: .failed, impact: .blocked))
        }
        let initialSummary = await store.issueSummary()
        #expect(initialSummary.issueCount == 1)
        #expect(initialSummary.occurrenceCount == 3)
        await store.markIssuesAcknowledged()
        #expect(await store.issueSummary().issueCount == 0)
        store.enqueue(DiagnosticEvent(timestamp: Date().addingTimeInterval(1),
            level: .error, visibility: .issue, category: "test", operation: "repeated", message: "Failure",
            summaryKey: DiagnosticIssue.generic.rawValue, outcome: .failed, impact: .blocked))
        #expect(await store.issueSummary().issueCount == 1)
    }

    @Test("日志风暴保持队列上限，所有未保留事件均计入丢弃数")
    func stormBudget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticLogStore(directoryURL: directory, queueLimit: 16, segmentBytes: 8 * 1024 * 1024)
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for n in 0..<625 {
                        store.enqueue(Self.fault("storm", count: worker * 625 + n))
                    }
                }
            }
        }
        let snapshot = await store.snapshot()
        let count = snapshot.text.split(separator: "\n").count
        #expect((snapshot.health["peakQueue"] ?? 9999) <= 16)
        #expect((snapshot.health["peakQueueBytes"] ?? Int.max) <= (snapshot.health["queueBudgetBytes"] ?? 0))
        #expect(count + (snapshot.health["droppedEvents"] ?? 0) == 5000)
        #expect(snapshot.health["writeFailures"] == 0)
        print("DIAGNOSTIC_STORM input=5000 retained=\(count) health=\(snapshot.health) duration=\(started.duration(to: .now))")
    }

    @Test("队列载荷预算和读取损坏分别计数，不能静默报为空日志")
    func byteBudgetAndReadFailure() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let constrained = DiagnosticLogStore(directoryURL: directory, queueByteLimit: 1024)
        constrained.enqueue(Self.fault("oversized"))
        let dropped = await constrained.snapshot()
        #expect(dropped.health["droppedEvents"] == 1)
        #expect(dropped.text.isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xff, 0xfe, 0xff]).write(to: directory.appendingPathComponent("diagnostic-log.jsonl"))
        let unreadable = await DiagnosticLogStore(directoryURL: directory).snapshot()
        #expect(unreadable.health["readFailures"] == 1)
        #expect(unreadable.text.isEmpty)
    }

    @Test("持续写入的旧文件按事件年龄清理，保留近期故障与损坏行")
    func retentionAcrossLongLivedFile() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldDate = Date().addingTimeInterval(-30 * 86400)
        let old = DiagnosticEvent(timestamp: oldDate, level: .info, category: "test", operation: "expired", message: "safe")
        let recent = DiagnosticEvent(level: .error, category: "test", operation: "recent", message: "safe")
        let text = try [old, recent].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        let file = directory.appendingPathComponent("diagnostic-log.jsonl")
        try (text + "\ndamaged-line\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: oldDate, .modificationDate: Date()], ofItemAtPath: file.path)
        let store = DiagnosticLogStore(directoryURL: directory)
        store.enqueue(Self.fault("next"))
        let snapshot = await store.snapshot()
        #expect(!snapshot.text.contains("\"operation\":\"expired\""))
        #expect(snapshot.text.contains("\"operation\":\"recent\""))
        #expect(snapshot.text.contains("damaged-line"))
        #expect(snapshot.health["expiredEvents"] == 1)
        let data = try String(contentsOf: file, encoding: .utf8)
        #expect(!data.contains("\"operation\":\"expired\""))
    }
}
