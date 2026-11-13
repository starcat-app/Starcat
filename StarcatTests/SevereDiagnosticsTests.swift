//
//  SevereDiagnosticsTests.swift
//  StarcatTests
//
//  严重故障准入、操作内存生命周期与旧证据的回归契约。
//  仅使用临时存储和合成错误，不触发网络、真实数据库或系统授权。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Severe diagnostic admission")
struct SevereDiagnosticsTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("severe-diagnostics-\(UUID())")
    }

    /// 每个维度必须同时成立，不能由 HTTP 500、error 等单一信号代替业务判断。
    @Test("准入矩阵同时验证格式、可见性、终态、影响与摘要")
    func admissionMatrix() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        let expected = DiagnosticEvent(level: .error, visibility: .issue, category: "test",
            operation: "final", message: "Final feature failure",
            summaryKey: DiagnosticIssue.generic.rawValue, statusCode: 500,
            outcome: .failed, impact: .blocked)
        var rejected: [DiagnosticEvent] = []
        for level in [DiagnosticEvent.Level.debug, .info, .warning] {
            var event = expected; event.level = level; rejected.append(event)
        }
        for outcome in [DiagnosticEvent.Outcome.succeeded, .cancelled, .skipped] {
            var event = expected; event.outcome = outcome; rejected.append(event)
        }
        for impact in [DiagnosticEvent.Impact.none, .degraded] {
            var event = expected; event.impact = impact; rejected.append(event)
        }
        var context = expected; context.visibility = .context; rejected.append(context)
        var legacy = expected; legacy.schemaVersion = 2; rejected.append(legacy)
        var unspecified = expected; unspecified.summaryKey = nil; rejected.append(unspecified)
        rejected.forEach(store.enqueue)
        #expect(await store.readAllText().isEmpty)
        store.enqueue(expected)
        var partial = expected
        partial.operation = "partialSave"
        partial.outcome = .partial
        partial.impact = .dataRisk
        store.enqueue(partial)
        let summary = await store.issueSummary()
        #expect(summary.issueCount == 2)
        #expect(summary.occurrenceCount == 2)
    }

    @Test("子操作严重失败后父操作成功回退不落盘")
    func successfulFallbackDiscardsChild() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        let parent = DiagnosticOperation(category: "test", name: "resolve", store: store)
        DiagnosticContext.$current.withValue(parent) {
            let candidate = DiagnosticOperation(category: "runtime", name: "candidate", store: store)
            candidate.finish(.failed, error: URLError(.timedOut),
                impact: .blocked, summary: .runtimeUnavailable)
        }
        parent.event(phase: "fallbackAvailable", outcome: .succeeded)
        parent.finish()
        #expect(await store.readAllText().isEmpty)
    }

    @Test("最终失败保留最近16条阶段并说明截断，取消仍全部丢弃")
    func boundedStagesAndCancellation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        let operation = DiagnosticOperation(category: "test", name: "failed", store: store)
        for count in 0..<24 {
            operation.event(phase: "attempt", fields: ["attempt": .integer(count)])
        }
        operation.finish(.partial, impact: .dataRisk, summary: .dataSaveFailed)
        operation.finish(.failed, impact: .blocked, summary: .generic)
        let text = await store.readAllText()
        let events = try text.split(separator: "\n").map {
            try JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8))
        }
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.breadcrumbs.count == 16)
        #expect(event.breadcrumbsTruncated)
        #expect(event.breadcrumbs.first?.fields["attempt"] == .integer(9))
        #expect(event.outcome == .partial)
        let cancelled = DiagnosticOperation(category: "test", name: "cancelled", store: store)
        cancelled.finish(.failed, error: URLError(.cancelled), impact: .blocked, summary: .generic)
        #expect(await store.readAllText() == text)
    }

    @Test("错误映射默认不写入，配置与取消不能被外层影响标记误收录")
    func presentationIsSeparate() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        let errors: [Error] = [AIChatSelectionError.missingProvider, LocalAIError.modelNotInstalled("fixture"),
                               CancellationError(), NetworkError.unauthorized,
                               ExternalAgentRuntimeError.executableNotFound("optional"),
                               ExternalAgentRuntimeError.missingConfiguration("fixture"),
                               AgentRunSessionError.iterationLimit(3),
                               LoopAgentRuntimeError.approvalRequired("fixture")]
        for error in errors {
            let friendly = UserFacingError.map(error, operation: "request", impact: .blocked, summary: .aiUnavailable)
            friendly.record(category: "test", operation: "request", store: store)
        }
        UserFacingError.map(DatabaseError.applicationSupportNotFound, operation: "open")
            .record(category: "database", operation: "open", store: store)
        #expect(await store.readAllText().isEmpty)
        UserFacingError.map(DatabaseError.applicationSupportNotFound, operation: "open",
                            impact: .blocked, summary: .databaseUnavailable)
            .record(category: "database", operation: "open", store: store)
        #expect(await store.issueSummary().issueCount == 1)
    }

    @Test("HTTP分类本身不准入，业务确认最终阻断后仍可记录", arguments: [
        NetworkError.rateLimited(retryAfter: 1), .notFound
    ])
    func finalHTTPFailureRequiresBusinessImpact(error: NetworkError) {
        #expect(!UserFacingError.map(error, operation: "request").shouldRecordDiagnostic)
        #expect(UserFacingError.map(error, operation: "request",
                    impact: .blocked, summary: .contentUnavailable).shouldRecordDiagnostic)
    }

    @Test("启动操作结束后继承的TaskLocal不吞掉新后台故障")
    func completedStartupDoesNotOwnLaterRequests() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        let startup = DiagnosticOperation(category: "startup", name: "bootstrap", store: store)
        startup.finish()
        DiagnosticContext.$current.withValue(startup) {
            let background = DiagnosticOperation(category: "sync", name: "stars", store: store)
            #expect(background.parentID == nil)
            background.finish(.failed, error: URLError(.cannotConnectToHost),
                              impact: .blocked, summary: .syncFailed)
        }
        let summary = await store.issueSummary()
        #expect(summary.issueCount == 1)
        #expect(summary.latestIssue?.summaryKey == DiagnosticIssue.syncFailed.rawValue)
    }

    @Test("业务影响候选保留根收尾错误链与最终回退状态")
    func terminalEvidenceMergesIntoCandidate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        let operation = DiagnosticOperation(category: "runtime", name: "resolve", store: store)
        operation.capture(DiagnosticEvent(level: .error, visibility: .issue, category: "runtime",
            operation: "resolve", message: "Required runtime failed",
            summaryKey: DiagnosticIssue.runtimeUnavailable.rawValue, outcome: .failed, impact: .blocked))
        operation.finish(.failed, error: URLError(.cannotOpenFile),
                         fields: ["attempt": .integer(2), "outputAvailable": .boolean(false)])
        let latest = try #require(await store.issueSummary().latestIssue)
        #expect(latest.fields["attempt"] == .integer(2))
        #expect(latest.errorChain.count == 1)
        #expect(latest.errorChain.first?.code == URLError.cannotOpenFile.rawValue)
        #expect(latest.underlying != nil)
    }

    @Test("确认标记及会话损坏均显示记录不可用，保留原文件")
    func damagedMetadataIsNotEmptyHealth() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = root.appendingPathComponent("sessions.json")
        try Data("broken-session".utf8).write(to: sessions)
        try Data("broken-marker".utf8).write(to: root.appendingPathComponent("diagnostic-log-acknowledged-at.txt"))
        let store = DiagnosticLogStore(directoryURL: root)
        store.startSession()
        let summary = await store.issueSummary()
        #expect(summary.issueCount == 0)
        #expect(summary.storageUnavailable)
        #expect(try String(contentsOf: sessions, encoding: .utf8) == "broken-session")
        #expect(await store.readAllText().isEmpty)
    }

    @Test("历史issue保留导出但不触发新提醒，损坏行不能伪装无故障")
    func historicalAndDamagedEvidence() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var legacy = DiagnosticEvent(level: .error, visibility: .issue, category: "database",
            operation: "legacy", message: "Historical failure", outcome: .failed, impact: .blocked)
        legacy.schemaVersion = 2
        let text = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        try (text + "\ndamaged\n").write(to: root.appendingPathComponent("diagnostic-log.jsonl"),
                                        atomically: true, encoding: .utf8)
        let store = DiagnosticLogStore(directoryURL: root)
        let summary = await store.issueSummary()
        #expect(summary.issueCount == 0)
        #expect(summary.storageUnavailable)
        #expect(await store.readAllText().contains("Historical failure"))
        #expect(DiagnosticIssue.summaryKey(for: "unknown-key") == DiagnosticIssue.generic.rawValue)
    }

    @Test("新写入缺摘要被拒绝，已落盘v3故障缺失或未知摘要时仍显示通用提醒")
    func missingStoredSummaryDoesNotHideSevereFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticLogStore(directoryURL: root)
        var missing = DiagnosticEvent(level: .error, visibility: .issue, category: "database",
            operation: "open", message: "Technical details stay out of the panel",
            outcome: .failed, impact: .blocked)
        store.enqueue(missing)
        #expect(await store.readAllText().isEmpty)
        var unknown = missing
        unknown.summaryKey = "diagnostics.issue.futureFailure"
        missing.summaryKey = nil
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = try [missing, unknown].map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        try text.write(to: root.appendingPathComponent("diagnostic-log.jsonl"), atomically: true, encoding: .utf8)
        let summary = await store.issueSummary()
        #expect(summary.issueCount == 1)
        #expect(summary.occurrenceCount == 2)
        #expect(DiagnosticIssue.summaryKey(for: summary.latestIssue?.summaryKey) == DiagnosticIssue.generic.rawValue)
    }
}
