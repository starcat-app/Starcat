//
//  ExternalContextDegradationReasonTests.swift
//  StarcatTests
//
//  Y9.3（2026-06-14 dong4j 反馈"开关都开了为什么没注入"修复）：覆盖
//  ExternalContextDegradationReason.classify 把 AnySearchError 7 种 typed case
//  + URLError 全集 + 兜底路径正确分类的单测。
//
//  关键约束：classify 是 nonisolated static 纯函数，可在测试线程直接调用，
//  无需 mock service / settings。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ExternalContextDegradationReason — classify mapping")
struct ExternalContextDegradationReasonTests {

    // MARK: - AnySearchError typed case

    @Test("502/503/504 → .serviceUnavailable")
    func serviceUnavailableMapsToServiceUnavailable() {
        let reason = ExternalContextDegradationReason.classify(
            AnySearchError.serviceUnavailable(message: "Bad Gateway")
        )
        if case .serviceUnavailable(let code) = reason {
            #expect(code == nil)  // typed case 不带 status
        } else {
            Issue.record("Expected .serviceUnavailable, got \(reason)")
        }
    }

    @Test("server(statusCode:) 兜底 → .serviceUnavailable 携带具体码")
    func serverStatusCodeCarriesNumber() {
        let reason = ExternalContextDegradationReason.classify(
            AnySearchError.server(statusCode: 599)
        )
        if case .serviceUnavailable(let code) = reason {
            #expect(code == 599)
        } else {
            Issue.record("Expected .serviceUnavailable(599), got \(reason)")
        }
    }

    @Test("transport → .networkUnavailable")
    func transportMapsToNetworkUnavailable() {
        let reason = ExternalContextDegradationReason.classify(
            AnySearchError.transport("timed out")
        )
        #expect(reason == .networkUnavailable)
    }

    @Test("invalidAPIKey 不论 reason 子类型 → .invalidAPIKey")
    func invalidAPIKeyMapsToInvalidAPIKey() {
        for sub in [AnySearchError.KeyFailReason.invalid, .malformedHeader, .expired] {
            let reason = ExternalContextDegradationReason.classify(
                AnySearchError.invalidAPIKey(reason: sub)
            )
            #expect(reason == .invalidAPIKey)
        }
    }

    @Test("anonymousQuotaExhausted / keyQuotaExhausted → .quotaExhausted")
    func quotaErrorsMapToQuotaExhausted() {
        #expect(
            ExternalContextDegradationReason.classify(AnySearchError.anonymousQuotaExhausted)
                == .quotaExhausted
        )
        #expect(
            ExternalContextDegradationReason.classify(
                AnySearchError.keyQuotaExhausted(limit: 1000, used: 1000)
            ) == .quotaExhausted
        )
    }

    @Test("rateLimited → .rateLimited（不论 scope）")
    func rateLimitedMapsToRateLimited() {
        for scope in [AnySearchError.RateLimitScope.key, .account] {
            let reason = ExternalContextDegradationReason.classify(
                AnySearchError.rateLimited(scope: scope, retryAfter: 60)
            )
            #expect(reason == .rateLimited)
        }
    }

    @Test("capabilityNotEnabled / accountDisabled → .capabilityNotEnabled")
    func capabilityErrorsMapToCapabilityNotEnabled() {
        #expect(
            ExternalContextDegradationReason.classify(
                AnySearchError.capabilityNotEnabled(message: "private_capability_not_enabled")
            ) == .capabilityNotEnabled
        )
        #expect(
            ExternalContextDegradationReason.classify(AnySearchError.accountDisabled)
                == .capabilityNotEnabled
        )
    }

    @Test("disabled / invalidURL / invalidRequest / invalidResponse / api / decoding → .unknown")
    func miscAnySearchErrorsMapToUnknown() {
        let cases: [AnySearchError] = [
            .disabled,
            .invalidURL,
            .invalidRequest(message: "bad request"),
            .invalidResponse,
            .api(code: -1, message: "biz error"),
            .decoding
        ]
        for err in cases {
            #expect(ExternalContextDegradationReason.classify(err) == .unknown)
        }
    }

    // MARK: - URLError fallback

    @Test("URLError 任意子类型 → .networkUnavailable")
    func urlErrorMapsToNetworkUnavailable() {
        for code: URLError.Code in [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost] {
            let reason = ExternalContextDegradationReason.classify(URLError(code))
            #expect(reason == .networkUnavailable, "URLError(\(code)) should map to .networkUnavailable")
        }
    }

    // MARK: - 兜底

    @Test("未知错误类型 → .unknown")
    func unknownErrorMapsToUnknown() {
        struct CustomError: Error {}
        #expect(ExternalContextDegradationReason.classify(CustomError()) == .unknown)
    }

    // MARK: - bannerMessageKey 完整性

    @Test("每个 case 都有 bannerMessageKey 且键名以 ai.externalContext.degraded. 开头")
    func everyCaseHasBannerMessageKey() {
        let cases: [ExternalContextDegradationReason] = [
            .serviceUnavailable(statusCode: 502),
            .networkUnavailable,
            .invalidAPIKey,
            .quotaExhausted,
            .rateLimited,
            .capabilityNotEnabled,
            .unknown
        ]
        for c in cases {
            #expect(c.bannerMessageKey.hasPrefix("ai.externalContext.degraded."))
            #expect(!c.bannerMessageKey.isEmpty)
        }
    }
}
