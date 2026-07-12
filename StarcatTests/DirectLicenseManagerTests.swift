//
//  DirectLicenseManagerTests.swift
//  StarcatTests
//
//  Direct License 冷启动权益恢复测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DirectLicenseManager", .serialized)
@MainActor
struct DirectLicenseManagerTests {

    @Test("本地已有 Direct license 时冷启动立即恢复 Pro 权益")
    func restoresOptimisticEntitlementFromStoredCredential() throws {
        let keychain = InMemoryKeychain()
        let store = DirectLicenseStore(keychain: keychain)
        try store.storeCredential(DirectLicenseCredential(
            licenseKey: "STARCAT-TEST-KEY",
            instanceID: "inst_123",
            subscriptionID: "sub_123",
            productID: "prod_lifetime",
            plan: .lifetime
        ))

        let manager = DirectLicenseManager(store: store)

        #expect(manager.storedCredential?.instanceID == "inst_123")
        #expect(manager.entitlement.isActive)
        #expect(manager.entitlement.source == .directLicense)
        #expect(manager.entitlement.productID == "prod_lifetime")
        #expect(manager.entitlement.verifiedAt == nil)
        #expect(manager.runtimeState == .localActive)
    }

    @Test("本地没有 Direct license 时冷启动保持 inactive")
    func remainsInactiveWithoutStoredCredential() {
        let manager = DirectLicenseManager(store: DirectLicenseStore(keychain: InMemoryKeychain()))

        #expect(manager.storedCredential == nil)
        #expect(manager.entitlement == .inactive)
    }

    @Test("Mac 硬件型号映射为授权设备类别")
    func mapsHardwareModelsToDeviceKinds() {
        #expect(DirectLicenseDeviceKind.forHardwareModelIdentifier("Mac14,13") == .macStudio)
        #expect(DirectLicenseDeviceKind.forHardwareModelIdentifier("Mac16,10") == .macMini)
        #expect(DirectLicenseDeviceKind.forHardwareModelIdentifier("MacBookPro18,3") == .macBookPro)
        #expect(DirectLicenseDeviceKind.forHardwareModelIdentifier("MacBookAir10,1") == .macBookAir)
        #expect(DirectLicenseDeviceKind.forHardwareModelIdentifier("unknown") == .mac)
    }

