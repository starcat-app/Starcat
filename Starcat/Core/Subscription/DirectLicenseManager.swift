//
//  DirectLicenseManager.swift
//  Starcat
//
//  Direct License 权益管理器。
//

import Foundation

/// Direct 渠道授权管理器。
///
/// 当前先落抽象和 API 对接能力，UI 激活入口可在后续迭代接入设置页。这里保持为
/// `ProEntitlementProviding`，让 `CompositeProEntitlementProvider` 可以把 Direct License
/// 与 StoreKit 权益自然合并。
@MainActor
@Observable
final class DirectLicenseManager: ProEntitlementProviding {
    private let api: DirectLicenseAPI
    private let store: DirectLicenseStore
    private let appVersionProvider: @MainActor () -> String
    private let deviceIDProvider: @MainActor () -> String

    private(set) var storedCredential: DirectLicenseCredential?
    private(set) var entitlement: ProEntitlement = .inactive {
        didSet {
            if oldValue != entitlement {
                onEntitlementDidChange?()
            }
        }
    }
    private(set) var lastSnapshot: DirectLicenseSnapshot?
    private(set) var lastSubscriptionSnapshot: DirectSubscriptionSnapshot?
    private(set) var lastErrorMessage: String?
    private(set) var isRequestInFlight = false

    var onEntitlementDidChange: (@MainActor () -> Void)?

    init(
        api: DirectLicenseAPI = DirectLicenseAPI(),
        store: DirectLicenseStore = DirectLicenseStore(),
        appVersionProvider: @escaping @MainActor () -> String = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" },
        deviceIDProvider: @escaping @MainActor () -> String = { AppConstants.bundleIdentifier }
    ) {
        self.api = api
        self.store = store
        self.appVersionProvider = appVersionProvider
        self.deviceIDProvider = deviceIDProvider
        self.storedCredential = try? store.loadCredential()
    }

    @discardableResult
    func activate(
        licenseKey: String,
        subscriptionID: String? = nil,
        customerID: String? = nil,
        productID: String? = nil
    ) async -> Bool {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return await perform { [store] in
            let snapshot = try await api.activate(DirectLicenseActivationRequest(
                licenseKey: trimmed,
                deviceID: deviceIDProvider(),
                appVersion: appVersionProvider()
            ))
            if snapshot.status.grantsPro, let instanceID = snapshot.instanceID {
                let previous = storedCredential ?? (try? store.loadCredential())
                let credential = DirectLicenseCredential(
                    licenseKey: trimmed,
                    instanceID: instanceID,
                    subscriptionID: directLicenseTrimmed(subscriptionID) ?? previous?.subscriptionID,
                    customerID: directLicenseTrimmed(customerID) ?? previous?.customerID,
                    productID: directLicenseTrimmed(productID) ?? snapshot.productID ?? previous?.productID
                )
                try store.storeCredential(credential)
                storedCredential = credential
            }
            return snapshot
        }
    }

    /// 处理支付成功页 deep link 带回的授权信息。
    ///
    /// Creem 的 license validate 不返回 subscription id，所以取消月订阅依赖成功页在
    /// 首次回跳时把 `subscription_id` 交给客户端保存。Lifetime checkout 没有
    /// subscription id 时保留旧月订阅 id，方便用户升级后立刻取消续费。
    @discardableResult
    func activateFromPaymentSuccessURL(_ url: URL) async -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let licenseKey = components.queryItemValue("license_key")
        else {
            lastErrorMessage = DirectLicenseAPIError.invalidResponse.localizedDescription
            return false
        }
        return await activate(
            licenseKey: licenseKey,
            subscriptionID: components.queryItemValue("subscription_id"),
            customerID: components.queryItemValue("customer_id"),
            productID: components.queryItemValue("product_id")
        )
    }

    @discardableResult
    func validateStoredLicense() async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()) else { return false }
        return await perform {
            try await api.validate(DirectLicenseValidationRequest(
                licenseKey: credential.licenseKey,
                instanceID: credential.instanceID,
                deviceID: deviceIDProvider(),
                appVersion: appVersionProvider()
            ))
        }
    }

    @discardableResult
    func deactivateStoredLicense() async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()) else { return false }
        let didRemainActive = await perform {
            let snapshot = try await api.deactivate(DirectLicenseDeactivationRequest(
                licenseKey: credential.licenseKey,
                instanceID: credential.instanceID,
                deviceID: deviceIDProvider()
            ))
            try? store.deleteCredential()
            storedCredential = nil
            return snapshot
        }
        return didRemainActive
    }

    @discardableResult
    func cancelStoredMonthlySubscription() async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()),
              let subscriptionID = directLicenseTrimmed(credential.subscriptionID)
        else {
            lastErrorMessage = String.l10n("settings.pro.direct.cancel.missingSubscription")
            return false
        }

        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            // 取消使用 period-end 预约模式，避免用户刚付款就立即失去本期权益。
            let snapshot = try await api.cancelSubscription(DirectCancelSubscriptionRequest(
                subscriptionID: subscriptionID,
                mode: "scheduled",
                onExecute: "cancel"
            ))
            lastSubscriptionSnapshot = snapshot
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] cancel subscription failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 创建官网 Direct checkout URL。
    ///
    /// 这里不把 Creem product id 传给客户端，只传稳定 plan alias；真实 SKU 映射由
    /// `starcat-license-api` 读取环境变量完成，后续调价或更换支付平台不需要发新版 App。
    func createCheckoutURL(for plan: DirectCheckoutPlan) async -> URL? {
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let response = try await api.checkout(DirectCheckoutRequest(
                plan: plan,
                customerEmail: nil,
                successURL: nil,
                requestID: UUID().uuidString
            ))
            guard let url = URL(string: response.url) else {
                lastErrorMessage = DirectLicenseAPIError.invalidResponse.localizedDescription
                return nil
            }
            lastErrorMessage = nil
            return url
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] checkout failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func clearStoredCredential() {
        try? store.deleteCredential()
        storedCredential = nil
        lastSnapshot = nil
        lastSubscriptionSnapshot = nil
        entitlement = .inactive
    }

    private func perform(_ operation: () async throws -> DirectLicenseSnapshot) async -> Bool {
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let snapshot = try await operation()
            lastSnapshot = snapshot
            entitlement = snapshot.proEntitlement()
            lastErrorMessage = nil
            return entitlement.isActive
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

private extension URLComponents {
    func queryItemValue(_ name: String) -> String? {
        directLicenseTrimmed(queryItems?.first(where: { $0.name == name })?.value)
    }
}

private func directLicenseTrimmed(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
