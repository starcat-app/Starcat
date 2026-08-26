//
//  AutoTidySettings.swift
//  Starcat
//
//  HOM-126 - 自动后台 AI 整理：用户偏好与运行态记录。
//
//  模块职责：
//  - 描述「在 AI 设置页可配置 + 后台调度器读取」的全部状态。
//  - 走 UserDefaults JSON 持久化（与 `AppSettings.aiSummaryTask` 同款），不引入新表。
//  - 同时承载上次运行结果（lastRunAt + 应用/忽略/失败计数），供「运行状态」只读区展示。
//
//  关键约束：
//  - 默认值与 HOM-126 任务描述一致：总开关 OFF、启动+同步触发 ON、定期 OFF、
//    定期间隔 1 小时、50 个 / 最近 star 优先 / 仅标签 / 90% 阈值。
//  - 总开关 OFF 时，调度器整体不工作（即使其他子开关为 ON 也不会触发）。
//  - 处理范围与排序需要让用户能在不影响 HOM-52 手动模式的前提下独立调，
//    所以**不复用** `BatchAIQueueOptions` 全部字段——只把 actions / autoApplyTags /
//    threshold 这几个会传给底层服务的字段透传。
//  - `lastRunStats` 用结构化字段而非 String，便于本地化时数字与文案灵活拼装；
//    也避免老旧字符串在新版本里被半途改格式后无法解析。
//

import Foundation
import SwiftUI

// MARK: - 排序策略

/// 自动整理时挑选未分类仓库的排序口径。
///
/// 设计：
/// - 与 `RepoSortOption` 分开：那个枚举服务于列表 UI（含 8 种排序），
///   自动整理只需要"用户能解释"的三种简化策略即可，避免在设置面板里塞过多选项。
/// - 随机模式用 `Repo.id` 哈希 + 进程内 `SystemRandomNumberGenerator` 打乱，
///   不写库；每次触发都重新打乱，避免长期"只跑同一批"。
enum AutoTidySortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 最近 star 的优先（默认；与"用户最近最关心"假设一致）。
    case recentlyStarred
    /// 最早 star 的优先（解决"老 star 永远不被整理"的角落场景）。
    case earliestStarred
    /// 随机（避免堆积排序偏置；适合用户希望"逐步覆盖全量"）。
    case random

    var id: String { rawValue }

    /// 本地化显示名。
    var displayNameKey: LocalizedStringKey {
        switch self {
        case .recentlyStarred:  return "autoTidy.sort.recentlyStarred"
        case .earliestStarred:  return "autoTidy.sort.earliestStarred"
        case .random:           return "autoTidy.sort.random"
        }
    }

    /// 按本枚举从 `repos` 中取前 `limit` 个。
    ///
    /// 实现笔记：
    /// - 时间字段使用 ISO8601 字符串字典序，与时间序一致；
    /// - `recentlyStarred` 用 `starredAt` 降序、缺失值排末；
    /// - `earliestStarred` 升序、缺失值排末（哨兵 `\u{FFFD}`）；
    /// - `random` 用 `Repo.id` 配进程随机数发生器打乱，保证轮次内稳定。
    func pick(from repos: [Repo], limit: Int) -> [Repo] {
        guard limit > 0 else { return [] }
        let sorted: [Repo]
        switch self {
        case .recentlyStarred:
            sorted = repos.sorted { ($0.starredAt ?? "") > ($1.starredAt ?? "") }
        case .earliestStarred:
            sorted = repos.sorted {
                let a = $0.starredAt ?? "\u{FFFD}"
                let b = $1.starredAt ?? "\u{FFFD}"
                return a < b
            }
        case .random:
            sorted = repos.shuffled()
        }
        return Array(sorted.prefix(limit))
    }
}

// MARK: - 运行结果统计

/// 上一轮自动整理的结果。
///
/// 字段口径：
/// - `applied`：成功落库的 repo 数（status == .completed）。
/// - `ignored`：所有标签都低于阈值的 repo 数（status == .ignored）。
/// - `failed`：永久失败或重试耗尽的 repo 数（status == .failed）。
/// - `total`：本轮真正进入队列的总数（用户配的"最多 N 个"与"未分类总数"的较小者）。
///
/// 与 `BatchAIQueueService` 派生计数同源，由 `AutoTidyScheduler` 在 isFinished
/// 时一次性抓取并写回 settings，避免在 UI 重渲染过程中反复观察会变化的瞬时态。
struct AutoTidyLastRunStats: Codable, Equatable, Sendable {
    var total: Int
    var applied: Int
    var ignored: Int
    var failed: Int

    static let empty = AutoTidyLastRunStats(total: 0, applied: 0, ignored: 0, failed: 0)
}

// MARK: - 偏好结构体