    @Test("支付回跳中的套餐参数不作为可信来源")
    func activationIgnoresTamperedPlanInDeepLink() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "active",
              "provider": "creem",
              "plan": "monthly",
              "productID": "prod_monthly",
              "instanceID": "inst_123",
              "validatedAt": "2026-07-08T00:00:00Z"
            }
            """)
        }

        let store = DirectLicenseStore(keychain: InMemoryKeychain())
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store)
        let url = URL(string: "starcat://license/activate?license_key=STARCAT-TEST-KEY&plan=yearly&product_id=prod_yearly")!

        let result = await manager.activateFromPaymentSuccessURL(url)

        #expect(result)
        #expect(manager.storedCredential?.plan == .monthly)
        #expect(manager.storedCredential?.productID == "prod_monthly")
        #expect(try store.loadCredential()?.plan == .monthly)
        #expect(try store.loadCredential()?.productID == "prod_monthly")
    }

    @Test("后台校验遇到临时服务端错误时保留本地 Pro")
    func validationTemporaryFailurePreservesLocalPro() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"code":"provider_unavailable"}"#.utf8))
        }

        let store = try Self.seededStore(plan: .monthly)
        let manager = DirectLicenseManager(
            api: Self.testAPI(),
            store: store,
            nowProvider: { Date(timeIntervalSince1970: 1_800) }
        )

        let result = await manager.validateStoredLicense()

        #expect(result)
        #expect(manager.entitlement.isActive)
        #expect(manager.runtimeState == DirectLicenseRuntimeState.localActive)
        #expect(manager.validationRecord.lastErrorCode == "provider_unavailable")
        #expect(try store.loadCredential() != nil)
    }

    @Test("服务端明确返回 revoked 时收回本地 Pro")
    func validationRevokedSnapshotRevokesLocalPro() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "revoked",
              "provider": "creem",
              "productID": "prod_monthly",
              "instanceID": "inst_123",
              "validatedAt": "2026-07-08T00:00:00Z"
            }
            """)
        }

        let store = try Self.seededStore(plan: .monthly)
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store)

        let result = await manager.validateStoredLicense()

        #expect(!result)
        #expect(!manager.entitlement.isActive)
        #expect(manager.runtimeState == DirectLicenseRuntimeState.revoked)
        #expect(try store.loadCredential() == nil)
    }

    @Test("解绑当前 Mac 后清空许可证快照与持久化验证状态")
    func deactivatingCurrentMacClearsAllLocalLicenseState() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "active",
              "provider": "creem",
              "plan": "monthly",
              "productID": "prod_monthly",
              "instanceID": "inst_123",
              "licenseKeySuffix": "93FR",
              "validatedAt": "2026-07-12T00:00:00Z"
            }
            """)
        }

        let store = DirectLicenseStore(keychain: InMemoryKeychain())
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store)

        let didActivate = await manager.activate(licenseKey: "STARCAT-TEST-KEY")
        #expect(didActivate)
        #expect(manager.lastSnapshot?.licenseKeySuffix == "93FR")

        let didDeactivate = await manager.deactivateStoredLicense()
        #expect(didDeactivate)
        #expect(manager.storedCredential == nil)
        #expect(manager.lastSnapshot == nil)
        #expect(manager.lastSubscriptionSnapshot == nil)
        #expect(manager.validationRecord == .empty)
        #expect(manager.licenseDevices.isEmpty)
        #expect(manager.runtimeState == .none)
        #expect(manager.entitlement == .inactive)
        #expect(try store.loadCredential() == nil)

        let restoredManager = DirectLicenseManager(store: store)
        #expect(restoredManager.validationRecord == .empty)
    }

    @Test("月订阅 24 小时内启动校验不重复请求后端")
    func monthlyValidationIsThrottledWithinOneDay() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "active",
              "provider": "creem",
              "productID": "prod_monthly",
              "instanceID": "inst_123",
              "validatedAt": "2026-07-08T00:00:00Z"
            }
            """)
        }

        let store = try Self.seededStore(plan: .monthly)
        try store.storeValidationRecord(DirectLicenseValidationRecord(
            plan: .monthly,
            runtimeState: .verifiedActive,
            lastAttemptAt: Date(timeIntervalSince1970: 1_000),
            lastSuccessAt: Date(timeIntervalSince1970: 1_000),
            lastFailureAt: nil,
            lastErrorCode: nil,
            lastRemoteStatus: .active
        ))
        let manager = DirectLicenseManager(
            api: Self.testAPI(),
            store: store,
            nowProvider: { Date(timeIntervalSince1970: 1_000 + 60 * 60) }
        )

        let result = await manager.validateStoredLicenseIfNeeded()

        #expect(result)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("终身授权 7 天后启动校验会请求后端")
    func lifetimeValidationRunsAfterSevenDays() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "active",
              "provider": "creem",
              "productID": "prod_lifetime",
              "instanceID": "inst_123",
              "validatedAt": "2026-07-08T00:00:00Z"
            }
            """)
        }

        let store = try Self.seededStore(plan: .lifetime, productID: "prod_lifetime")
        try store.storeValidationRecord(DirectLicenseValidationRecord(
            plan: .lifetime,
            runtimeState: .verifiedActive,
            lastAttemptAt: Date(timeIntervalSince1970: 1_000),
            lastSuccessAt: Date(timeIntervalSince1970: 1_000),
            lastFailureAt: nil,
            lastErrorCode: nil,
            lastRemoteStatus: .active
        ))
        let manager = DirectLicenseManager(
            api: Self.testAPI(),
            store: store,
            nowProvider: { Date(timeIntervalSince1970: 1_000 + 7 * 24 * 60 * 60 + 1) }
        )

        let result = await manager.validateStoredLicenseIfNeeded()

        #expect(result)
        #expect(URLProtocolStub.receivedRequests.count == 1)
        #expect(manager.runtimeState == DirectLicenseRuntimeState.verifiedActive)
    }

    private nonisolated static func seededStore(
        plan: DirectCheckoutPlan,
        productID: String = "prod_monthly"
    ) throws -> DirectLicenseStore {
        let keychain = InMemoryKeychain()
        let store = DirectLicenseStore(keychain: keychain)
        try store.storeCredential(DirectLicenseCredential(
            licenseKey: "STARCAT-TEST-KEY",
            instanceID: "inst_123",
            subscriptionID: plan == .monthly ? "sub_123" : nil,
            productID: productID,
            plan: plan
        ))
        return store
    }

    private nonisolated static func testAPI() -> DirectLicenseAPI {
        DirectLicenseAPI(
            baseURL: URL(string: "https://license.test.invalid")!,
            apiKey: "license-api-key",
            urlSession: URLProtocolStub.ephemeralSession()
        )
    }

    private nonisolated static func jsonResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}
