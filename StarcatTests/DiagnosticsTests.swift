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

    @Test("诊断事件会脱敏裸密钥与用户绝对路径")
    func diagnosticEventRedactsRawSecretsAndPaths() {
        let event = DiagnosticEvent(
            level: .error,
            category: "storage",
            operation: "test",
            message: "Invalid API key sk-proj-abcdefghijklmnop",
            underlying: "failed at /Users/dong4j/Library/Application Support/Starcat/data.sqlite"
        )

        #expect(!event.message.contains("sk-proj-"))
        #expect(event.message.contains("<redacted>"))
        #expect(!event.underlying!.contains("/Users/dong4j"))
        #expect(event.underlying!.contains("/Users/<redacted>"))
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
        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("单仓摘要未配置 Provider 时直接展示配置文案")
    func userFacingErrorMapsMissingProvider() {
        let error = UserFacingError.map(
            RepoAIInsightError.missingProvider("摘要"),
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI"
        )

        #expect(error.title == String.l10n("error.user.aiConfiguration.title"))
        #expect(error.message == RepoAIInsightError.missingProvider("摘要").localizedDescription)
        #expect(!error.message.contains("在访问 AI 时失败"))
        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("单仓摘要缺少 API Key 时直接展示配置文案")
    func userFacingErrorMapsMissingAPIKey() {
        let error = UserFacingError.map(
            RepoAIInsightError.missingAPIKey,
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI"
        )

        #expect(error.title == String.l10n("error.user.aiConfiguration.title"))
        #expect(error.message == String.l10n("ai.insight.error.missingAPIKey"))
        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("本地数据库错误会进入开发者诊断")
    func userFacingDatabaseErrorRequiresDiagnostic() {
        let error = UserFacingError.map(
            DatabaseError.applicationSupportNotFound,
            operation: "loading local data",
            service: "Starcat"
        )

        #expect(error.shouldRecordDiagnostic)
    }

    @Test("未分类的外部 SDK 错误不会直接污染开发者诊断")
    func unknownExternalErrorDoesNotRequireDiagnostic() {
        let error = UserFacingError.map(
            NSError(domain: "ThirdPartySDK", code: 400),
            operation: "generating summary",
            service: "AI"
        )

        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("旧版诊断事件缺少 visibility 时只作为导出上下文")
    func legacyDiagnosticEventDefaultsToContext() throws {
        let data = Data("""
        {"timestamp":"2027-01-15T08:00:00Z","level":"error","category":"ai","operation":"legacy","message":"failed","context":{}}
        """.utf8)

        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: data)
        #expect(event.visibility == .context)
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

    @Test("诊断日志在阈值内只记录第一条重复事件")
    func diagnosticLogStoreSuppressesDuplicateEventsInsideWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(securityAdvisoryEvent(timestamp: base))
        await store.record(securityAdvisoryEvent(timestamp: base.addingTimeInterval(30)))

        let lines = await diagnosticLogLines(in: store)
        #expect(lines.count == 1)
    }

    @Test("诊断日志超过阈值后允许再次记录相同事件")
    func diagnosticLogStoreAllowsDuplicateEventsAfterWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(securityAdvisoryEvent(timestamp: base))
        await store.record(securityAdvisoryEvent(timestamp: base.addingTimeInterval(5 * 60 + 1)))

        let lines = await diagnosticLogLines(in: store)
        #expect(lines.count == 2)
    }

    @Test("诊断日志不同诊断细节不会被重复去重合并")
    func diagnosticLogStoreKeepsEventsWithDifferentDetails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(securityAdvisoryEvent(timestamp: base, statusCode: 500))
        await store.record(securityAdvisoryEvent(timestamp: base.addingTimeInterval(1), statusCode: 503))
        await store.record(securityAdvisoryEvent(
            timestamp: base.addingTimeInterval(2),
            context: ["repo": "owner/name"]
        ))

        let lines = await diagnosticLogLines(in: store)
        #expect(lines.count == 3)
    }

    @Test("底层系统描述变化不会绕过重复事件抑制")
    func diagnosticLogStoreIgnoresUnderlyingWhenDeduplicating() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(DiagnosticEvent(
            timestamp: base,
            level: .error,
            visibility: .issue,
            category: "ai",
            operation: "same",
            message: "same failure",
            underlying: "response pointer 0x1"
        ))
        await store.record(DiagnosticEvent(
            timestamp: base.addingTimeInterval(1),
            level: .error,
            visibility: .issue,
            category: "ai",
            operation: "same",
            message: "same failure",
            underlying: "response pointer 0x2"
        ))

        let lines = await diagnosticLogLines(in: store)
        #expect(lines.count == 1)
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
            visibility: .issue,
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
            visibility: .issue,
            category: "activity",
            operation: "new",
            message: "new warning"
        ))

        let afterNewIssue = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(afterNewIssue.issueCount == 1)
        #expect(afterNewIssue.latestIssue?.operation == "new")
    }

    @Test("上下文事件写入导出日志但不计入问题摘要")
    func diagnosticContextEventDoesNotBecomeIssue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let now = Date()
        await store.record(DiagnosticEvent(
            timestamp: now,
            level: .error,
            visibility: .context,
            category: "network",
            operation: "recoverable",
            message: "temporary failure"
        ))

        let text = await store.readAllText()
        let summary = await store.issueSummary(since: now.addingTimeInterval(-1))
        #expect(text.contains("\"operation\":\"recoverable\""))
        #expect(summary.issueCount == 0)
    }

    private func securityAdvisoryEvent(
        timestamp: Date,
        statusCode: Int? = nil,
        context: [String: String] = [:]
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: timestamp,
            level: .warning,
            category: "activity",
            operation: "securityAdvisories.fetch",
            message: "加载安全公告 在访问 GitHub 时失败。",
            service: "github",
            statusCode: statusCode,
            underlying: "已取消",
            context: context
        )
    }

    private func diagnosticLogLines(in store: DiagnosticLogStore) async -> [String] {
        let text = await store.readAllText()
        return text.split(separator: "\n").map(String.init)
    }
}
