//
//  DirectUpdateControllerTests.swift
//  StarcatTests
//
//  Direct 自动更新配置门控单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DirectUpdateController")
@MainActor
struct DirectUpdateControllerTests {

    @Test("App Store 渠道不启用 Direct 更新")
    func appStoreBuildDoesNotExposeDirectUpdater() {
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "appstore",
            "SUPublicEDKey": "configured"
        ])

        let controller = DirectUpdateController(bundle: bundle)

        #expect(controller.isDirectBuild == false)
        #expect(controller.isConfigured == true)
        #expect(controller.canCheckForUpdates == false)
    }

    @Test("Direct 渠道缺少 Sparkle 公钥时不允许检查更新")
    func directBuildWithoutPublicKeyIsNotConfigured() {
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "direct",
            "SUPublicEDKey": "   "
        ])

        let controller = DirectUpdateController(bundle: bundle)

        #expect(controller.isDirectBuild)
        #expect(controller.isConfigured == false)
        #expect(controller.canCheckForUpdates == false)
    }

    @Test("Direct 渠道读取非空 Sparkle 公钥")
    func directBuildReadsConfiguredPublicKey() {
        let bundle = MockDirectUpdateBundle(info: [
            "STARCAT_DISTRIBUTION": "direct",
            "SUPublicEDKey": "mock-public-key"
        ])

        let controller = DirectUpdateController(bundle: bundle)

        #expect(controller.isDirectBuild)
        #expect(controller.isConfigured)
    }
}

private final class MockDirectUpdateBundle: Bundle, @unchecked Sendable {
    private let mockInfo: [String: Any]

    init(info: [String: Any]) {
        self.mockInfo = info
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        mockInfo[key]
    }
}
