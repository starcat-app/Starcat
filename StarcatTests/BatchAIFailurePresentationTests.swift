//
//  BatchAIFailurePresentationTests.swift
//  StarcatTests
//
//  批量 AI 整理失败文案：短文案 + 诊断详情分流。
//

import Foundation
import OpenAI
import Testing
@testable import Starcat

@MainActor
@Suite("BatchAIFailurePresentation", .serialized)
struct BatchAIFailurePresentationTests {

    @Test("AIClientError 请求拒绝时主文案含 HTTP 状态码，诊断保留 detail")
    func requestRejectedKeepsShortMessageAndDiagnostic() {
        let error = AIClientError.requestRejected(
            statusCode: 400,
            detail: "HTTP 400 https://api.deepseek.com/v1/chat/completions"
        )
        let short = BatchAIQueueService.userVisibleFailureMessage(for: error)
        #expect(short.contains("400"))
        #expect(!short.lowercased().contains("nshttpurlresponse"))

        let friendly = UserFacingError.map(
            error,
            operation: String.l10n("diagnostics.operation.generateAIInsight"),
            service: "AI"
        )
        let diagnostic = BatchAIQueueService.failureDiagnostic(
            for: error,
            friendly: friendly,
            shortMessage: short
        )
        #expect(diagnostic?.contains("api.deepseek.com") == true)
        #expect(diagnostic != short)
    }

    @Test("SDK dump 风格字符串不会直接作为主文案")
    func rawSDKDumpFallsBackToUnknown() {
        let dump = "statusError(response: <NSHTTPURLResponse: 0x123> { Status Code: 400 })"
        let error = NSError(domain: "test", code: 400, userInfo: [
            NSLocalizedDescriptionKey: dump
        ])
        let short = BatchAIQueueService.userVisibleFailureMessage(for: error)
        #expect(short == String.l10n("batchAI.panel.row.failedUnknown"))
        #expect(!short.lowercased().contains("statuserror"))
    }

    @Test("OpenAIClient.mapChatFailure 把 statusError 收成 requestRejected")
    func mapChatFailureStatusError() {
        let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        // 通过 OpenAIError 构造：测试目标是 mapChatFailure，不依赖真实网络。
        let sdkError = OpenAIError.statusError(response: response, statusCode: 400)
        let mapped = OpenAIClient.mapChatFailure(sdkError)
        guard case .requestRejected(let code, let detail) = mapped else {
            Issue.record("expected requestRejected, got \(mapped)")
            return
        }
        #expect(code == 400)
        #expect(detail.contains("400"))
        #expect(detail.contains("URL:"))
        #expect(detail.contains("api.deepseek.com"))
        #expect(!mapped.localizedDescription.lowercased().contains("nshttpurlresponse"))
    }

    @Test("OpenAIClient.mapChatFailure 把 401 收成 authenticationRejected 并保留诊断")
    func mapChatFailureUnauthorized() {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let mapped = OpenAIClient.mapChatFailure(
            OpenAIError.statusError(response: response, statusCode: 401)
        )
        guard case .authenticationRejected(let detail) = mapped else {
            Issue.record("expected authenticationRejected, got \(mapped)")
            return
        }
        #expect(detail.contains("401"))
        #expect(detail.contains("api.openai.com"))
    }

    @Test("OpenAIClient.mapChatFailure 把 402 收成 paymentRequired")
    func mapChatFailurePaymentRequired() {
        let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 402,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let mapped = OpenAIClient.mapChatFailure(
            OpenAIError.statusError(response: response, statusCode: 402)
        )
        guard case .paymentRequired(let detail) = mapped else {
            Issue.record("expected paymentRequired, got \(mapped)")
            return
        }
        #expect(detail.contains("402"))
        #expect(mapped.localizedDescription == String.l10n("ai.client.error.paymentRequired"))
        #expect(BatchAIQueueService.userVisibleFailureMessage(for: mapped).contains("402"))
    }