/// 自动整理偏好与运行态。
///
/// 持久化方式：JSON 字符串落 `UserDefaults`（与 `AISettings` 同款）。
/// 增加字段时给默认值即可向后兼容：JSONDecoder 在缺字段时会用 init 默认值
/// （Swift 自动合成 init 不行；这里手写 Codable 实现 + decode 时给兜底）。
///
/// 字段分组：
/// 1) 总开关 + 触发时机
/// 2) 处理范围（条数 + 排序）
/// 3) 执行操作（摘要 / 标签 + 阈值）
/// 4) 运行态（上次运行时间 + 计数；只读区展示，调度器写入）
struct AutoTidySettings: Codable, Equatable, Sendable {

    // MARK: - 1. 总开关 + 触发时机

    /// 标签 / 摘要自动整理的总开关。
    var enabled: Bool

    /// 开启后：App 启动延迟 60s 自动整理一次。关闭后：启动时不触发（不是立刻执行）。
    /// 启动期网络 / 数据库还没暖完，固定 60s 让 stars 同步与首屏渲染先跑稳。
    var triggerOnLaunch: Bool

    /// 同步完成且检测到新 star 时增量触发。
    /// 调度器侧用「同步完成 + 5min 反抖动」近似实现，不严格依赖 syncManager 提供
    /// "本次有几个新 star" 增量数（HOM-126 第一版避免在 SyncManager 加新协议字段）。
    var triggerOnSync: Bool

    /// 定期触发。默认 OFF，避免新手第一周就被烧 quota。
    /// 开启后按 `scheduledIntervalHours` 间隔重复触发（仅 App 前台运行期间）。
    var triggerScheduled: Bool

    /// 定期触发间隔（小时）。默认 1；UI / 调度器均 clamp 到 `scheduledIntervalHoursRange`。
    /// 独立字段：关掉「定期开启」时仍保留用户上次选的间隔，再次打开可还原。
    var scheduledIntervalHours: Int

    // MARK: - 2. 处理范围

    /// 单轮最大处理数（5...500，UI Stepper 限定）。默认 50。
    /// 上限 500 是软上限——更大批次更适合走 HOM-52 手动模式 + 浮动面板可视。
    var maxPerRun: Int

    /// 排序策略，详见 `AutoTidySortOrder`。
    var sortOrder: AutoTidySortOrder

    // MARK: - 3. 执行操作

    /// 是否生成 AI 摘要。默认 false（HOM-126 任务描述明确：摘要烧 token 更多，默认关）。
    var generateSummary: Bool

    /// 是否推荐 + 自动应用标签。默认 true。
    /// 注意：本字段同时控制"推荐标签"与"自动应用"，因为自动模式没法弹确认框，
    /// 用户开了标签就视作同意自动应用（与 HOM-52 的 autoApply Toggle 解耦）。
    var generateTags: Bool

    /// 是否启用置信度阈值过滤。默认 true（保持 HOM-126 第一版"保险地只应用高置信度"语义）。
    ///
    /// HOM-126 follow-up (dong4j 反馈 2026-06-07)：用户希望阈值有独立开关，
    /// 关掉后不论 AI 给出什么置信度都视为通过（即下游 confidenceThreshold = 0），
    /// 同时 UI 上 disable 下方的阈值滑块，告诉用户"现在不过滤了"。
    /// 与 `generateTags` 串联：generateTags = false 时整个阈值区无意义、整体 disable；
    /// generateTags = true 但本开关关掉时，仅滑块 disable、Toggle 行仍可点开。
    var useConfidenceThreshold: Bool

    /// 自动应用标签的置信度阈值（0.5...1.0）。默认 0.90。
    /// 与 `BatchAIQueueOptions.confidenceThreshold` 同口径——低于阈值进 `.ignored` 桶。
    /// 当 `useConfidenceThreshold == false` 时，`makeBatchOptions` 会把这值降级为 0
    /// （等价于"全部通过"），本字段仍保留用户的历史选择，便于再次开启时还原。
    var confidenceThreshold: Double

    // MARK: - 4. 运行态（只读区展示）

    /// 上次自动跑的完成时刻；nil 表示从未跑过。
    var lastRunAt: Date?

    /// 上次自动跑的结果计数；nil 表示从未跑过。
    var lastRunStats: AutoTidyLastRunStats?

    // MARK: - 默认值

    /// 定期间隔允许范围（小时）。下限 1 小时（高于调度器 5min 反抖动）；上限 24 小时。
    static let scheduledIntervalHoursRange: ClosedRange<Int> = 1...24

    /// HOM-126 任务描述明确的最小烧 quota 安全默认值。
    static let `default` = AutoTidySettings(
        enabled: false,
        triggerOnLaunch: true,
        triggerOnSync: true,
        triggerScheduled: false,
        scheduledIntervalHours: 1,
        maxPerRun: 50,
        sortOrder: .recentlyStarred,
        generateSummary: false,
        generateTags: true,
        useConfidenceThreshold: true,
        confidenceThreshold: 0.90,
        lastRunAt: nil,
        lastRunStats: nil
    )

    // MARK: - Codable（手写以便缺字段时兜底默认值）

