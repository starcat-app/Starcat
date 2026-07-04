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
    }

    var keychain: any KeychainManaging = KeychainManager.shared

    func loadCredential() throws -> DirectLicenseCredential? {
        guard let licenseKey = try keychain.loadServiceAPIKey(forService: Key.license),
              let instanceID = try keychain.loadServiceAPIKey(forService: Key.instance)
        else {
            return nil
        }
        return DirectLicenseCredential(licenseKey: licenseKey, instanceID: instanceID)
    }

    func storeCredential(_ credential: DirectLicenseCredential) throws {
        try keychain.storeServiceAPIKey(credential.licenseKey, forService: Key.license)
        try keychain.storeServiceAPIKey(credential.instanceID, forService: Key.instance)
    }

    func deleteCredential() throws {
        try keychain.deleteServiceAPIKey(forService: Key.license)
        try keychain.deleteServiceAPIKey(forService: Key.instance)
    }
}
