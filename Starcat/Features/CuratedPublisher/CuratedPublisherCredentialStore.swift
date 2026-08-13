//
//  CuratedPublisherCredentialStore.swift
//  Starcat
//
//  精选发布台管理员密钥的窄接口，隔离 UI/Session 与具体安全存储实现。
//

import Foundation

protocol CuratedPublisherCredentialStoring: Sendable {
    func loadAdminKey() throws -> String?
    func storeAdminKey(_ key: String) throws
    func deleteAdminKey() throws
}

/// 复用 Starcat 现有 AES-GCM 本地安全凭据存储，并使用独立 namespace。
///
/// 不能复用普通 Weekly API key：两者权限完全不同，共用会导致普通客户端凭据被
/// 意外提升为管理员密钥，或设置页重置普通 key 时删除运营凭据。
struct CuratedPublisherCredentialStore: CuratedPublisherCredentialStoring {
    static let serviceID = "weekly-admin"

    private let keychain: any KeychainManaging

    init(keychain: any KeychainManaging = KeychainManager.shared) {
        self.keychain = keychain
    }

    func loadAdminKey() throws -> String? {
        try keychain.loadServiceAPIKey(forService: Self.serviceID)
    }

    func storeAdminKey(_ key: String) throws {
        try keychain.storeServiceAPIKey(key, forService: Self.serviceID)
    }

    func deleteAdminKey() throws {
        try keychain.deleteServiceAPIKey(forService: Self.serviceID)
    }
}
