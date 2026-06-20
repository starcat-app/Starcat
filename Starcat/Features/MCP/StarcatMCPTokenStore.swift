//
//  StarcatMCPTokenStore.swift
//  Starcat
//
//  MCP Bearer token 的安全存储。
//
//  复用 `KeychainManaging.storeServiceAPIKey(_:forService:)` 的加密文件后端，但使用独立
//  serviceID = "mcp"，避免与 trending/weekly 等后端服务 API Key 混淆。
//

import Foundation
import Security

struct StarcatMCPTokenStore {
    private static let serviceID = "mcp"
    private let keychain: any KeychainManaging

    init(keychain: any KeychainManaging = KeychainManager.shared) {
        self.keychain = keychain
    }

    func loadOrCreateToken() -> String {
        if let token = try? keychain.loadServiceAPIKey(forService: Self.serviceID), !token.isEmpty {
            return token
        }
        let token = Self.makeToken()
        try? keychain.storeServiceAPIKey(token, forService: Self.serviceID)
        return token
    }

    func rotateToken() -> String {
        let token = Self.makeToken()
        try? keychain.storeServiceAPIKey(token, forService: Self.serviceID)
        return token
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        return UUID().uuidString + "-" + UUID().uuidString
    }
}

