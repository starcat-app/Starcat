//
//  SubscriptionManager.swift
//  Starcat
//
//  StoreKit 2 订阅协调器。
//

import Foundation
import Observation
import StoreKit

/// StoreKit 2 订阅协调器。
///
/// 设计边界：
/// - 本类是 Pro 订阅状态唯一真相源，业务代码不得直接遍历 `Transaction.currentEntitlements`；
/// - AppSettings 只保留 `isProUser` 只读镜像，便于头像徽章等轻量 UI 继续工作；
/// - v1 不做 App Store Server API 校验，原因记录在
///   `docs/StoreKit订阅实施决策记录.md`。后续如果服务端要按订阅放行自建 AI 代理，
///   可在本类刷新后追加远端同步，不需要改业务门控。
@MainActor
@Observable
final class SubscriptionManager: ProEntitlementProviding {

    private let productIDs: [String]
    private let settings: AppSettings
    private var updatesTask: Task<Void, Never>?

    private(set) var products: [Product] = []
    private(set) var entitlement: ProEntitlement = .inactive {
        didSet {
            settings.updateProEntitlementMirror(isPro: entitlement.isActive)
        }
    }
    private(set) var isLoadingProducts: Bool = false
    private(set) var isPurchasing: Bool = false
    private(set) var isRestoring: Bool = false
    private(set) var lastErrorMessage: String?

    init(
        settings: AppSettings,
        productIDs: [String] = ProProductID.allIDs,
        startTransactionListener: Bool = true
    ) {
        self.settings = settings
        self.productIDs = productIDs

        if TestEnvironment.isRunning {
            entitlement = .testEnvironment
            settings.updateProEntitlementMirror(isPro: true)
            return
        }

        if startTransactionListener {
            start()
        }
    }

    /// 启动订阅监听与首轮刷新。
    ///
    /// AppDependencies 构造期调用即可；内部幂等，避免 Settings scene 重建时重复监听。
    func start() {
        guard updatesTask == nil, !TestEnvironment.isRunning else { return }
        updatesTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlements()
            await self.loadProducts()
            await self.listenForTransactionUpdates()
        }
    }

    /// 从 App Store / `.storekit` 读取商品元数据。
    ///
    /// 价格、币种、订阅周期均以 StoreKit 返回为准；Connect 后台调整价格后，代码无需改。
    func loadProducts() async {
        guard !TestEnvironment.isRunning else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: productIDs)
            products = loaded.sorted {
                ProProductID.sortOrder(for: $0.id) < ProProductID.sortOrder(for: $1.id)
            }
            if products.isEmpty {
                lastErrorMessage = SubscriptionError.productsUnavailable.localizedDescription
            } else {
                lastErrorMessage = nil
            }
        } catch {
            lastErrorMessage = SubscriptionError.unknown(error.localizedDescription).localizedDescription
            AppLog.general.error("[subscription] loadProducts failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 购买指定商品。返回 true 表示购买已验证并激活权益。
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard !TestEnvironment.isRunning else {
            entitlement = .testEnvironment
            return true
        }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verifiedTransaction(from: verification)
                await transaction.finish()
                await refreshEntitlements()
                lastErrorMessage = nil
                return entitlement.isActive
            case .pending:
                lastErrorMessage = SubscriptionError.purchasePending.localizedDescription
                return false
            case .userCancelled:
                lastErrorMessage = SubscriptionError.purchaseCancelled.localizedDescription
                return false
            @unknown default:
                lastErrorMessage = SubscriptionError.unknown("Unknown purchase result").localizedDescription
                return false
            }
        } catch let error as SubscriptionError {
            lastErrorMessage = error.localizedDescription
            return false
        } catch {
            lastErrorMessage = SubscriptionError.unknown(error.localizedDescription).localizedDescription
            AppLog.general.error("[subscription] purchase failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 主动恢复购买。
    ///
    /// `AppStore.sync()` 会触发 StoreKit 与 App Store 同步交易；完成后再读
    /// `currentEntitlements`，保证 UI 状态与最新交易一致。
    func restorePurchases() async {
        guard !TestEnvironment.isRunning else {
            entitlement = .testEnvironment
            return
        }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            lastErrorMessage = entitlement.isActive ? nil : SubscriptionError.restoreFailed.localizedDescription
        } catch {
            lastErrorMessage = SubscriptionError.restoreFailed.localizedDescription
            AppLog.general.error("[subscription] restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 重新计算当前有效权益。
    ///
    /// `Transaction.currentEntitlements` 只返回当前仍授予权益的交易，但这里仍显式检查
    /// product ID、revocation 和 expiration，避免未来新增商品时误把非 Pro 商品当成 Pro。
    func refreshEntitlements() async {
        guard !TestEnvironment.isRunning else {
            entitlement = .testEnvironment
            return
        }

        var best: Transaction?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verifiedTransaction(from: result),
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  isTransactionActive(transaction) else { continue }

            if let current = best {
                if (transaction.expirationDate ?? .distantFuture) > (current.expirationDate ?? .distantFuture) {
                    best = transaction
                }
            } else {
                best = transaction
            }
        }

        if let best {
            entitlement = ProEntitlement(
                isActive: true,
                productID: best.productID,
                expirationDate: best.expirationDate,
                verifiedAt: Date(),
                source: .storeKit
            )
        } else {
            entitlement = .inactive
        }
    }

    /// 处理 `offerCodeRedemption` sheet 关闭后的结果并刷新 Pro 权益。
    @MainActor
    func handleOfferCodeRedemptionResult(_ result: Result<Void, Error>) async -> Bool {
        switch result {
        case .success:
            await refreshEntitlements()
            if entitlement.isActive {
                lastErrorMessage = nil
                return true
            }
            return false
        case .failure(let error):
            if Self.isUserCancelledOfferCodeError(error) {
                lastErrorMessage = nil
            } else {
                lastErrorMessage = SubscriptionError.offerCodeRedemptionFailed.localizedDescription
                AppLog.general.error("[subscription] offer code redemption failed: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    private static func isUserCancelledOfferCodeError(_ error: Error) -> Bool {
        if let storeKit = error as? StoreKitError, case .userCancelled = storeKit {
            return true
        }
        return (error as NSError).code == NSUserCancelledError
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            do {
                let transaction = try verifiedTransaction(from: result)
                await transaction.finish()
                await refreshEntitlements()
            } catch {
                lastErrorMessage = SubscriptionError.unverifiedTransaction.localizedDescription
                AppLog.general.error("[subscription] transaction update rejected: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func verifiedTransaction(from result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            AppLog.general.error("[subscription] unverified transaction: \(error.localizedDescription, privacy: .public)")
            throw SubscriptionError.unverifiedTransaction
        }
    }

    private func isTransactionActive(_ transaction: Transaction) -> Bool {
        guard transaction.revocationDate == nil else { return false }
        if let expiration = transaction.expirationDate {
            return expiration > Date()
        }
        return true
    }
}
