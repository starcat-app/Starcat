//
//  StarcatLocalAPIKeyStore.swift
//  Starcat
//
//  Starcat 本机外部集成 API Key 的单一来源。
//
//  这个 key 只授权 127.0.0.1 上的 Starcat 本地接口, 供 MCP、浏览器插件
//  以及后续 Alfred/Raycast/uTools/脚本 REST 调用复用。它不是 GitHub token,
//  也不是 AI provider key 或 Starcat 后端服务 API key。
//

import Foundation
import Observation
import Security

@MainActor
@Observable
final class StarcatLocalAPIKeyStore {
    static let shared = StarcatLocalAPIKeyStore()

    private static let serviceID = "local_api"
    private let keychain: any KeychainManaging

    private(set) var apiKey: String

    init(keychain: any KeychainManaging = KeychainManager.shared) {
        self.keychain = keychain

        if let stored = try? keychain.loadServiceAPIKey(forService: Self.serviceID), !stored.isEmpty {
            apiKey = stored
        } else {
            let generated = Self.makeAPIKey()
            apiKey = generated
            try? keychain.storeServiceAPIKey(generated, forService: Self.serviceID)
        }
    }

    /// 重新生成全局本地 API Key。
    ///
    /// MCP 和 Companion 都观察同一个 store。刷新后旧 key 应立即失效,
    /// 外部工具需要重新复制这里的新 key。
    func rotateAPIKey() {
        let generated = Self.makeAPIKey()
        apiKey = generated
        try? keychain.storeServiceAPIKey(generated, forService: Self.serviceID)
    }

    private static func makeAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        return UUID().uuidString + "-" + UUID().uuidString
    }
}
