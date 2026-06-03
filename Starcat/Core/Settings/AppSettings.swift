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
import SwiftUI
import Observation

// MARK: - 外观主题(W4-5 D1,dong4j 2026-06-03 需求)

/// 应用外观主题。
///
/// 设计选型:
/// - 不强制走系统 — Starcat 整体视觉(暖橙 code 卡 + 卡片式 sheet)在深色下层次更分明,
///   所以默认 `.dark`,但保留 `.system` / `.light` 让用户自由切换
/// - 对应到 SwiftUI 的 `ColorScheme?`:`.system` → nil(跟随系统),其余 → 强制
/// - icon 用 SF Symbol 跟 macOS 系统"外观"设置的图标语言保持一致,
///   降低用户认知成本
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// 跟随系统(macOS 系统设置切换"外观"时 Starcat 自动同步)
    case system
    /// 强制浅色
    case light
    /// 强制深色 — Starcat 默认值
    case dark

    var id: String { rawValue }

    /// 本地化显示名(供 Picker / Label 使用)。
    var displayName: LocalizedStringKey {
        switch self {
        case .system: return "settings.appearance.system"
        case .light:  return "settings.appearance.light"
        case .dark:   return "settings.appearance.dark"
        }
    }

    /// SF Symbol 图标。
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.fill"
        }
    }

    /// 映射到 SwiftUI 的 `ColorScheme?`。
    ///
    /// - `.system` → `nil`:`.preferredColorScheme(nil)` 即"不强制",回退到系统设置
    /// - `.light` → `.light` / `.dark` → `.dark`:强制覆盖系统外观
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 列表密度

/// 仓库列表的视觉密度。
enum RepoListDensity: String, CaseIterable, Identifiable {
    /// 单行紧凑：一行内显示 name / lang / stars。
    case compact
    /// 卡片多行：头像 + full_name + description + 属性条。
    case card

    var id: String { rawValue }

    /// 本地化显示名。
    var displayName: LocalizedStringKey {
        switch self {
        case .compact: return "settings.listDensity.compact"
        case .card:    return "settings.listDensity.card"
        }
    }
}

// MARK: - 列表排序（W4-4 D1）

/// 仓库列表排序选项。
///
/// 设计：把"字段 + 方向"合并成枚举 case，UI 用单层 Picker 就能列全，无需嵌套 Menu。
/// 默认 `.starredAtDesc` — 最近 star 的在最前，与之前隐式行为一致。
enum RepoSortOption: String, CaseIterable, Identifiable {
    /// 默认：最近 star 在前。
    case starredAtDesc
    /// 最早 star 在前。
    case starredAtAsc
    /// 名称 A→Z。
    case nameAsc
    /// 名称 Z→A。
    case nameDesc
    /// Stars 高→低。
    case starsDesc
    /// Stars 低→高。
    case starsAsc
    /// 最近 push（GitHub `pushed_at`）在前。命名采用"更新"对齐用户语义。
    case updatedDesc
    /// 最早 push 在前。
    case updatedAsc

    var id: String { rawValue }

    /// 本地化显示名。
    var displayName: LocalizedStringKey {
        switch self {
        case .starredAtDesc: return "settings.sort.starredAtDesc"
        case .starredAtAsc:  return "settings.sort.starredAtAsc"
        case .nameAsc:       return "settings.sort.nameAsc"
        case .nameDesc:      return "settings.sort.nameDesc"
        case .starsDesc:     return "settings.sort.starsDesc"
        case .starsAsc:      return "settings.sort.starsAsc"
        case .updatedDesc:   return "settings.sort.updatedDesc"
        case .updatedAsc:    return "settings.sort.updatedAsc"
        }
    }

    /// SF Symbol，用于 Menu Label 视觉提示。
    var systemImage: String {
        switch self {
        case .starredAtDesc, .starredAtAsc: return "star"
        case .nameAsc, .nameDesc:           return "textformat"
        case .starsDesc, .starsAsc:         return "star.fill"
        case .updatedDesc, .updatedAsc:     return "clock.arrow.circlepath"
        }
    }

