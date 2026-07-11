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
    private let nowProvider: @MainActor () -> Date

    private(set) var storedCredential: DirectLicenseCredential?
    private(set) var validationRecord: DirectLicenseValidationRecord = .empty
    private(set) var runtimeState: DirectLicenseRuntimeState = .none
    private(set) var entitlement: ProEntitlement = .inactive {
        didSet {
            if oldValue != entitlement {
                onEntitlementDidChange?()
            }
        }
    }
    private(set) var lastSnapshot: DirectLicenseSnapshot?
    private(set) var lastSubscriptionSnapshot: DirectSubscriptionSnapshot?
    private(set) var licenseDevices: [DirectLicenseDevice] = []
    private(set) var lastErrorMessage: String?
    private(set) var isRequestInFlight = false

    var onEntitlementDidChange: (@MainActor () -> Void)?

    init(
        api: DirectLicenseAPI = DirectLicenseAPI(),
        store: DirectLicenseStore = DirectLicenseStore(),
        appVersionProvider: @escaping @MainActor () -> String = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" },
        deviceIDProvider: @escaping @MainActor () -> String = { DirectLicenseManager.defaultDeviceName(store: DirectLicenseStore()) },
        nowProvider: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.api = api
        self.store = store
        self.appVersionProvider = appVersionProvider
        self.deviceIDProvider = deviceIDProvider
        self.nowProvider = nowProvider
        self.storedCredential = try? store.loadCredential()
        self.validationRecord = (try? store.loadValidationRecord()) ?? .empty
        self.runtimeState = validationRecord.runtimeState
        if let credential = storedCredential, validationRecord.lastRemoteStatus?.grantsPro != false {
            // 冷启动必须优先相信本机已保存的授权凭据，让 Pro 标识和功能门控立即恢复。
            // 远程 validate 会在启动后异步执行；若服务端明确返回 expired/revoked，
            // validate 路径会再把 entitlement 收回。这样避免用户每次启动都等网络后才看到 Pro。
            self.runtimeState = validationRecord.runtimeState == .verifiedActive ? .verifiedActive : .localActive
            self.entitlement = ProEntitlement(
                isActive: true,
                productID: credential.productID,
                expirationDate: nil,
                verifiedAt: nil,
                source: .directLicense
            )
        }
    }

    @discardableResult
    func activate(
        licenseKey: String,
        subscriptionID: String? = nil,
        customerID: String? = nil,
        productID: String? = nil,
        plan: DirectCheckoutPlan? = nil
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
                    productID: directLicenseTrimmed(productID) ?? snapshot.productID ?? previous?.productID,
                    plan: plan ?? previous?.plan
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
            productID: components.queryItemValue("product_id"),
            plan: components.queryItemValue("plan").flatMap(DirectCheckoutPlan.init(rawValue:))
        )
    }

    @discardableResult
    func validateStoredLicense() async -> Bool {
        await validateStoredLicense(force: true, isSilent: false)
    }

    @discardableResult
    func validateStoredLicenseIfNeeded() async -> Bool {
        guard shouldValidateStoredLicense() else { return entitlement.isActive }
        return await validateStoredLicense(force: true, isSilent: true)
    }

    private func validateStoredLicense(force: Bool, isSilent: Bool) async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()) else { return false }
        if !force, !shouldValidateStoredLicense() {
            return entitlement.isActive
        }

        isRequestInFlight = true
        defer { isRequestInFlight = false }

        updateValidationRecord { record in
            record.plan = credential.plan ?? record.plan
            record.lastAttemptAt = nowProvider()
            record.lastErrorCode = nil
        }

        do {
            let snapshot = try await api.validate(DirectLicenseValidationRequest(
                licenseKey: credential.licenseKey,
                instanceID: credential.instanceID,
                deviceID: deviceIDProvider(),
                appVersion: appVersionProvider()
            ))
            applyValidatedSnapshot(snapshot, credential: credential)
            lastErrorMessage = nil
            return entitlement.isActive
        } catch {
            applyValidationFailure(error, isSilent: isSilent)
            return entitlement.isActive
        }
    }

    @discardableResult
    func deactivateStoredLicense() async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()) else { return false }
        return await deactivateLicenseDevice(instanceID: credential.instanceID)
    }

    @discardableResult
    func refreshLicenseDevices() async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()) else { return false }
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let snapshot = try await api.devices(DirectLicenseDevicesRequest(
                licenseKey: credential.licenseKey,
                instanceID: credential.instanceID,
                deviceID: deviceIDProvider()
            ))
            applyValidatedSnapshot(snapshot, credential: credential)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] refresh devices failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func deactivateLicenseDevice(instanceID: String) async -> Bool {
        guard let credential = storedCredential ?? (try? store.loadCredential()),
              let targetInstanceID = directLicenseTrimmed(instanceID)
        else { return false }

        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let snapshot = try await api.deactivate(DirectLicenseDeactivationRequest(
                licenseKey: credential.licenseKey,
                instanceID: targetInstanceID,
                deviceID: deviceIDProvider()
            ))
            lastSnapshot = snapshot
            licenseDevices = snapshot.devices ?? licenseDevices.filter { $0.instanceID != targetInstanceID }
            lastErrorMessage = nil

            if targetInstanceID == credential.instanceID {
                try? store.deleteCredential()
                storedCredential = nil
                validationRecord = .empty
                runtimeState = .none
                entitlement = .inactive
                licenseDevices = []
            }
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] deactivate device failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
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

    /// 创建 Creem customer portal URL。
    ///
    /// 客户端只把支付成功页保存下来的 `customerID` 交给 Starcat License API；真正的
    /// Creem API Key 和 portal 创建逻辑仍留在服务端。没有 `customerID` 时不猜测邮箱，
    /// 避免在本机缺少订单上下文时误打开错误客户的账单页。
    func createCustomerPortalURL() async -> URL? {
        guard let credential = storedCredential ?? (try? store.loadCredential()),
              let customerID = directLicenseTrimmed(credential.customerID)
        else {
            lastErrorMessage = String.l10n("settings.pro.direct.portal.missingCustomer")
            return nil
        }

        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let response = try await api.customerPortal(DirectCustomerPortalRequest(
                customerID: customerID,
                email: nil
            ))
            guard let url = URL(string: response.url) else {
                lastErrorMessage = DirectLicenseAPIError.invalidResponse.localizedDescription
                return nil
            }
            lastErrorMessage = nil
            return url
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] customer portal failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func clearStoredCredential() {
        try? store.deleteCredential()
        storedCredential = nil
        lastSnapshot = nil
        lastSubscriptionSnapshot = nil
        licenseDevices = []
        validationRecord = .empty
        runtimeState = .none
        entitlement = .inactive
    }

    private func perform(_ operation: () async throws -> DirectLicenseSnapshot) async -> Bool {
        isRequestInFlight = true
        defer { isRequestInFlight = false }

        do {
            let snapshot = try await operation()
            lastSnapshot = snapshot
            entitlement = snapshot.proEntitlement()
            runtimeState = snapshot.status.grantsPro ? .verifiedActive : state(for: snapshot.status)
            updateValidationRecord { record in
                record.runtimeState = runtimeState
                record.lastRemoteStatus = snapshot.status
                record.lastSuccessAt = nowProvider()
                record.lastErrorCode = nil
            }
            lastErrorMessage = nil
            return entitlement.isActive
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.general.error("[direct-license] request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func shouldValidateStoredLicense() -> Bool {
        let referenceDate = validationRecord.lastAttemptAt ?? validationRecord.lastSuccessAt
        guard let referenceDate else { return true }
        return nowProvider().timeIntervalSince(referenceDate) >= validationInterval
    }

    private var validationInterval: TimeInterval {
        switch storedCredential?.plan ?? validationRecord.plan {
        case .lifetime:
            return 7 * 24 * 60 * 60
        case .monthly, .yearly, .none:
            return 24 * 60 * 60
        }
    }

    private func applyValidatedSnapshot(_ snapshot: DirectLicenseSnapshot, credential: DirectLicenseCredential) {
        lastSnapshot = snapshot
        licenseDevices = snapshot.devices ?? licenseDevices
        updateValidationRecord { record in
            record.plan = credential.plan ?? record.plan
            record.runtimeState = snapshot.status.grantsPro ? .verifiedActive : state(for: snapshot.status)
            record.lastSuccessAt = nowProvider()
            record.lastFailureAt = nil
            record.lastErrorCode = nil
            record.lastRemoteStatus = snapshot.status
        }

        if snapshot.status.grantsPro {
            runtimeState = .verifiedActive
            entitlement = snapshot.proEntitlement()
            return
        }

        // 只有服务端明确返回非 active 状态时才收回本地 Pro；网络失败不会走到这里。
        runtimeState = state(for: snapshot.status)
        storedCredential = nil
        try? store.deleteCredential()
        entitlement = .inactive
    }

    private func applyValidationFailure(_ error: Error, isSilent: Bool) {
        let apiError = error as? DirectLicenseAPIError
        let shouldPreserveEntitlement = apiError?.preservesLocalEntitlement ?? true
        let diagnosticCode = apiError?.diagnosticCode ?? "unknown_validation_error"

        updateValidationRecord { record in
            record.lastFailureAt = nowProvider()
            record.lastErrorCode = diagnosticCode
            if shouldPreserveEntitlement, entitlement.isActive {
                record.runtimeState = runtimeState == .verifiedActive ? .verifiedActive : .localActive
            }
        }

        if shouldPreserveEntitlement {
            if entitlement.isActive, runtimeState != .verifiedActive {
                runtimeState = .localActive
            }
            if !isSilent {
                lastErrorMessage = error.localizedDescription
            }
            AppLog.general.error("[direct-license] validation preserved local entitlement after failure: \(diagnosticCode, privacy: .public)")
            return
        }

        runtimeState = .revoked
        storedCredential = nil
        try? store.deleteCredential()
        entitlement = .inactive
        if !isSilent {
            lastErrorMessage = error.localizedDescription
        }
        AppLog.general.error("[direct-license] validation revoked local entitlement: \(diagnosticCode, privacy: .public)")
    }

    private func updateValidationRecord(_ mutate: (inout DirectLicenseValidationRecord) -> Void) {
        var record = validationRecord
        mutate(&record)
        validationRecord = record
        runtimeState = record.runtimeState
        try? store.storeValidationRecord(record)
    }

    private func state(for status: DirectLicenseStatus) -> DirectLicenseRuntimeState {
        switch status {
        case .active:
            return .verifiedActive
        case .expired:
            return .expired
        case .revoked, .inactive:
            return .revoked
        }
    }

    private static func defaultDeviceName(store: DirectLicenseStore) -> String {
        let hostName = directLicenseTrimmed(Host.current().localizedName) ?? "Mac"
        let installID = (try? store.loadOrCreateInstallID()) ?? UUID().uuidString
        return "\(hostName) · Starcat \(installID.prefix(4).uppercased())"
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
