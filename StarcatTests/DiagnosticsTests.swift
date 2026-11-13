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

    @Test("对话配置错误保留具体原因且不显示类型名", arguments: [
        AIChatSelectionError.missingProvider,
        .providerUnavailable, .missingModel, .incompatibleModel("private-model-detail")
    ])
    func chatSelectionErrorsHaveConfigurationRecovery(selection: AIChatSelectionError) {
        let mapped = UserFacingError.map(selection, operation: "Planning")
        #expect(mapped.title == String.l10n("error.user.aiConfiguration.title"))
        #expect(mapped.recovery == String.l10n("error.user.aiProvider.recovery.modelsSettings"))
        #expect(!mapped.message.contains("AIChatSelectionError"))
        #expect(!mapped.message.contains("private-model-detail"))
        #expect(!mapped.shouldRecordDiagnostic)
        let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .planning, error: selection)
        #expect(diagnostic.settingsTarget == "ai.chat")
    }

    @Test("外部搜索错误保留状态与搜索设置入口", arguments: [
        ExternalSearchError.disabled(provider: .exa),
        .missingAPIKey(provider: .exa), .unverifiedCredential(provider: .exa),
        .invalidCredential(provider: .exa, statusCode: 401, message: "private-server-body"),
        .invalidCredential(provider: .exa, statusCode: 403, message: "private-server-body"),
        .paymentRequired(provider: .exa, statusCode: 402, message: "private-server-body"),
        .rateLimited(provider: .exa, retryAfter: 12, message: "private-server-body"),
        .serviceUnavailable(provider: .exa, statusCode: 503, message: "private-server-body"),
        .invalidResponse(provider: .exa, message: "private-server-body"),
        .network(provider: .exa, message: "private-server-body")
    ])
    func externalSearchErrorsKeepTheirCategory(error: ExternalSearchError) {
        let mapped = UserFacingError.map(error, operation: "Web search")
        #expect(mapped.message == error.friendlyMessage)
        #expect(!mapped.message.contains("private-server-body"))
        #expect(!mapped.message.contains("ExternalSearchError"))
        if case .disabled = error { #expect(mapped.diagnosticOutcome == .skipped) }
        let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .webSearch, error: error)
        #expect(diagnostic.settingsTarget == "ai.externalSearch")
        switch error {
        case .invalidCredential(_, let status, _), .paymentRequired(_, let status, _),
             .serviceUnavailable(_, let status, _): #expect(diagnostic.statusCode == status)
        case .rateLimited: #expect(diagnostic.statusCode == 429)
        default: break
        }
    }

    @Test("Rerank HTTP 错误按鉴权余额限流和服务异常分类", arguments: [401, 402, 403, 429, 500, 503])
    func rerankHTTPFailuresKeepStatusAndSettings(status: Int) {
        let error = RAGExternalBackendError.http(
            backend: "Rerank", status: status, message: "private-server-body"
        )
        let diagnostic = SearchDiscoveryDiagnostic.failure(stage: .ranking, error: error)
        #expect(diagnostic.statusCode == status)
        #expect(diagnostic.settingsTarget == "rag.retrieval")
        #expect(!diagnostic.message.contains("private-server-body"))
        #expect(!diagnostic.message.contains("RAGExternalBackendError"))
        #expect(diagnostic.recovery?.isEmpty == false)
    }

    @Test("Rerank 配置和无效响应不归为未知错误")
    func rerankConfigurationAndDecodingHaveSpecificRecovery() {
        let configuration = UserFacingError.map(
            RAGExternalBackendError.invalidConfiguration("private-endpoint"),
            operation: "Rerank"
        )
        #expect(configuration.title == String.l10n("error.user.aiConfiguration.title"))
        #expect(!configuration.message.contains("private-endpoint"))
        let decoding = UserFacingError.map(
            RAGExternalBackendError.invalidResponse("Rerank"), operation: "Rerank"
        )
        #expect(decoding.title == String.l10n("error.user.decoding.title"))
    }

    @Test("DecodingError 摘要包含 codingPath，而不是只留本地化笼统句")
    func diagnosticEventSummarizesDecodingErrorPath() throws {
        struct Box: Decodable {
            let toy: Toy
        }
        enum Toy: String, Decodable {
            case known
        }

        let data = Data(#"{"toy":"not-a-real-case"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(Box.self, from: data)
            Issue.record("expected DecodingError")
        } catch {
            let summary = DiagnosticEvent.summarize(error)
            #expect(summary.contains("DecodingError"))
            #expect(summary.contains("toy"))
            #expect(summary.contains("not-a-real-case") || summary.contains("dataCorrupted") || summary.contains("typeMismatch"))
        }
    }

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
        #expect(event.underlying == "<unstructured-error-omitted>")
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
        #expect(event.underlying == "<unstructured-error-omitted>")
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
            RepoAIInsightError.missingAPIKey(String.l10n("ai.taskName.summary")),
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI"
        )

        #expect(error.title == String.l10n("error.user.aiConfiguration.title"))
        #expect(
            error.message == RepoAIInsightError.missingAPIKey(String.l10n("ai.taskName.summary")).localizedDescription
        )
        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("系统翻译错误不再显示为访问 AI 失败")
    func userFacingErrorMapsSystemTranslationSeparately() {
        let error = UserFacingError.map(
            SystemTranslationError.sessionUnavailable,
            operation: String.l10n("diagnostics.operation.translateReadme"),
            service: "系统翻译"
        )

        #expect(error.message == String.l10n("readme.translate.error.sessionUnavailable"))
        #expect(!error.message.contains("在访问 AI 时失败"))
        #expect(error.title == String.l10n("readme.translate.engine.system"))
    }

    @Test("本地 AI 超上下文不再显示为访问 AI 失败")
    func userFacingErrorMapsLocalAIContextTooLong() {
        let error = UserFacingError.map(
            LocalAIError.contextTooLong,
            operation: String.l10n("diagnostics.operation.aiChat"),
            service: "AI"
        )
        #expect(error.message == String.l10n("toolbar.localai.contextTooLong"))
        #expect(!error.message.contains("在访问 AI 时失败"))
        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("系统翻译语言包缺失不写入开发者诊断")
    func userFacingErrorSystemTranslationLanguagePackMissing() throws {
        let error = UserFacingError.map(
            SystemTranslationError.languagePackMissing,
            operation: String.l10n("diagnostics.operation.translateReadme"),
            service: "系统翻译"
        )

        #expect(error.message == String.l10n("readme.translate.error.languagePackMissing"))
        #expect(!error.shouldRecordDiagnostic)
    }

    @Test("业务确认数据库不可用后才进入开发者诊断")
    func userFacingDatabaseErrorRequiresDiagnostic() {
        let error = UserFacingError.map(
            DatabaseError.applicationSupportNotFound,
            operation: "loading local data",
            service: "Starcat", impact: .blocked, summary: .databaseUnavailable
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
            level: .error,
            visibility: .issue,
            category: "sync",
            operation: "test",
            message: "hello token: secret",
            summaryKey: DiagnosticIssue.syncFailed.rawValue,
            outcome: .failed, impact: .blocked
        ))

        let text = await store.readAllText()
        #expect(text.contains("\"category\":\"sync\""))
        #expect(text.contains("token=<redacted>"))
        #expect(!text.contains("secret"))
    }

    @Test("诊断日志在阈值内保留重复发生次数")
    func diagnosticLogStoreSuppressesDuplicateEventsInsideWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DiagnosticLogStore(directoryURL: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        await store.record(securityAdvisoryEvent(timestamp: base))
        await store.record(securityAdvisoryEvent(timestamp: base.addingTimeInterval(30)))

        let lines = await diagnosticLogLines(in: store)
        #expect(lines.count == 2)
        let events = lines.compactMap { try? JSONDecoder().decode(DiagnosticEvent.self, from: Data($0.utf8)) }
        #expect(events.reduce(0) { $0 + $1.occurrenceCount } == 2)
        #expect(events.last?.phase == "repeated")
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

    @Test("底层系统描述变化仍归入同一故障并保留次数")
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
            summaryKey: DiagnosticIssue.aiUnavailable.rawValue,
            underlying: "response pointer 0x1", outcome: .failed, impact: .blocked
        ))
        await store.record(DiagnosticEvent(
            timestamp: base.addingTimeInterval(1),
            level: .error,
            visibility: .issue,
            category: "ai",
            operation: "same",
            message: "same failure",
            summaryKey: DiagnosticIssue.aiUnavailable.rawValue,
            underlying: "response pointer 0x2", outcome: .failed, impact: .blocked
        ))

        let lines = await diagnosticLogLines(in: store)
        #expect(lines.count == 2)
        #expect(lines.last?.contains("\"phase\":\"repeated\"") == true)
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
            level: .error,
            visibility: .issue,
            category: "activity",
            operation: "old",
            message: "Old failure",
            summaryKey: DiagnosticIssue.contentUnavailable.rawValue, outcome: .failed, impact: .blocked
        ))

        let beforeAcknowledgement = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(beforeAcknowledgement.issueCount == 1)

        await store.markIssuesAcknowledged(upTo: base.addingTimeInterval(1))

        let afterAcknowledgement = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(afterAcknowledgement.issueCount == 0)

        await store.record(DiagnosticEvent(
            timestamp: base.addingTimeInterval(2),
            level: .error,
            visibility: .issue,
            category: "activity",
            operation: "new",
            message: "New failure",
            summaryKey: DiagnosticIssue.contentUnavailable.rawValue, outcome: .failed, impact: .blocked
        ))

        let afterNewIssue = await store.issueSummary(since: base.addingTimeInterval(-1))
        #expect(afterNewIssue.issueCount == 1)
        #expect(afterNewIssue.latestIssue?.operation == "new")
    }

    @Test("普通上下文事件既不落盘也不计入问题摘要")
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
        #expect(text.isEmpty)
        #expect(summary.issueCount == 0)
    }

    private func securityAdvisoryEvent(
        timestamp: Date,
        statusCode: Int? = nil,
        context: [String: String] = [:]
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: timestamp,
            level: .error,
            visibility: .issue,
            category: "activity",
            operation: "securityAdvisories.fetch",
            message: "Security advisories unavailable without usable cache",
            summaryKey: DiagnosticIssue.contentUnavailable.rawValue,
            service: "github",
            statusCode: statusCode,
            context: context, outcome: .failed, impact: .blocked
        )
    }

    private func diagnosticLogLines(in store: DiagnosticLogStore) async -> [String] {
        let text = await store.readAllText()
        return text.split(separator: "\n").map(String.init)
    }
}
