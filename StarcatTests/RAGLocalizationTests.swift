//
//  RAGLocalizationTests.swift
//  StarcatTests
//
//  验证 RAG 核心层返回给工作台的固定文案跟随 App 显示语言；Planner / 模型产出的
//  动态内容不在这里翻译，避免把模型语义误当作产品文案。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RAG 固定文案国际化", .serialized)
struct RAGLocalizationTests {
    @Test("英文环境不会从计划与错误兜底泄漏固定中文")
    func englishFallbackCopyDoesNotLeakChinese() throws {
        try withLocaleOverride("en") {
            #expect(RAGUserVisiblePlan().scope == "Knowledge Base")

            let decoded = try JSONDecoder().decode(RAGUserVisiblePlan.self, from: Data("{}".utf8))
            #expect(decoded.scope == "Knowledge Base")

            let plan = try KnowledgeRAGQueryPlanner.decodeAndValidate(
                """
                {"mode":"semantic_only","semanticQuery":"Swift concurrency","filters":{},"remoteContextRequests":[],"confidence":"high","userVisiblePlan":{}}
                """,
                fallbackQuestion: "Which repositories use actors?"
            )
            #expect(plan.userVisiblePlan.scope == "Knowledge Base")
            #expect(RAGQueryPlannerError.emptyQuestion.errorDescription == "Question cannot be empty")
        }
    }

    @Test("英文环境本地化附件与外部后端错误")
    func englishErrorsAreLocalized() throws {
        try withLocaleOverride("en") {
            #expect(RAGAttachmentError.tooManyFiles.errorDescription == "You can attach up to 5 files at a time")
            #expect(RAGAttachmentError.fileTooLarge("notes.pdf").errorDescription == "Attachment is too large: notes.pdf")

            var meilisearch = RAGMeilisearchConfiguration()
            meilisearch.endpoint = "not a url"
            #expect(meilisearch.validationMessage == "Invalid Meilisearch endpoint")

            let responseError = RAGExternalBackendError.invalidResponse("Qdrant")
            #expect(responseError.errorDescription == "Qdrant returned an unreadable response")
            let httpError = RAGExternalBackendError.http(backend: "Qdrant", status: 500, message: "bad response")
            #expect(httpError.errorDescription == "Qdrant HTTP 500: bad response")
        }
    }

    /// `String.l10n` 直接读取持久化 key；测试必须恢复旧值，避免影响同一 test host 中的
    /// 其它本地化断言。Suite 串行化仅保护本文件内部的切换顺序。
    private func withLocaleOverride<T>(_ raw: String, _ body: () throws -> T) throws -> T {
        let defaults = UserDefaults.standard
        let old = defaults.string(forKey: "AppLocaleOverride")
        defaults.set(raw, forKey: "AppLocaleOverride")
        defer {
            if let old {
                defaults.set(old, forKey: "AppLocaleOverride")
            } else {
                defaults.removeObject(forKey: "AppLocaleOverride")
            }
        }
        return try body()
    }
}
