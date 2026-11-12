//
//  OfferCodeRedemptionTests.swift
//  StarcatTests
//
//  兑换结果回归：用户取消不得显示错误，失败不得当作成功，旧系统须刷新有效权益。
//

import Foundation
import StoreKit
import Testing
@testable import Starcat

/// 只测试权益协调与错误处理，不展示系统面板、不连接真实 App Store 或修改用户配置。
@MainActor
@Suite("OfferCodeRedemption")
struct OfferCodeRedemptionTests {
    @Test("取消兑换清理旧错误且不触发激活回调", arguments: [
        StoreKitError.userCancelled as any Error,
        CancellationError(),
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
        NSError(domain: SKErrorDomain, code: SKError.Code.paymentCancelled.rawValue)
    ])
    func cancellationClearsPreviousError(_ error: any Error) async throws {
        let (manager, defaultsDomain) = try makeManager()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        _ = await manager.handleOfferCodeRedemptionResult(.failure(URLError(.notConnectedToInternet)))
        #expect(manager.lastErrorMessage != nil)

        let activated = await manager.handleOfferCodeRedemptionResult(.failure(error))

        #expect(!activated)
        #expect(manager.lastErrorMessage == nil)
    }

    @Test("面板展示失败保留用户可读错误且不激活")
    func presentationFailureDoesNotActivate() async throws {
        let (manager, defaultsDomain) = try makeManager()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }

        let activated = await manager.handleOfferCodeRedemptionResult(
            .failure(URLError(.notConnectedToInternet))
        )

        #expect(!activated)
        #expect(manager.lastErrorMessage == SubscriptionError.offerCodeRedemptionFailed.localizedDescription)
    }

    @Test("其他错误域的相同错误码不能被当作取消")
    func unrelatedErrorCodeIsNotCancellation() async throws {
        let (manager, defaultsDomain) = try makeManager()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }

        let activated = await manager.handleOfferCodeRedemptionResult(
            .failure(NSError(domain: "OfferCodeRedemptionTests", code: NSUserCancelledError))
        )

        #expect(!activated)
        #expect(manager.lastErrorMessage != nil)
    }

    @Test("旧系统关闭面板后重新读取权益并清理旧错误")
    func legacyCompletionRefreshesEntitlements() async throws {
        let (manager, defaultsDomain) = try makeManager()
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        _ = await manager.handleOfferCodeRedemptionResult(.failure(URLError(.notConnectedToInternet)))

        let activated = await manager.handleOfferCodeRedemptionResult(.success(nil))

        // 测试 host 的有效权益由 TestEnvironment 提供，这里不伪造 StoreKit 交易。
        #expect(activated)
        #expect(manager.entitlement.source == .testEnvironment)
        #expect(manager.lastErrorMessage == nil)
    }

    /// 隔离 UserDefaults 与 Keychain，禁止启动真实的交易监听。
    private func makeManager() throws -> (SubscriptionManager, String) {
        let defaultsDomain = "OfferCodeRedemptionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        return (SubscriptionManager(settings: settings, startTransactionListener: false), defaultsDomain)
    }
}
