//
//  CompanionConfiguration.swift
//  Starcat
//
//  Browser Plugin 本机服务配置。
//
//  设计约束:
//  - token 由全局 Starcat Local API Key 接管, 这里只保存服务开关与端口;
//  - port 与 enabled 不是秘密, 使用 UserDefaults 便于设置页和测试注入;
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
    /// 进程级配置实例。设置页和菜单栏入口必须观察同一份对象，否则从菜单栏切换
    /// Browser Plugin Service 后，设置页会继续显示旧状态。
    static let shared = CompanionConfiguration()

    private let localAPIKeyStore: StarcatLocalAPIKeyStore
    private let defaults: UserDefaults

    var token: String { localAPIKeyStore.apiKey }
    private(set) var port: UInt16
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }
    private(set) var serverStatus: ServerStatus = .stopped

    init(
        localAPIKeyStore: StarcatLocalAPIKeyStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.localAPIKeyStore = localAPIKeyStore
        self.defaults = defaults

        let savedPort = defaults.integer(forKey: Key.port)
        if Self.allowedPortRange.contains(savedPort) {
            port = UInt16(savedPort)
        } else {
            port = Self.defaultPort
        }
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    func updateBoundPort(_ value: UInt16) {
        guard Self.allowedPortRange.contains(Int(value)) else { return }
        port = value
        defaults.set(Int(value), forKey: Key.port)
    }

    func updateServerStatus(_ value: ServerStatus) {
        serverStatus = value
    }

}
