//
//  AppStoreUpdateControllerTests.swift
//  StarcatTests
//
//  App Store 更新查询、版本比较、渠道门控与节流行为测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AppStoreUpdateController", .serialized)
@MainActor
struct AppStoreUpdateControllerTests {

    @Test("版本号按数字段比较且忽略尾部零")
    func comparesNumericVersionComponents() throws {
        let oneNine = try #require(AppStoreVersion("1.9"))
        let oneTen = try #require(AppStoreVersion("1.10"))
        let oneTwo = try #require(AppStoreVersion("1.2"))
        let oneTwoZero = try #require(AppStoreVersion("1.2.0"))

        #expect(oneNine < oneTen)
        #expect(oneTwo == oneTwoZero)
        #expect(AppStoreVersion("1..2") == nil)
        #expect(AppStoreVersion("1.2-beta") == nil)
    }

    @Test("Lookup API 使用固定 App ID 并返回 Mac App Store 跳转")
    func lookupClientUsesCanonicalAppIdentity() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let body = """
            {
              "resultCount": 1,
              "results": [{
                "trackId": 6788809803,
                "bundleId": "com.starcat.app.store",
                "version": "1.2.0"
              }]
            }
            """
            guard let url = request.url else {
                throw AppStoreUpdateError.invalidResponse
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let client = URLSessionAppStoreUpdateClient(
            session: URLProtocolStub.ephemeralSession(),
            countryCode: "cn"
        )
        let listing = try await client.fetchLatestVersion()
        let request = try #require(URLProtocolStub.receivedRequests.first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )

        #expect(components.queryItems?.contains(
            URLQueryItem(name: "id", value: "6788809803")
        ) == true)
        #expect(components.queryItems?.contains(
            URLQueryItem(name: "country", value: "cn")
        ) == true)
        #expect(listing.version == "1.2.0")
        #expect(
            listing.storeURL.absoluteString
                == "macappstore://itunes.apple.com/app/id6788809803"
        )
    }

    @Test("App Store 自动检查按天节流且同版本只自动提示一次")
    func automaticCheckIsThrottledAndDeduplicated() async throws {
        let testDefaults = makeDefaults()
        let defaults = testDefaults.value
        defer { clear(testDefaults) }
        let client = RecordingAppStoreUpdateClient(
            listing: AppStoreListing(
                version: "1.2.0",
                storeURL: URL(string: "macappstore://itunes.apple.com/app/id6788809803")!
            )
        )
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = AppStoreUpdateController(
            bundle: MockAppStoreUpdateBundle(
                distribution: "appstore",
                version: "1.1.0"
            ),
            client: client,
            defaults: defaults,
            now: { now },
            allowsAutomaticChecks: true
        )

        await controller.checkAutomaticallyIfNeeded()
        #expect(controller.presentation == .updateAvailable(
            currentVersion: "1.1.0",
            listing: AppStoreListing(
                version: "1.2.0",
                storeURL: URL(string: "macappstore://itunes.apple.com/app/id6788809803")!
            )
        ))
        #expect(await client.callCount == 1)

        controller.dismissPresentation()
        await controller.checkAutomaticallyIfNeeded()
        #expect(await client.callCount == 1)

        now.addTimeInterval(AppStoreUpdateController.automaticCheckInterval + 1)
        await controller.checkAutomaticallyIfNeeded()
        #expect(await client.callCount == 2)
        #expect(controller.presentation == nil)
    }

    @Test("Direct 渠道不会请求 App Store")
    func directBuildSkipsAppStoreLookup() async {
        let testDefaults = makeDefaults()
        let defaults = testDefaults.value
        defer { clear(testDefaults) }
        let client = RecordingAppStoreUpdateClient(
            listing: AppStoreListing(
                version: "9.9.9",
                storeURL: URL(string: "macappstore://itunes.apple.com/app/id6788809803")!
            )
        )
        let controller = AppStoreUpdateController(
            bundle: MockAppStoreUpdateBundle(
                distribution: "direct",
                version: "1.0.0"
            ),
            client: client,
            defaults: defaults,
            allowsAutomaticChecks: true
        )

        await controller.checkAutomaticallyIfNeeded()
        await controller.checkManually()

        #expect(controller.canCheckForUpdates == false)
        #expect(controller.presentation == nil)
        #expect(await client.callCount == 0)
    }

    @Test("手动检查在当前版本和失败时都给出明确结果")
    func manualCheckPresentsCurrentAndFailureStates() async {
        let testDefaults = makeDefaults()
        let defaults = testDefaults.value
        defer { clear(testDefaults) }
        let bundle = MockAppStoreUpdateBundle(
            distribution: "appstore",
            version: "1.2.0"
        )
        let currentController = AppStoreUpdateController(
            bundle: bundle,
            client: RecordingAppStoreUpdateClient(
                listing: AppStoreListing(
                    version: "1.2",
                    storeURL: URL(string: "macappstore://itunes.apple.com/app/id6788809803")!
                )
            ),
            defaults: defaults
        )

        await currentController.checkManually()
        #expect(currentController.presentation == .upToDate(currentVersion: "1.2.0"))

        let failedController = AppStoreUpdateController(
            bundle: bundle,
            client: FailingAppStoreUpdateClient(),
            defaults: defaults
        )
        await failedController.checkManually()
        #expect(failedController.presentation == .failed)
    }

    private func makeDefaults() -> TestDefaults {
        let suiteName = "AppStoreUpdateControllerTests.\(UUID().uuidString)"
        return TestDefaults(
            suiteName: suiteName,
            value: UserDefaults(suiteName: suiteName)!
        )
    }

    private func clear(_ defaults: TestDefaults) {
        defaults.value.removePersistentDomain(forName: defaults.suiteName)
    }
}

private struct TestDefaults {
    let suiteName: String
    let value: UserDefaults
}

private actor RecordingAppStoreUpdateClient: AppStoreUpdateFetching {
    let listing: AppStoreListing
    private(set) var callCount = 0

    init(listing: AppStoreListing) {
        self.listing = listing
    }

    func fetchLatestVersion() async throws -> AppStoreListing {
        callCount += 1
        return listing
    }
}

private struct FailingAppStoreUpdateClient: AppStoreUpdateFetching {
    func fetchLatestVersion() async throws -> AppStoreListing {
        throw URLError(.notConnectedToInternet)
    }
}

private final class MockAppStoreUpdateBundle: Bundle, @unchecked Sendable {
    private let mockInfo: [String: Any]

    init(distribution: String, version: String) {
        mockInfo = [
            "STARCAT_DISTRIBUTION": distribution,
            "CFBundleShortVersionString": version
        ]
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        mockInfo[key]
    }
}
