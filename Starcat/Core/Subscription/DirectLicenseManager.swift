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
    /// 使用绝对截止时间，关闭设置页不会重置冷却，也不依赖后台计时任务存活。
    private(set) var activationRetryAfter: Date?

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
        // MainActor 上在首次 await 前检查；按钮、深链与直接调用共用同一道入口。
        guard !isActivating else { return false }
        let retrySeconds = activationRetrySeconds()
        guard retrySeconds == 0 else {
            lastErrorMessage = DirectLicenseAPIError.rateLimited(retryAfter: retrySeconds).localizedDescription
            return false
        }
        activationRetryAfter = nil

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
                do {
                    try store.storeCredential(credential)
                } catch {
                    // 远端已成功；本机保存失败不能冒充激活完成，也不能把底层描述中的路径/凭据显示给用户。
                    let diagnostic = DirectLicenseActivationError.storageDiagnostic(error)
                    AppLog.general.error("[direct-license] stage=credential_save code=credential_save_failed \(diagnostic, privacy: .public)")
                    throw DirectLicenseActivationError.credentialSaveFailed
                }
                storedCredential = credential
            }
            return snapshot
        }
    }

    /// 向上取整使按钮只在整个等待期结束后恢复；注入时钟便于无等待测试边界。
    func activationRetrySeconds(at date: Date? = nil) -> Int {
        guard let activationRetryAfter else { return 0 }
        let remaining = max(0, activationRetryAfter.timeIntervalSince(date ?? nowProvider()).rounded(.up))
        return Int(exactly: remaining) ?? Int.max
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
        guard shouldValidateStoredLicense() else {
            recordDiagnosticState(phase: "validationNotDue")
            return entitlement.isActive
        }
        return await validateStoredLicense(force: true, isSilent: true)
    }

    private func validateStoredLicense(force: Bool, isSilent: Bool) async -> Bool {
        let diagnostic = DiagnosticOperation(category: "license", name: "validation")
        return await DiagnosticContext.$current.withValue(diagnostic) {
            defer { diagnostic.finish() }
            guard let credential = storedCredential ?? (try? store.loadCredential()) else {
                diagnostic.finish(.skipped, fields: ["credentialAvailable": .boolean(false)])
                return false
            }
            if !force, !shouldValidateStoredLicense() {
                diagnostic.finish(.skipped)
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
                diagnostic.finish(.failed, error: error)
                return entitlement.isActive
            }
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
            // UI 只接收受控文案；未知错误也不能直接暴露请求内容或文件路径。
            lastErrorMessage = (error as? DirectLicenseAPIError)?.errorDescription
                ?? (error as? DirectLicenseActivationError)?.errorDescription
                ?? DirectLicenseAPIError.invalidResponse.localizedDescription
            if case let .rateLimited(retryAfter) = error as? DirectLicenseAPIError {
                activationRetryAfter = nowProvider().addingTimeInterval(TimeInterval(retryAfter))
            }
            // 用户提示与诊断分离；未知 Error 的描述也可能带请求内容，只记录固定错误码。
            let diagnosticCode = (error as? DirectLicenseAPIError)?.diagnosticCode
                ?? (error as? DirectLicenseActivationError)?.diagnosticCode
                ?? "unknown_request_error"
            AppLog.general.error("[direct-license] request failed: \(diagnosticCode, privacy: .public)")
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
        defer { recordDiagnosticState(phase: "validatedSnapshotApplied") }
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
        defer { recordDiagnosticState(phase: "validationFailureApplied") }
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

    /// 使用已存在的权益状态，明确区别“错误允许保留”与“当前确实有效”，不读取或导出授权凭据。
    private func recordDiagnosticState(phase: String) {
        var fields: [String: DiagnosticValue] = [
            "entitlementActive": .boolean(entitlement.isActive),
            "credentialAvailable": .boolean(storedCredential != nil),
            "runtimeState": .string(runtimeState.rawValue)
        ]
        if let success = validationRecord.lastSuccessAt {
            fields["lastSuccessAgeSeconds"] = .decimal(max(0, nowProvider().timeIntervalSince(success)))
        }
        DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
            level: .info, category: "license", operation: "entitlement", message: "Local entitlement observed",
            phase: phase, fields: fields))
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

/// 激活已到本机保存阶段时单独报错，避免用户将存储失败误认为授权码无效。
enum DirectLicenseActivationError: Error, LocalizedError {
    case credentialSaveFailed

    var diagnosticCode: String { "credential_save_failed" }

    var errorDescription: String? {
        String.l10n("settings.pro.direct.error.credentialSaveFailed")
    }

    /// 只展开一层已知存储包装，保留定位所需的系统码；禁止输出 userInfo 或任意错误域。
    static func storageDiagnostic(_ error: Error) -> String {
        let category: String
        let underlying: Error
        switch error {
        case let KeychainError.writeFailed(cause):
            category = "write_failed"
            underlying = cause
        case let KeychainError.encryptionFailed(cause):
            category = "encryption_failed"
            underlying = cause
        case let KeychainError.deleteFailed(cause):
            category = "delete_failed"
            underlying = cause
        default:
            category = "other"
            underlying = error
        }
        let systemError = underlying as NSError
        let knownDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain]
        let domain = knownDomains.contains(systemError.domain) ? systemError.domain : "other"
        return "reason=\(category) error_domain=\(domain) error_code=\(systemError.code)"
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