    /// 手写 init(from:) 的目的：未来追加新字段（如「免打扰时段」）时，
    /// 老 build 写的 JSON 缺字段不会让整个 settings 反序列化失败。
    /// 等价于"per-field optional decode + 兜底"。
    private enum CodingKeys: String, CodingKey {
        case enabled, triggerOnLaunch, triggerOnSync, triggerScheduled, scheduledIntervalHours
        case maxPerRun, sortOrder
        case generateSummary, generateTags
        case useConfidenceThreshold, confidenceThreshold
        case lastRunAt, lastRunStats
    }

    init(
        enabled: Bool,
        triggerOnLaunch: Bool,
        triggerOnSync: Bool,
        triggerScheduled: Bool,
        scheduledIntervalHours: Int,
        maxPerRun: Int,
        sortOrder: AutoTidySortOrder,
        generateSummary: Bool,
        generateTags: Bool,
        useConfidenceThreshold: Bool,
        confidenceThreshold: Double,
        lastRunAt: Date?,
        lastRunStats: AutoTidyLastRunStats?
    ) {
        self.enabled = enabled
        self.triggerOnLaunch = triggerOnLaunch
        self.triggerOnSync = triggerOnSync
        self.triggerScheduled = triggerScheduled
        self.scheduledIntervalHours = Self.clampScheduledIntervalHours(scheduledIntervalHours)
        self.maxPerRun = maxPerRun
        self.sortOrder = sortOrder
        self.generateSummary = generateSummary
        self.generateTags = generateTags
        self.useConfidenceThreshold = useConfidenceThreshold
        self.confidenceThreshold = confidenceThreshold
        self.lastRunAt = lastRunAt
        self.lastRunStats = lastRunStats
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        self.triggerOnLaunch = (try? c.decode(Bool.self, forKey: .triggerOnLaunch)) ?? d.triggerOnLaunch
        self.triggerOnSync = (try? c.decode(Bool.self, forKey: .triggerOnSync)) ?? d.triggerOnSync
        self.triggerScheduled = (try? c.decode(Bool.self, forKey: .triggerScheduled)) ?? d.triggerScheduled
        self.scheduledIntervalHours = Self.clampScheduledIntervalHours(
            (try? c.decode(Int.self, forKey: .scheduledIntervalHours)) ?? d.scheduledIntervalHours
        )
        self.maxPerRun = (try? c.decode(Int.self, forKey: .maxPerRun)) ?? d.maxPerRun
        self.sortOrder = (try? c.decode(AutoTidySortOrder.self, forKey: .sortOrder)) ?? d.sortOrder
        self.generateSummary = (try? c.decode(Bool.self, forKey: .generateSummary)) ?? d.generateSummary
        self.generateTags = (try? c.decode(Bool.self, forKey: .generateTags)) ?? d.generateTags
        self.useConfidenceThreshold = (try? c.decode(Bool.self, forKey: .useConfidenceThreshold)) ?? d.useConfidenceThreshold
        self.confidenceThreshold = (try? c.decode(Double.self, forKey: .confidenceThreshold)) ?? d.confidenceThreshold
        self.lastRunAt = try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        self.lastRunStats = try? c.decodeIfPresent(AutoTidyLastRunStats.self, forKey: .lastRunStats)
    }

    /// 把用户输入 / 老数据钳到合法小时区间。
    static func clampScheduledIntervalHours(_ hours: Int) -> Int {
        min(max(hours, scheduledIntervalHoursRange.lowerBound), scheduledIntervalHoursRange.upperBound)
    }

    /// 调度器读取的秒级间隔（已 clamp）。
    var scheduledIntervalSeconds: TimeInterval {
        TimeInterval(Self.clampScheduledIntervalHours(scheduledIntervalHours) * 60 * 60)
    }

    // MARK: - 派生

    /// 标签分类自动整理下至少要选一个子操作，供该 Section 的手动触发按钮判断。
    var hasAnyAction: Bool { generateSummary || generateTags }

    /// 标签 / 摘要后台调度器是否存在真正启用的工作。
    var hasEnabledBackgroundAction: Bool { enabled && hasAnyAction }

    /// 把自动整理偏好映射成底层 `BatchAIQueueOptions`。
    ///
    /// 映射规则：
    /// - actions：按 `generateSummary` / `generateTags` 组合 `Set<BatchAIAction>`；
    /// - autoApplyTags：自动模式恒为 true（用户开总开关 = 明示同意自动应用）；
    /// - confidenceThreshold：`useConfidenceThreshold == false` 时降级为 0（等价于"不过滤"，
    ///   所有 AI 建议都会被自动应用）；为 true 时透传用户值；
    /// - maxRetries：复用底层默认 3，自动模式不暴露给用户。
    func makeBatchOptions(standardActionRepoIDs: Set<Int64>? = nil) -> BatchAIQueueOptions {
        var actions: Set<BatchAIAction> = []
        if enabled, generateSummary { actions.insert(.summary) }
        if enabled, generateTags { actions.insert(.tags) }
        return BatchAIQueueOptions(
            actions: actions,
            autoApplyTags: enabled && generateTags,
            confidenceThreshold: useConfidenceThreshold ? confidenceThreshold : 0,
            maxRetries: 3,
            standardActionRepoIDs: standardActionRepoIDs
        )
    }
}
