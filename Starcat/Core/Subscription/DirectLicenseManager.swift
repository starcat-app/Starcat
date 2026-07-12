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

    // 各操作独立 in-flight：UI loading 只绑自己的标志，避免门户请求把设备区/解绑一起转圈。
    private(set) var isActivating = false
    private(set) var isValidating = false
    private(set) var isRefreshingDevices = false
    private(set) var isDeactivating = false
    private(set) var isCancellingSubscription = false
    private(set) var isCreatingCheckout = false
    private(set) var isOpeningPortal = false

    /// 任意 Direct License 请求进行中（表单互斥禁用用，不直接驱动某个按钮 spinner）。
    var isRequestInFlight: Bool {
        isActivating
            || isValidating
            || isRefreshingDevices
            || isDeactivating
            || isCancellingSubscription
            || isCreatingCheckout
            || isOpeningPortal
    }

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
        subscriptionID: String? = nil
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
                    productID: snapshot.productID,
                    plan: snapshot.plan
                )
                try store.storeCredential(credential)
                storedCredential = credential
            }
            return snapshot
        }
    }

    /// 处理支付成功页 deep link 带回的授权信息。
    ///
    /// Deep link 只负责把用户从支付成功页带回 App。套餐与 product id 必须来自
    /// 后端对 Creem License API 的 activate/validate 结果，不能信任 URL 查询参数。
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
            subscriptionID: components.queryItemValue("subscription_id")
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

        isValidating = true
        defer { isValidating = false }

        updateValidationRecord { record in
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
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }

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

        isDeactivating = true
        defer { isDeactivating = false }

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
                // 当前 Mac 已从远端实例列表移除，不能保留这张许可证的任何本机展示快照；
                // 否则通行证会继续显示旧尾号，且重启后验证记录还会带回旧套餐信息。
                clearStoredCredential()
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

        isCancellingSubscription = true
        defer { isCancellingSubscription = false }

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
        isCreatingCheckout = true
        defer { isCreatingCheckout = false }

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
    /// 授权码和当前实例先由服务端重新校验，再从已验签 checkout 关联到 Customer Portal。
    /// 因而用户手动输入授权码激活也可管理账单，客户端无需相信或保存 deep link 的客户信息。
    func createCustomerPortalURL() async -> URL? {
        guard let credential = storedCredential ?? (try? store.loadCredential()) else {
            lastErrorMessage = String.l10n("settings.pro.direct.portal.missingCustomer")
            return nil
        }

        isOpeningPortal = true
        defer { isOpeningPortal = false }

        do {
            let response = try await api.customerPortal(DirectCustomerPortalRequest(
                licenseKey: credential.licenseKey,
                instanceID: credential.instanceID
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
        // 验证记录也属于当前许可证的本机状态，必须持久化清空，避免下次启动恢复旧套餐。
        try? store.storeValidationRecord(.empty)
        storedCredential = nil
        lastSnapshot = nil
        lastSubscriptionSnapshot = nil
        licenseDevices = []
        validationRecord = .empty
        runtimeState = .none
        entitlement = .inactive
    }

    private func perform(_ operation: () async throws -> DirectLicenseSnapshot) async -> Bool {
        isActivating = true
        defer { isActivating = false }

        do {
            let snapshot = try await operation()
            lastSnapshot = snapshot
            entitlement = snapshot.proEntitlement()
            runtimeState = snapshot.status.grantsPro ? .verifiedActive : state(for: snapshot.status)
            updateValidationRecord { record in
                record.plan = snapshot.plan
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
            record.plan = snapshot.plan
            record.runtimeState = snapshot.status.grantsPro ? .verifiedActive : state(for: snapshot.status)
            record.lastSuccessAt = nowProvider()
            record.lastFailureAt = nil
            record.lastErrorCode = nil
            record.lastRemoteStatus = snapshot.status
        }

        if snapshot.status.grantsPro {
            let refreshedCredential = DirectLicenseCredential(
                licenseKey: credential.licenseKey,
                instanceID: snapshot.instanceID ?? credential.instanceID,
                subscriptionID: credential.subscriptionID,
                productID: snapshot.productID,
                plan: snapshot.plan
            )
            storedCredential = refreshedCredential
            try? store.storeCredential(refreshedCredential)
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
        let deviceKind = DirectLicenseDeviceKind.currentMac()
        let installID = (try? store.loadOrCreateInstallID()) ?? UUID().uuidString
        return "\(deviceKind.instanceNamePrefix) · Starcat \(installID.prefix(4).uppercased())"
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
