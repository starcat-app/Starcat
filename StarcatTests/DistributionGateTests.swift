//
//  DistributionGateTests.swift
//  StarcatTests
//
//  分发渠道能力门控单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DistributionGate")
struct DistributionGateTests {

    @Test("App Store 构建拒绝 Direct-only 能力")
    func appStoreBuildRejectsDirectOnlyFeatures() {
        let gate = DistributionGate(channel: .appStore)

        #expect(gate.isAvailable(.localAutomation) == false)
        #expect(throws: DistributionGateError.directOnly(feature: .localAutomation, current: .appStore)) {
            try gate.requireDirect(.localAutomation)
        }
    }

    @Test("Direct 构建允许 Direct-only 能力")
    func directBuildAllowsDirectOnlyFeatures() throws {
        let gate = DistributionGate(channel: .direct)

        for feature in ChannelFeature.allCases {
            #expect(gate.isAvailable(feature))
            try gate.requireAvailable(feature)
        }
    }

    @Test("自动更新和授权码都属于渠道能力，不属于 Pro 权益")
    func existingDirectBoundariesAreChannelFeatures() {
        let gate = DistributionGate(channel: .appStore)

        #expect(gate.isAvailable(.automaticUpdates) == false)
        #expect(gate.isAvailable(.directLicense) == false)
        #expect(gate.isAvailable(.deviceFlowLogin) == false)
        #expect(gate.isAvailable(.personalAccessTokenLogin) == false)
    }
}
