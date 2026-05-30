//
//  AppSettings.swift
//  Starcat
//
//  应用级用户偏好。
//
//  设计要点：
//  - 用 @Observable + UserDefaults 持久化，SwiftUI 端读偏好可自动响应
//  - 单例（.shared）模式，与 DatabaseManager / KeychainManager 一致
//  - 所有偏好键集中在 private Keys 枚举里，避免散落字符串
//  - 不打算在 App 内做 iCloud 偏好同步（macOS Settings 一般本机即可）
//
//  增加新偏好的流程：
//  1. Keys 里加 key
//  2. 加 @Observable 属性 + didSet 写 UserDefaults
//  3. 在 init 里读初始值
//  4. SettingsView 里加对应控件
//

import Foundation
import Observation

// MARK: - 列表密度

/// 仓库列表的视觉密度。
enum RepoListDensity: String, CaseIterable, Identifiable {
    /// 单行紧凑：一行内显示 name / lang / stars。
    case compact
    /// 卡片多行：头像 + full_name + description + 属性条。
    case card

    var id: String { rawValue }

    /// 用户可见的中文显示名。
    var displayName: String {
        switch self {
        case .compact: return "紧凑"
        case .card:    return "卡片"
        }
    }
}

// MARK: - AppSettings

/// 应用级偏好容器。
///
/// 通过 SwiftUI Environment 注入（见 `AppDependencies`），
/// 也可通过 `AppSettings.shared` 直接访问（与 KeychainManager 模式一致）。
@MainActor
@Observable
final class AppSettings {

    // MARK: - 单例

    static let shared = AppSettings()

    // MARK: - 偏好项

    /// 仓库列表行密度。
    /// 写入即落盘；UI 通过 @Observable 自动响应。
    var listDensity: RepoListDensity {
        didSet { persist(key: Keys.repoListDensity, value: listDensity.rawValue) }
    }

    // MARK: - 初始化

    private let defaults: UserDefaults

    /// - Parameter defaults: 注入点，便于测试用 UserDefaults(suiteName:) 隔离。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 读取或回落到默认值
        let densityRaw = defaults.string(forKey: Keys.repoListDensity)
        self.listDensity = densityRaw.flatMap(RepoListDensity.init(rawValue:)) ?? .card
    }

    // MARK: - 内部

    private func persist(key: String, value: String) {
        defaults.set(value, forKey: key)
    }

    /// 全部偏好键集中地，避免字符串散落。
    private enum Keys {
        static let repoListDensity = "settings.repoListDensity"
    }
}
