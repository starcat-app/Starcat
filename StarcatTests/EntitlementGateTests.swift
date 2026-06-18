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

    @Test("AI 摘要免费试用 3 次，第四次需要 Pro")
    func aiSummaryTrialQuota() throws {
        let defaults = isolatedDefaults()
        let gate = makeGate(
            isPro: false,
            defaults: defaults,
            userID: 42
        )

        try gate.consumeTrialOrRequirePro(.aiSummary)
        try gate.consumeTrialOrRequirePro(.aiSummary)
        try gate.consumeTrialOrRequirePro(.aiSummary)

        do {
            try gate.consumeTrialOrRequirePro(.aiSummary)
            Issue.record("第四次 AI 摘要试用应被门控拦截")
        } catch let error as EntitlementGateError {
            #expect(error == .trialQuotaExceeded(feature: .aiSummary, limit: 3))
        }
    }

    @Test("Pro 用户不消耗 AI 免费试用配额")
    func proDoesNotConsumeTrialQuota() throws {
        let defaults = isolatedDefaults()
        let gate = makeGate(
            isPro: true,
            defaults: defaults,
            userID: 7
        )

        try gate.consumeTrialOrRequirePro(.aiTags)

        let store = TrialQuotaStore(defaults: defaults)
        #expect(store.usedCount(kind: .aiTags, userID: 7) == 0)
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
        defaults: UserDefaults? = nil,
        userID: Int64? = nil
    ) -> EntitlementGate {
        let resolvedDefaults = defaults ?? isolatedDefaults()
        return EntitlementGate(
            entitlementProvider: MockProEntitlementProvider(isPro: isPro),
            trialQuotaStore: TrialQuotaStore(defaults: resolvedDefaults),
            userIDProvider: { userID }
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.entitlement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
