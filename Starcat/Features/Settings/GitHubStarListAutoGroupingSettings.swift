//
//  GitHubStarListAutoGroupingSettings.swift
//  Starcat
//
//  GitHub Lists 后台自动分组的独立偏好。
//
//  关键约束：仓库分组会写 GitHub 远端，而标签整理只写 Starcat 本地数据；两者不能
//  共用总开关、阈值或运行统计。老版本曾把这两个字段塞进 AutoTidySettings，本类型
//  只在首次读取新 key 时迁移一次，之后完全使用独立 UserDefaults JSON。
//

import Foundation

/// HomeView 只观察会改变定时器安装方式的字段；后台尝试进度写回不能反复重装 Timer。
struct GitHubStarListAutoGroupingScheduleConfiguration: Equatable, Sendable {
    let enabled: Bool
    let triggerScheduled: Bool
    let scheduledIntervalHours: Int
}

struct GitHubStarListAutoGroupingSettings: Codable, Equatable, Sendable {
    /// 后台自动分组全局开关；还必须同时满足 List 级授权和置信度阈值才会写 GitHub。
    var enabled: Bool
    /// App 启动暖机完成后自动整理一次。
    var triggerOnLaunch: Bool
    /// GitHub Stars 同步完成后整理当前未分组仓库。
    var triggerOnSync: Bool
    /// App 运行期间按固定间隔整理。
    var triggerScheduled: Bool
    /// 定时整理间隔，单位小时。
    var scheduledIntervalHours: Int
    /// 单轮最多分析的未分组仓库数。
    var maxPerRun: Int
    /// 单轮候选仓库的处理优先级。
    var sortOrder: AutoTidySortOrder
    /// 自动写入 GitHub Lists 的最低置信度。
    var confidenceThreshold: Double
    /// 当前规则和阈值下已经分析、但没有达到自动应用条件的仓库。
    ///
    /// 不能用循环 offset：低置信度和无匹配仓库仍会保持未分组，offset 归零后会无限
    /// 重跑。记录这些 repo ID 后，本轮规则只判断一次；规则或阈值变化会自动清空记录。
    var attemptedRepositoryIDs: Set<Int64>
    /// `attemptedRepositoryIDs` 所属的规则快照；由自动分组会话生成。
    var attemptConfigurationFingerprint: String?

    static let `default` = GitHubStarListAutoGroupingSettings(
        enabled: false,
        triggerOnLaunch: true,
        triggerOnSync: true,
        triggerScheduled: false,
        scheduledIntervalHours: 1,
        maxPerRun: 50,
        sortOrder: .recentlyStarred,
        confidenceThreshold: 0.90
    )

    private enum CodingKeys: String, CodingKey {
        case enabled
        case triggerOnLaunch
        case triggerOnSync
        case triggerScheduled
        case scheduledIntervalHours
        case maxPerRun
        case sortOrder
        case confidenceThreshold
        case attemptedRepositoryIDs
        case attemptConfigurationFingerprint
    }

    init(
        enabled: Bool,
        triggerOnLaunch: Bool = true,
        triggerOnSync: Bool = true,
        triggerScheduled: Bool = false,
        scheduledIntervalHours: Int = 1,
        maxPerRun: Int = 50,
        sortOrder: AutoTidySortOrder = .recentlyStarred,
        confidenceThreshold: Double,
        attemptedRepositoryIDs: Set<Int64> = [],
        attemptConfigurationFingerprint: String? = nil
    ) {
        self.enabled = enabled
        self.triggerOnLaunch = triggerOnLaunch
        self.triggerOnSync = triggerOnSync
        self.triggerScheduled = triggerScheduled
        self.scheduledIntervalHours = Self.clampScheduledIntervalHours(scheduledIntervalHours)
        self.maxPerRun = Self.clampMaxPerRun(maxPerRun)
        self.sortOrder = sortOrder
        self.confidenceThreshold = Self.clamp(confidenceThreshold)
        self.attemptedRepositoryIDs = attemptedRepositoryIDs
        self.attemptConfigurationFingerprint = attemptConfigurationFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? false
        self.triggerOnLaunch = (try? container.decode(Bool.self, forKey: .triggerOnLaunch)) ?? true
        self.triggerOnSync = (try? container.decode(Bool.self, forKey: .triggerOnSync)) ?? true
        self.triggerScheduled = (try? container.decode(Bool.self, forKey: .triggerScheduled)) ?? false
        self.scheduledIntervalHours = Self.clampScheduledIntervalHours(
            (try? container.decode(Int.self, forKey: .scheduledIntervalHours)) ?? 1
        )
        self.maxPerRun = Self.clampMaxPerRun(
            (try? container.decode(Int.self, forKey: .maxPerRun)) ?? 50
        )
        self.sortOrder = (try? container.decode(AutoTidySortOrder.self, forKey: .sortOrder))
            ?? .recentlyStarred
        self.confidenceThreshold = Self.clamp(
            (try? container.decode(Double.self, forKey: .confidenceThreshold)) ?? 0.90
        )
        self.attemptedRepositoryIDs =
            (try? container.decode(Set<Int64>.self, forKey: .attemptedRepositoryIDs)) ?? []
        self.attemptConfigurationFingerprint = try? container.decodeIfPresent(
            String.self,
            forKey: .attemptConfigurationFingerprint
        )
    }

    /// 从仍保存在旧 AutoTidy JSON 中的两个字段迁移；新 key 已存在时调用方不会走这里。
    static func migratedFromLegacyAutoTidyJSON(_ raw: String?) -> Self? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        struct Legacy: Decodable {
            let generateGitHubListGrouping: Bool?
            let githubListGroupingConfidenceThreshold: Double?
        }
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: data),
              legacy.generateGitHubListGrouping != nil
                || legacy.githubListGroupingConfidenceThreshold != nil
        else { return nil }
        return Self(
            enabled: legacy.generateGitHubListGrouping ?? false,
            confidenceThreshold: legacy.githubListGroupingConfidenceThreshold ?? 0.90
        )
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0.5), 1.0)
    }

    static func clampScheduledIntervalHours(_ value: Int) -> Int {
        min(max(value, 1), 24)
    }

    static func clampMaxPerRun(_ value: Int) -> Int {
        min(max(value, 5), 500)
    }

    var scheduledIntervalSeconds: TimeInterval {
        TimeInterval(Self.clampScheduledIntervalHours(scheduledIntervalHours) * 60 * 60)
    }

    var scheduleConfiguration: GitHubStarListAutoGroupingScheduleConfiguration {
        GitHubStarListAutoGroupingScheduleConfiguration(
            enabled: enabled,
            triggerScheduled: triggerScheduled,
            scheduledIntervalHours: Self.clampScheduledIntervalHours(scheduledIntervalHours)
        )
    }
}