    @Test("HTTP 失败诊断包含格式化的原始请求与响应 JSON")
    func mapChatFailureIncludesFormattedRequestAndResponseJSON() {
        let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 402,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let exchange = AIHTTPFailureExchange(
            url: url,
            statusCode: 402,
            mimeType: "application/json",
            requestBody: Data(#"{"model":"deepseek-chat","messages":[{"role":"user","content":"hello"}]}"#.utf8),
            responseBody: Data(#"{"error":{"type":"insufficient_balance","message":"Insufficient Balance"}}"#.utf8),
            responseBodyTruncated: false
        )

        let mapped = OpenAIClient.mapChatFailure(
            OpenAIError.statusError(response: response, statusCode: 402),
            exchange: exchange
        )
        guard case .paymentRequired(let detail) = mapped else {
            Issue.record("expected paymentRequired, got \(mapped)")
            return
        }

        #expect(detail.contains("Response JSON:\n{"))
        #expect(detail.contains(#""message" : "Insufficient Balance""#))
        #expect(detail.contains("Request JSON:\n{"))
        #expect(detail.contains(#""model" : "deepseek-chat""#))
        #expect(detail.contains("\n  \"messages\" : ["))
    }

    @Test("失败交换缓存禁止 nil/nil 通配取走，避免并发错绑")
    func failureExchangeStoreRejectsWildcardTake() {
        let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
        AIHTTPFailureExchangeStore.shared.record(AIHTTPFailureExchange(
            url: url,
            statusCode: 402,
            mimeType: "application/json",
            requestBody: Data(#"{"model":"a"}"#.utf8),
            responseBody: Data(#"{"error":"x"}"#.utf8),
            responseBodyTruncated: false
        ))
        #expect(AIHTTPFailureExchangeStore.shared.take(url: nil, statusCode: nil) == nil)
        let taken = AIHTTPFailureExchangeStore.shared.take(url: url, statusCode: 402)
        #expect(taken?.statusCode == 402)
    }

    @Test("同一个结构化失败会跟随应用语言重新生成文案")
    func structuredFailureRelocalizesAfterLanguageChange() {
        let defaults = UserDefaults.standard
        let key = "AppLocaleOverride"
        let previous = defaults.string(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let failure = BatchAIFailure.aiClient(
            .paymentRequired(detail: "HTTP 402 payment required")
        )

        defaults.set("zh-Hans", forKey: key)
        let chinese = failure.localizedMessage
        #expect(chinese.contains("余额不足"))
        let chineseReport = BatchAIQueueService.copyableFailureReport(
            repoFullName: "owner/repo",
            message: chinese,
            diagnostic: "HTTP 402"
        )
        #expect(chineseReport.contains("仓库：owner/repo"))
        #expect(chineseReport.contains("错误："))

        defaults.set("en", forKey: key)
        let english = failure.localizedMessage
        #expect(english.contains("insufficient balance"))
        #expect(english != chinese)
        let englishReport = BatchAIQueueService.copyableFailureReport(
            repoFullName: "owner/repo",
            message: english,
            diagnostic: "HTTP 402"
        )
        #expect(englishReport.contains("Repo: owner/repo"))
        #expect(englishReport.contains("Message:"))
    }

    @Test("复制报告包含仓库、短文案与诊断全文")
    func copyableFailureReportIncludesFullPackage() {
        let report = BatchAIQueueService.copyableFailureReport(
            repoFullName: "mvanhorn/last30days-skill",
            message: String.l10n("ai.client.error.paymentRequired"),
            diagnostic: "HTTP 402 Payment Required\nURL: https://api.deepseek.com/v1/chat/completions"
        )
        #expect(report.contains("mvanhorn/last30days-skill"))
        #expect(report.contains(String.l10n("ai.client.error.paymentRequired")))
        #expect(report.contains("HTTP 402"))
        #expect(report.contains("api.deepseek.com"))
    }
}
