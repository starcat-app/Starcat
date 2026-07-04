//
//  DistributionChannelTests.swift
//  StarcatTests
//
//  分发渠道解析单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DistributionChannel")
struct DistributionChannelTests {

    @Test("缺省配置回退到 App Store")
    func missingValueFallsBackToAppStore() {
        let bundle = makeBundle(info: [:])

        #expect(DistributionChannel.resolve(from: bundle) == .appStore)
    }

    @Test("Direct 值大小写和空白不敏感")
    func directValueIsNormalized() {
        let bundle = makeBundle(info: ["STARCAT_DISTRIBUTION": " Direct "])

        #expect(DistributionChannel.resolve(from: bundle) == .direct)
        #expect(DistributionChannel.resolve(from: bundle).isDirect)
    }

    @Test("非法值保守回退 App Store")
    func invalidValueFallsBackToAppStore() {
        let bundle = makeBundle(info: ["STARCAT_DISTRIBUTION": "website"])

        #expect(DistributionChannel.resolve(from: bundle) == .appStore)
        #expect(DistributionChannel.resolve(from: bundle).isAppStore)
    }

    private func makeBundle(info: [String: Any]) -> Bundle {
        MockInfoBundle(info: info)
    }
}

private final class MockInfoBundle: Bundle, @unchecked Sendable {
    private let mockInfo: [String: Any]

    init(info: [String: Any]) {
        self.mockInfo = info
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        mockInfo[key]
    }
}
