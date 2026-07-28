//
//  StarcatMCPPairingTests.swift
//  StarcatTests
//
//  验证跨平台 CLI invitation 契约和自签名 TLS certificate 可被 Security.framework 解析。
//

import Foundation
import Security
import Testing
@testable import Starcat

@Suite("Starcat MCP Pairing")
@MainActor
struct StarcatMCPPairingTests {
    @Test("Invitation 包含协议、endpoint、fingerprint 和高熵 secret")
    func invitationContract() throws {
        let store = StarcatMCPDeviceStore()
        let fingerprint = String(repeating: "ab", count: 32)
        let raw = try store.createInvitation(
            endpoint: "https://starcat-mac.local:5551/mcp",
            certificateFingerprint: fingerprint
        )
        let components = try #require(URLComponents(string: raw))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "starcat-pair")
        #expect(components.host == "connect")
        #expect(values["v"] == StarcatMCPDeviceStore.protocolVersion)
        #expect(values["endpoint"] == "https://starcat-mac.local:5551/mcp")
        #expect(values["fingerprint"] == fingerprint)
        #expect((values["secret"]?.count ?? 0) >= 40)
    }

    @Test("自签名 certificate DER 可被 Security.framework 解析")
    func tlsCertificateIsParseable() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let data = try StarcatMCPTLSIdentityStore.makeCertificateDER(
            privateKey: privateKey,
            publicKey: publicKey
        )

        #expect(SecCertificateCreateWithData(nil, data as CFData) != nil)
    }

    @Test("设备确认后签发独立 token，撤销后立即失效")
    func deviceApprovalAndRevocation() async throws {
        let keychain = PairingKeychainStub()
        let store = StarcatMCPDeviceStore(keychain: keychain)
        let invitation = try store.createInvitation(
            endpoint: "http://127.0.0.1:5551/mcp",
            certificateFingerprint: nil
        )
        let components = try #require(URLComponents(string: invitation))
        let secret = try #require(components.queryItems?.first(where: { $0.name == "secret" })?.value)
        let request = StarcatMCPPairingExchangeRequest(
            secret: secret,
            device_name: "Test Linux",
            platform: "linux",
            architecture: "amd64",
            cli_version: "test"
        )

        let exchangeTask = Task { @MainActor in
            try await store.exchange(request)
        }
        await Task.yield()
        #expect(store.pendingApproval?.deviceName == "Test Linux")
        store.approvePendingPairing()
        let response = try await exchangeTask.value

        #expect(store.isAuthorized(token: response.token))
        #expect(store.devices.map(\.id) == [response.device_id])
        try store.revoke(deviceID: response.device_id)
        #expect(!store.isAuthorized(token: response.token))
        #expect(store.devices.isEmpty)
    }
}

private final class PairingKeychainStub: KeychainManaging, @unchecked Sendable {
    private var values: [String: String] = [:]

    func storeGithubToken(_ token: String) throws { values["github"] = token }
    func loadGithubToken() throws -> String? { values["github"] }
    func deleteGithubToken() throws { values.removeValue(forKey: "github") }
    func storeProjectAccessCredential(_ credentialJSON: String) throws { values["github-app"] = credentialJSON }
    func loadProjectAccessCredential() throws -> String? { values["github-app"] }
    func deleteProjectAccessCredential() throws { values.removeValue(forKey: "github-app") }
    func storeAIKey(_ key: String) throws { values["ai"] = key }
    func loadAIKey() throws -> String? { values["ai"] }
    func deleteAIKey() throws { values.removeValue(forKey: "ai") }
    func storeAIKey(_ key: String, forProvider providerID: String) throws { values["ai:\(providerID)"] = key }
    func loadAIKey(forProvider providerID: String) throws -> String? { values["ai:\(providerID)"] }
    func deleteAIKey(forProvider providerID: String) throws { values.removeValue(forKey: "ai:\(providerID)") }
    func storeServiceAPIKey(_ key: String, forService serviceID: String) throws { values["service:\(serviceID)"] = key }
    func loadServiceAPIKey(forService serviceID: String) throws -> String? { values["service:\(serviceID)"] }
    func deleteServiceAPIKey(forService serviceID: String) throws { values.removeValue(forKey: "service:\(serviceID)") }
    func deleteAllCredentials() throws { values.removeAll() }
    func ping() throws {}
}
