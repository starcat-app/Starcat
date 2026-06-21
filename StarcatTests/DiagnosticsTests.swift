//
//  DiagnosticsTests.swift
//  StarcatTests
//
//  诊断日志与用户友好错误映射单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Diagnostics")
struct DiagnosticsTests {

    @Test("诊断事件会脱敏 Bearer token 与 API Key")
    func diagnosticEventRedactsSecrets() {
        let event = DiagnosticEvent(
            level: .error,
            category: "network",
            operation: "test",
            message: "Authorization: Bearer abc.def.ghi api_key=sk-secret",
            underlying: "token: ghp_secret"
        )

        #expect(event.message.contains("Bearer <redacted>"))
        #expect(event.message.contains("api_key=<redacted>"))
        #expect(event.underlying?.contains("token=<redacted>") == true)
        #expect(!event.message.contains("sk-secret"))
        #expect(event.underlying?.contains("ghp_secret") == false)
    }

    @Test("网络错误映射为用户友好文案并保留诊断状态码")
    func userFacingErrorMapsNetworkError() {
        let error = UserFacingError.map(
            NetworkError.serverError(statusCode: 503),
            operation: "syncing stars",
            service: "GitHub"
        )

        #expect(error.title == String.l10n("error.user.service.title"))
        #expect(error.message.contains("syncing stars"))
        #expect(error.message.contains("GitHub"))
        #expect(error.statusCode == 503)
        #expect(error.diagnosticSummary.contains("503"))
    }

    @Test("诊断日志写入 JSONL")
    func diagnosticLogStoreWritesJSONL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        await store.record(DiagnosticEvent(
            level: .warning,
            category: "sync",
            operation: "test",
            message: "hello token: secret"
        ))

        let text = await store.readAllText()
        #expect(text.contains("\"category\":\"sync\""))
        #expect(text.contains("token=<redacted>"))
        #expect(!text.contains("secret"))
    }

    @Test("确认诊断问题后状态摘要只统计新问题")
    func diagnosticLogStoreAcknowledgesOldIssues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(DiagnosticEvent(
            timestamp: base,
            level: .warning,
            category: "activity",
            operation: "old",
            message: "old warning"
        ))

        let beforeAcknowledgement = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(beforeAcknowledgement.issueCount == 1)

        await store.markIssuesAcknowledged(upTo: base.addingTimeInterval(1))

        let afterAcknowledgement = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(afterAcknowledgement.issueCount == 0)

        await store.record(DiagnosticEvent(
            timestamp: base.addingTimeInterval(2),
            level: .warning,
            category: "activity",
            operation: "new",
            message: "new warning"
        ))

        let afterNewIssue = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(afterNewIssue.issueCount == 1)
        #expect(afterNewIssue.latestIssue?.operation == "new")
    }
}