    /// 排序谓词。
    ///
    /// 实现策略：
    /// - 时间字段（starredAt / pushedAt）用 ISO8601 字符串字典序，与时间序一致(`String?`，nil 视作空串、排最后)
    /// - 名称按 `fullName` 大小写不敏感比较
    /// - Stars 数字直接比较
    ///
    /// 1801 条 in-memory sort 耗时 < 10ms，HomeViewModel 直接调，无需走数据库重查。
    func comparator(_ a: Repo, _ b: Repo) -> Bool {
        switch self {
        case .starredAtDesc:
            return (a.starredAt ?? "") > (b.starredAt ?? "")
        case .starredAtAsc:
            // 升序也要把 nil 推到末尾(否则空串会冒到最前面看不到内容)
            let av = a.starredAt ?? "\u{FFFD}"
            let bv = b.starredAt ?? "\u{FFFD}"
            return av < bv
        case .nameAsc:
            return a.fullName.localizedCaseInsensitiveCompare(b.fullName) == .orderedAscending
        case .nameDesc:
            return a.fullName.localizedCaseInsensitiveCompare(b.fullName) == .orderedDescending
        case .starsDesc:
            return a.starsCount > b.starsCount
        case .starsAsc:
            return a.starsCount < b.starsCount
        case .updatedDesc:
            return (a.pushedAt ?? "") > (b.pushedAt ?? "")
        case .updatedAsc:
            let av = a.pushedAt ?? "\u{FFFD}"
            let bv = b.pushedAt ?? "\u{FFFD}"
            return av < bv
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

    /// 应用外观主题(W4-5 D1,dong4j 2026-06-03 需求)。
    /// 默认 `.dark` — Starcat 主视觉为深色,见 `AppearanceMode` 设计注释。
    /// 写入即落盘;UI 通过 @Observable 自动响应,
    /// `StarcatApp` 的 WindowGroup / Settings scene 各挂一个 `.preferredColorScheme(_:)` 应用。
    var appearanceMode: AppearanceMode {
        didSet { persist(key: Keys.appearanceMode, value: appearanceMode.rawValue) }
    }

    /// 仓库列表行密度。
    /// 写入即落盘；UI 通过 @Observable 自动响应。
    var listDensity: RepoListDensity {
        didSet { persist(key: Keys.repoListDensity, value: listDensity.rawValue) }
    }

    /// 仓库列表排序（W4-4 D1）。默认 `.starredAtDesc`。
    var repoSortOption: RepoSortOption {
        didSet { persist(key: Keys.repoSortOption, value: repoSortOption.rawValue) }
    }

    /// W4-4 D2：是否隐藏已 archived 的仓库（默认 false，全部显示）。
    var hideArchived: Bool {
        didSet { persistBool(key: Keys.hideArchived, value: hideArchived) }
    }

    /// W4-4 D2：是否隐藏 fork 的仓库（默认 false，全部显示）。
    var hideForks: Bool {
        didSet { persistBool(key: Keys.hideForks, value: hideForks) }
    }

    /// W4-4 D3：按阅读状态过滤。`nil` = 全部。
    /// 落盘用 RawValue("unread"...);为了"无过滤"也能持久化,
    /// 用空字符串占位代表 nil。
    var statusFilter: RepoStatus? {
        didSet {
            defaults.set(statusFilter?.rawValue ?? "", forKey: Keys.statusFilter)
        }
    }

    /// 用户在 Manage 页最后选中的分类，用于跨启动恢复。
    ///
    /// 为什么存字符串而非 `SidebarItem`：
    /// - `SidebarItem` 含关联值（`.language(String?)` / `.tag(String)`），无法直接当 RawValue 落盘；
    /// - 为避免 AppSettings（Core 层）反向依赖 Home 功能层的 enum，这里只存"已编码字符串"，
    ///   具体编/解码由 `SidebarItem.persistedRawValue` / `init(persistedRawValue:)` 负责（Home 层）。
    /// - 空串表示"无记录"，解码时回落 `.allStars`。
    var lastManageSelectionRaw: String {
        didSet { persist(key: Keys.lastManageSelection, value: lastManageSelectionRaw) }
    }

    // MARK: - 初始化

    private let defaults: UserDefaults

    /// - Parameter defaults: 注入点，便于测试用 UserDefaults(suiteName:) 隔离。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // W4-5 D1:外观主题。dong4j 2026-06-03 决定默认深色(`.dark`),
        // 历史用户(首次升级到本版)若无落盘值,也会落到 `.dark`,跟新用户一致。
        let appearanceRaw = defaults.string(forKey: Keys.appearanceMode)
        self.appearanceMode = appearanceRaw.flatMap(AppearanceMode.init(rawValue:)) ?? .dark

        // 读取或回落到默认值
        let densityRaw = defaults.string(forKey: Keys.repoListDensity)
        self.listDensity = densityRaw.flatMap(RepoListDensity.init(rawValue:)) ?? .card

        let sortRaw = defaults.string(forKey: Keys.repoSortOption)
        self.repoSortOption = sortRaw.flatMap(RepoSortOption.init(rawValue:)) ?? .starredAtDesc

        // Bool 默认值用 object(forKey:) 判 nil；防止 `bool(forKey:)` 把缺失也当 false
        self.hideArchived = defaults.object(forKey: Keys.hideArchived) as? Bool ?? false
        self.hideForks = defaults.object(forKey: Keys.hideForks) as? Bool ?? false

        // W4-4 D3：空字符串表示 nil(无过滤);非空字符串尝试匹配 RepoStatus,失败也回落 nil
        let statusRaw = defaults.string(forKey: Keys.statusFilter) ?? ""
        self.statusFilter = statusRaw.isEmpty ? nil : RepoStatus(rawValue: statusRaw)

        // 上次 Manage 分类：缺失则空串，由 SidebarItem 解码时回落 allStars
        self.lastManageSelectionRaw = defaults.string(forKey: Keys.lastManageSelection) ?? ""
    }

    // MARK: - 内部

    private func persist(key: String, value: String) {
        defaults.set(value, forKey: key)
    }

    private func persistBool(key: String, value: Bool) {
        defaults.set(value, forKey: key)
    }

    /// 全部偏好键集中地，避免字符串散落。
    private enum Keys {
        static let appearanceMode = "settings.appearanceMode"  // W4-5 D1
        static let repoListDensity = "settings.repoListDensity"
        static let repoSortOption = "settings.repoSortOption"
        static let hideArchived = "settings.hideArchived"
        static let hideForks = "settings.hideForks"
        static let statusFilter = "settings.statusFilter"
        static let lastManageSelection = "settings.lastManageSelection"
    }
}
