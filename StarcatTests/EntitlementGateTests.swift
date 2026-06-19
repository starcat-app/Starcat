//
//  EntitlementGateTests.swift
//  StarcatTests
//
//  StoreKit Pro 门控规则单测。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("EntitlementGate")
struct EntitlementGateTests {

    @Test("AI 摘要免费用户直接需要 Pro")
    func aiSummaryRequiresPro() throws {
        let gate = makeGate(
            isPro: false,
            userID: 42
        )

        do {
            try gate.requirePro(.aiSummary)
            Issue.record("免费用户生成 AI 摘要应被 Pro 门控拦截")
        } catch let error as EntitlementGateError {
            #expect(error == .requiresPro(feature: .aiSummary))
        }
    }

    @Test("Pro 用户可使用 AI 标签推荐")
    func proCanUseAITags() throws {
        let gate = makeGate(
            isPro: true,
            userID: 7
        )

        try gate.requirePro(.aiTags)
    }

    @Test("免费用户最多创建 20 个标签")
    func freeTagLimit() throws {
        let freeGate = makeGate(isPro: false)
        try freeGate.validateTagCreation(currentTagCount: 19)

        do {
            try freeGate.validateTagCreation(currentTagCount: 20)
            Issue.record("第 21 个标签应被门控拦截")
        } catch let error as EntitlementGateError {
            #expect(error == .tagLimitReached(limit: 20))
        }

        let proGate = makeGate(isPro: true)
        try proGate.validateTagCreation(currentTagCount: 200)
    }

    @Test("免费用户最多订阅 5 个 Release")
    func freeReleaseSubscriptionLimit() throws {
        let gate = makeGate(isPro: false)
        try gate.validateReleaseSubscription(activeSubscriptionCount: 4, isAlreadySubscribed: false)
        try gate.validateReleaseSubscription(activeSubscriptionCount: 5, isAlreadySubscribed: true)

        do {
            try gate.validateReleaseSubscription(activeSubscriptionCount: 5, isAlreadySubscribed: false)
            Issue.record("第 6 个 Release 订阅应被门控拦截")
        } catch let error as EntitlementGateError {
            #expect(error == .releaseSubscriptionLimitReached(limit: 5))
        }
    }

    private func makeGate(
        isPro: Bool,
        userID: Int64? = nil
    ) -> EntitlementGate {
        return EntitlementGate(
            entitlementProvider: MockProEntitlementProvider(isPro: isPro),
            userIDProvider: { userID }
        )
    }
}

@MainActor
private final class MockProEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}
