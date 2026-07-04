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
    func activate(licenseKey: String) async -> Bool {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        return await perform { [store] in
            let snapshot = try await api.activate(DirectLicenseActivationRequest(
                licenseKey: trimmed,
                deviceID: deviceIDProvider(),
                appVersion: appVersionProvider()
            ))
            if snapshot.status.grantsPro, let instanceID = snapshot.instanceID {
                let credential = DirectLicenseCredential(licenseKey: trimmed, instanceID: instanceID)
                try store.storeCredential(credential)
                storedCredential = credential
            }
            return snapshot
        }
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

    func clearStoredCredential() {
        try? store.deleteCredential()
        storedCredential = nil
        lastSnapshot = nil
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
