//
//  DirectLicenseStore.swift
//  Starcat
//
//  Direct License 本机凭据存储。
//

import Foundation

/// Direct License 本机凭据。
struct DirectLicenseCredential: Equatable, Sendable {
    var licenseKey: String
    var instanceID: String
    var subscriptionID: String?
    var customerID: String?
    var productID: String?
    var plan: DirectCheckoutPlan?
}

/// Direct License 凭据存储。
///
/// 授权码本质上等同购买凭证，不能明文落到 UserDefaults。这里复用现有
/// `KeychainManager` 的本地 AES-GCM 加密文件能力，并用独立 service id 避免和后端 API
/// Key、AI Key 命名空间混淆。
struct DirectLicenseStore: Sendable {
    private enum Key {
        static let license = "direct_license_key"
        static let instance = "direct_license_instance_id"
        static let subscription = "direct_license_subscription_id"
        static let customer = "direct_license_customer_id"
        static let product = "direct_license_product_id"
        static let plan = "direct_license_plan"
        static let validationRuntimeState = "direct_license_validation_runtime_state"
        static let validationLastAttemptAt = "direct_license_validation_last_attempt_at"
        static let validationLastSuccessAt = "direct_license_validation_last_success_at"
        static let validationLastFailureAt = "direct_license_validation_last_failure_at"
        static let validationLastErrorCode = "direct_license_validation_last_error_code"
        static let validationLastRemoteStatus = "direct_license_validation_last_remote_status"
    }

    var keychain: any KeychainManaging = KeychainManager.shared
    private var dateFormatter: ISO8601DateFormatter { ISO8601DateFormatter() }

    func loadCredential() throws -> DirectLicenseCredential? {
        guard let licenseKey = try keychain.loadServiceAPIKey(forService: Key.license),
              let instanceID = try keychain.loadServiceAPIKey(forService: Key.instance)
        else {
            return nil
        }
        return DirectLicenseCredential(
            licenseKey: licenseKey,
            instanceID: instanceID,
            subscriptionID: try keychain.loadServiceAPIKey(forService: Key.subscription),
            customerID: try keychain.loadServiceAPIKey(forService: Key.customer),
            productID: try keychain.loadServiceAPIKey(forService: Key.product),
            plan: try loadPlan()
        )
    }

    func storeCredential(_ credential: DirectLicenseCredential) throws {
        try keychain.storeServiceAPIKey(credential.licenseKey, forService: Key.license)
        try keychain.storeServiceAPIKey(credential.instanceID, forService: Key.instance)
        try storeOptional(credential.subscriptionID, forService: Key.subscription)
        try storeOptional(credential.customerID, forService: Key.customer)
        try storeOptional(credential.productID, forService: Key.product)
        try storeOptional(credential.plan?.rawValue, forService: Key.plan)
    }

    func deleteCredential() throws {
        try keychain.deleteServiceAPIKey(forService: Key.license)
        try keychain.deleteServiceAPIKey(forService: Key.instance)
        try keychain.deleteServiceAPIKey(forService: Key.subscription)
        try keychain.deleteServiceAPIKey(forService: Key.customer)
        try keychain.deleteServiceAPIKey(forService: Key.product)
        try keychain.deleteServiceAPIKey(forService: Key.plan)
        try deleteValidationRecord()
    }

    func loadValidationRecord() throws -> DirectLicenseValidationRecord {
        var record = DirectLicenseValidationRecord.empty
        record.plan = try loadPlan()
        if let rawState = try keychain.loadServiceAPIKey(forService: Key.validationRuntimeState),
           let state = DirectLicenseRuntimeState(rawValue: rawState) {
            record.runtimeState = state
        }
        record.lastAttemptAt = try loadDate(forService: Key.validationLastAttemptAt)
        record.lastSuccessAt = try loadDate(forService: Key.validationLastSuccessAt)
        record.lastFailureAt = try loadDate(forService: Key.validationLastFailureAt)
        record.lastErrorCode = try keychain.loadServiceAPIKey(forService: Key.validationLastErrorCode)
        if let rawStatus = try keychain.loadServiceAPIKey(forService: Key.validationLastRemoteStatus),
           let status = DirectLicenseStatus(rawValue: rawStatus) {
            record.lastRemoteStatus = status
        }
        return record
    }

    func storeValidationRecord(_ record: DirectLicenseValidationRecord) throws {
        try storeOptional(record.plan?.rawValue, forService: Key.plan)
        try storeOptional(record.runtimeState.rawValue, forService: Key.validationRuntimeState)
        try storeDate(record.lastAttemptAt, forService: Key.validationLastAttemptAt)
        try storeDate(record.lastSuccessAt, forService: Key.validationLastSuccessAt)
        try storeDate(record.lastFailureAt, forService: Key.validationLastFailureAt)
        try storeOptional(record.lastErrorCode, forService: Key.validationLastErrorCode)
        try storeOptional(record.lastRemoteStatus?.rawValue, forService: Key.validationLastRemoteStatus)
    }

    func deleteValidationRecord() throws {
        try keychain.deleteServiceAPIKey(forService: Key.validationRuntimeState)
        try keychain.deleteServiceAPIKey(forService: Key.validationLastAttemptAt)
        try keychain.deleteServiceAPIKey(forService: Key.validationLastSuccessAt)
        try keychain.deleteServiceAPIKey(forService: Key.validationLastFailureAt)
        try keychain.deleteServiceAPIKey(forService: Key.validationLastErrorCode)
        try keychain.deleteServiceAPIKey(forService: Key.validationLastRemoteStatus)
    }

    private func storeOptional(_ value: String?, forService service: String) throws {
        if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            try keychain.storeServiceAPIKey(trimmed, forService: service)
        } else {
            try keychain.deleteServiceAPIKey(forService: service)
        }
    }

    private func loadPlan() throws -> DirectCheckoutPlan? {
        guard let raw = try keychain.loadServiceAPIKey(forService: Key.plan) else { return nil }
        return DirectCheckoutPlan(rawValue: raw)
    }

    private func loadDate(forService service: String) throws -> Date? {
        guard let raw = try keychain.loadServiceAPIKey(forService: service) else { return nil }
        return dateFormatter.date(from: raw)
    }

    private func storeDate(_ date: Date?, forService service: String) throws {
        try storeOptional(date.map { dateFormatter.string(from: $0) }, forService: service)
    }
}
