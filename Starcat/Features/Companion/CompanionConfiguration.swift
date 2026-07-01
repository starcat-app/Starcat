//
//  CompanionConfiguration.swift
//  Starcat
//
//  Chrome Companion 本机配对配置。
//
//  设计约束:
//  - token 是本机 HTTP Bearer 凭证, 只授权 loopback API, 不能复用 GitHub/AI/服务 Key;
//  - port 与 enabled 不是秘密, 使用 UserDefaults 便于 Debug 开关和测试注入;
//  - token 生成后写入 Starcat 现有 AES-GCM 凭证文件, 插件只能由用户手动复制;
//  - 默认 disabled, 避免未发布插件能力在普通用户环境中无意开启本机服务。
//

import Foundation
import Observation

@MainActor
@Observable
final class CompanionConfiguration {
    enum ServerStatus: String, Equatable {
        case stopped
        case starting
        case running
        case failed
    }

    private enum Key {
        static let enabled = "companion.enabled"
        static let port = "companion.localHTTP.port"
    }

    static let defaultPort: UInt16 = 5051
    static let allowedPortRange: ClosedRange<Int> = 5051...5060

    private let secureStore: any KeychainManaging
    private let defaults: UserDefaults

    private(set) var token: String
    private(set) var port: UInt16
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }
    private(set) var serverStatus: ServerStatus = .stopped

    init(
        secureStore: any KeychainManaging = KeychainManager.shared,
        defaults: UserDefaults = .standard
    ) {
        self.secureStore = secureStore
        self.defaults = defaults

        if let stored = try? secureStore.loadCompanionToken(), !stored.isEmpty {
            token = stored
        } else {
            let generated = Self.makeToken()
            token = generated
            try? secureStore.storeCompanionToken(generated)
        }

        let savedPort = defaults.integer(forKey: Key.port)
        if Self.allowedPortRange.contains(savedPort) {
            port = UInt16(savedPort)
        } else {
            port = Self.defaultPort
        }
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    func resetToken() {
        let generated = Self.makeToken()
        token = generated
        try? secureStore.storeCompanionToken(generated)
    }

    func updateBoundPort(_ value: UInt16) {
        guard Self.allowedPortRange.contains(Int(value)) else { return }
        port = value
        defaults.set(Int(value), forKey: Key.port)
    }

    func updateServerStatus(_ value: ServerStatus) {
        serverStatus = value
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes).base64EncodedString()
    }
}
