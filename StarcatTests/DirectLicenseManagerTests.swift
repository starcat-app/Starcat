//
//  DirectLicenseManagerTests.swift
//  StarcatTests
//
//  Direct License 冷启动权益恢复、HTTP 错误分层与脱敏诊断回归测试。
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

    @Test("License HTTP 错误按业务 code 分层，未知故障保留权益", arguments: [
        (404, "LICENSE_NOT_FOUND", DirectLicenseAPIError.licenseNotFound, false),
        (403, "ACTIVATION_LIMIT_REACHED", .activationLimitReached, true),
        (502, "PROVIDER_ERROR", .temporaryServerFailure(statusCode: 502, code: "provider_error"), true),
        (503, "PROVIDER_NOT_CONFIGURED", .temporaryServerFailure(statusCode: 503, code: "provider_not_configured"), true),
        (403, "LICENSE_EXPIRED", .licenseRejected(code: "license_expired"), false),
        (401, "", .unauthorizedClient, true),
        (404, "", .invalidResponse, true),
        (502, "SENSITIVE-LICENSE-KEY", .temporaryServerFailure(statusCode: 502, code: nil), true)
    ])
    func mapsLicenseHTTPErrors(
        status: Int,
        code: String,
        expected: DirectLicenseAPIError,
        preservesEntitlement: Bool
    ) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let data = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "message": "SENSITIVE-LICENSE-KEY customer@example.com",
            "traceID": "SENSITIVE-LICENSE-KEY\nFORGED-LOG"
        ])
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        do {
            _ = try await Self.testAPI().activate(DirectLicenseActivationRequest(licenseKey: "KEY", deviceID: "Mac", appVersion: "1.8.0"))
            Issue.record("Expected activation to fail")
        } catch let error as DirectLicenseAPIError {
            #expect(error == expected)
            #expect(error.preservesLocalEntitlement == preservesEntitlement)
            #expect(!error.diagnosticCode.contains("SENSITIVE-LICENSE-KEY"))
        }
        // activate 有副作用，收到错误也不能自动重试而重复占用席位。
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("激活限流禁止重复及深链请求，期满仅恢复手动激活")
    func activationCooldownBlocksRequestsUntilDeadline() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "60"]
            )!
            return (response, Data(#"{"code":"RATE_LIMITED"}"#.utf8))
        }
        var now = Date(timeIntervalSince1970: 1_000)
        let store = try Self.seededStore(plan: .monthly)
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store, nowProvider: { now })

        #expect(await manager.activate(licenseKey: "NEW-KEY") == false)
        #expect(manager.activationRetrySeconds() == 60)
        #expect(manager.entitlement.isActive)
        #expect(try store.loadCredential()?.licenseKey == "STARCAT-TEST-KEY")
        #expect(await manager.activate(licenseKey: "ANOTHER-KEY") == false)
        let url = try #require(URL(string: "starcat://license/activate?license_key=NEW-KEY"))
        #expect(await manager.activateFromPaymentSuccessURL(url) == false)
        #expect(URLProtocolStub.receivedRequests.count == 1)

        now = now.addingTimeInterval(59.5)
        #expect(manager.activationRetrySeconds() == 1)
        #expect(await manager.activate(licenseKey: "NEW-KEY") == false)
        #expect(URLProtocolStub.receivedRequests.count == 1)
        now = now.addingTimeInterval(0.5)
        #expect(manager.activationRetrySeconds() == 0)
        // 经过截止时间不会产生自动重试；下一次明确的手动激活才允许出站。
        #expect(URLProtocolStub.receivedRequests.count == 1)
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status": "active", "provider": "creem", "plan": "monthly",
              "productID": "prod_monthly", "instanceID": "inst_new",
              "validatedAt": "2026-11-10T00:00:00Z"
            }
            """)
        }
        #expect(await manager.activate(licenseKey: "NEW-KEY"))
        #expect(URLProtocolStub.receivedRequests.count == 2)
        #expect(manager.activationRetryAfter == nil)
        #expect(manager.lastErrorMessage == nil)
        #expect(try store.loadCredential()?.licenseKey == "NEW-KEY")
    }

    @Test("后台校验限流保留凭据与 Pro，记录统一诊断码")
    func validationRateLimitPreservesStoredPro() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"code":"RATE_LIMITED"}"#.utf8))
        }
        let store = try Self.seededStore(plan: .monthly)
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store)
        #expect(await manager.validateStoredLicense())
        #expect(manager.entitlement.isActive)
        #expect(try store.loadCredential() != nil)
        #expect(manager.validationRecord.lastErrorCode == "rate_limit_reached")
        #expect(manager.activationRetryAfter == nil)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("未知上游故障与路由 404 不撤销已保存的 Pro", arguments: [502, 403, 404])
    func unknownUpstreamFailuresPreserveStoredPro(status: Int) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"PROVIDER_ERROR","message":"SENSITIVE-LICENSE-KEY"}"#.utf8))
        }
        let store = try Self.seededStore(plan: .monthly)
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store)

        let result = await manager.validateStoredLicense()

        #expect(result)
        #expect(manager.entitlement.isActive)
        #expect(try store.loadCredential() != nil)
        #expect(manager.validationRecord.lastErrorCode?.contains("SENSITIVE-LICENSE-KEY") == false)
    }

    @Test("明确的授权码不存在业务错误撤销已保存的 Pro")
    func missingLicenseBusinessErrorRevokesStoredPro() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"LICENSE_NOT_FOUND"}"#.utf8))
        }
        let store = try Self.seededStore(plan: .monthly)
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store)

        let result = await manager.validateStoredLicense()

        #expect(!result)
        #expect(!manager.entitlement.isActive)
        #expect(manager.runtimeState == .revoked)
        #expect(try store.loadCredential() == nil)
        #expect(manager.lastErrorMessage == String.l10n("settings.pro.direct.error.licenseNotFound"))
    }

    @Test("网络错误使用本地化提示，不暴露底层请求内容")
    func transportFailureUsesLocalizedMessage() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await Self.testAPI().activate(DirectLicenseActivationRequest(licenseKey: "KEY", deviceID: "Mac", appVersion: "1.8.0"))
            Issue.record("Expected transport failure")
        } catch let error as DirectLicenseAPIError {
            #expect(error == .transport(code: URLError.notConnectedToInternet.rawValue))
            #expect(error.errorDescription == String.l10n("settings.pro.direct.error.transport"))
            #expect(error.preservesLocalEntitlement)
        }
    }

    @Test("诊断仅接受固定 code 与 UUID trace，不采信原始消息")
    func diagnosticsRejectSensitiveServerFields() {
        #expect(DirectLicenseAPIError.safeServerCode("SENSITIVE-LICENSE-KEY") == nil)
        #expect(DirectLicenseAPIError.safeServerCode("License key not found") == nil)
        #expect(DirectLicenseAPIError.temporaryServerFailure(statusCode: 502, code: "SECRET").diagnosticCode == "http_502")
        #expect(DirectLicenseAPIError.safeTraceID("SENSITIVE-LICENSE-KEY\nFORGED-LOG") == nil)
        #expect(DirectLicenseAPIError.safeTraceID("customer@example.com") == nil)
        #expect(DirectLicenseAPIError.safeTraceID("550E8400-E29B-41D4-A716-446655440000") == "550e8400-e29b-41d4-a716-446655440000")
    }

    @Test("正常激活保存完整凭据，恢复 Pro 并清除之前的失败提示")
    func successfulActivationPersistsCredentialAndClearsError() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: #"{"status":"active","provider":"creem"}"#)
        }
        let store = DirectLicenseStore(keychain: InMemoryKeychain())
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store, deviceIDProvider: { "Mac" })
        #expect(await manager.activate(licenseKey: "TEST-KEY") == false)
        #expect(manager.lastErrorMessage != nil)
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status":"active", "provider":"creem", "plan":"lifetime",
              "productID":"prod_lifetime", "instanceID":"inst_new",
              "activationUsed":1, "activationLimit":3,
              "validatedAt":"2026-11-10T00:00:00.123456789Z"
            }
            """)
        }
        #expect(await manager.activate(licenseKey: " TEST-KEY ", subscriptionID: "sub_new"))
        let saved = try #require(try store.loadCredential())
        #expect(saved.licenseKey == "TEST-KEY")
        #expect(saved.instanceID == "inst_new")
        #expect(saved.productID == "prod_lifetime")
        #expect(saved.plan == .lifetime)
        #expect(saved.subscriptionID == "sub_new")
        #expect(manager.storedCredential == saved)
        #expect(manager.entitlement.isActive)
        #expect(manager.runtimeState == .verifiedActive)
        #expect(manager.lastSnapshot?.instanceID == "inst_new")
        #expect(manager.lastErrorMessage == nil)
        #expect(!manager.isActivating)
        #expect(URLProtocolStub.receivedRequests.count == 2)
    }

    @Test("激活解码失败显示安全提示，保留已有权益且不保存新授权", arguments: [false, true])
    func activationDecodingFailureKeepsPreviousState(hasCredential: Bool) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {"status":"active","provider":"creem","instanceID":"inst_new","validatedAt":"SENSITIVE-LICENSE-KEY"}
            """)
        }
        let store = try hasCredential ? Self.seededStore(plan: .monthly) : DirectLicenseStore(keychain: InMemoryKeychain())
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store, deviceIDProvider: { "Mac" })
        let previous = manager.storedCredential
        let previousEntitlement = manager.entitlement
        let previousState = manager.runtimeState

        #expect(await manager.activate(licenseKey: "SENSITIVE-LICENSE-KEY") == false)
        #expect(manager.lastErrorMessage == String.l10n("settings.pro.direct.error.responseDecodingFailed"))
        #expect(manager.lastErrorMessage?.contains("SENSITIVE-LICENSE-KEY") == false)
        #expect(manager.storedCredential == previous)
        #expect(try store.loadCredential() == previous)
        #expect(manager.entitlement == previousEntitlement)
        #expect(manager.runtimeState == previousState)
        #expect(manager.lastSnapshot == nil)
        #expect(!manager.isActivating)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("远端成功但本机写入失败时提示保存失败，不授予未保存的 Pro")
    func activationSaveFailureIsReportedSafely() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            Self.jsonResponse(for: request, body: """
            {
              "status":"active", "provider":"creem", "plan":"lifetime",
              "instanceID":"inst_new", "validatedAt":"2026-11-10T00:00:00Z"
            }
            """)
        }
        let store = DirectLicenseStore(keychain: InMemoryKeychain(rejectsServiceKeyWrites: true))
        // 固定设备名称，确保失败发生在远端成功后的凭据保存，而非安装 ID 初始化。
        let manager = DirectLicenseManager(api: Self.testAPI(), store: store, deviceIDProvider: { "Mac" })
        #expect(await manager.activate(licenseKey: "SENSITIVE-LICENSE-KEY") == false)
        #expect(manager.lastErrorMessage == String.l10n("settings.pro.direct.error.credentialSaveFailed"))
        #expect(manager.lastErrorMessage?.contains("SENSITIVE-LICENSE-KEY") == false)
        #expect(manager.storedCredential == nil)
        #expect(try store.loadCredential() == nil)
        #expect(manager.entitlement == .inactive)
        #expect(manager.runtimeState == .none)
        #expect(manager.lastSnapshot == nil)
        #expect(!manager.isActivating)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("保存诊断只记录固定类别和系统域及码，不输出凭据或文件路径")
    func credentialSaveDiagnosticRedactsErrorDetails() {
        let underlying = NSError(
            domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "SENSITIVE-LICENSE-KEY", NSFilePathErrorKey: "/private/customer"]
        )
        #expect(DirectLicenseActivationError.storageDiagnostic(KeychainError.writeFailed(underlying: underlying))
            == "reason=write_failed error_domain=NSCocoaErrorDomain error_code=513")
        #expect(DirectLicenseActivationError.storageDiagnostic(KeychainError.encryptionFailed(underlying: underlying))
            == "reason=encryption_failed error_domain=NSCocoaErrorDomain error_code=513")
        #expect(DirectLicenseActivationError.storageDiagnostic(KeychainError.deleteFailed(underlying: underlying))
            == "reason=delete_failed error_domain=NSCocoaErrorDomain error_code=513")
        let custom = NSError(domain: "SENSITIVE-LICENSE-KEY\nFORGED-LOG", code: 42, userInfo: underlying.userInfo)
        #expect(DirectLicenseActivationError.storageDiagnostic(custom)
            == "reason=other error_domain=other error_code=42")
        #expect(DirectLicenseActivationError.credentialSaveFailed.diagnosticCode == "credential_save_failed")
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
