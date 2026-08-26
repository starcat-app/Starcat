//
//  BatchAIQueueModels.swift
//  Starcat
//
//  HOM-52 批量未分类仓库 AI 整理 - 数据模型层。
//
//  模块职责：
//  - 定义"批量 AI 整理"队列中的单元 Job、状态机、本次任务配置 Options。
//  - 作为 BatchAIQueueService（状态机执行者）与 SwiftUI（状态展示者）之间的稳定边界。
//
//  关键约束：
//  - Job 是**会话级**对象：纯内存持有，不落库。详细理由见 BatchAIQueueService 文件头。
//    （已有 AI 摘要会命中 ai_summaries 表，所以重启后再次处理也不会浪费 AI 配额。）
//  - 状态枚举与 "ignored" 的引入：dong4j 2026-06-06 16:21 评审决议——
//    当开启"自动应用标签"时，置信度低于阈值的推荐应被**自动忽略**（不计入失败、不重试）。
//    `ignored` 与 `failed` 在 UX 上必须区分，否则用户会误以为 AI 失败率虚高。
//  - 操作集 Options.actions 用 Set<Action> 保证多选幂等；UI 默认勾选「摘要 + 标签」。
//

import Foundation

// MARK: - BatchAIJobStatus

/// 队列中单个 repo 的处理状态机。
///
/// 状态流转：
/// ```
///                     ┌──> .completed    （应用了 N 个标签 / 摘要写入成功）
/// .queued ─> .processing ──> .ignored     （AI 返回的所有标签都低于置信度阈值）
///                     │
///                     └──> .failed        （重试 N 次仍失败：网络/AI Key/JSON 解析等）
/// ```
///
/// 注意：
/// - `ignored` 与 `failed` 是互斥终态，UI 用不同颜色 / 文案表达。
/// - `failed` 才计入"失败计数 + 触发重试"；`ignored` 不算失败。
/// - `queued` 时未做任何调用，可以被用户在面板中删除或整体 cancel。
enum BatchAIJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case completed
    case ignored
    case failed
}

// MARK: - BatchAIFailure

/// 批量任务失败的结构化语义。
///
/// 不能在 job 里保存失败发生时已经翻译完成的 `String`：用户运行任务后切换应用语言，
/// SwiftUI 会重建面板，但旧字符串不会重新查 String Catalog，最终出现英文界面夹中文错误。
/// 这里保留错误类型与参数，`localizedMessage` 每次渲染时按当前 `LocaleStore` 重新查表。
enum BatchAIFailure: Equatable, Sendable {
    case aiClient(AIClientError)
    case repoInsight(RepoAIInsightError)
    case cancelled
    /// 无法归类的第三方错误；nil 表示原始内容为空或属于不可展示的 SDK dump。
    case unknown(String?)

    init(error: Error) {
        if let ai = error as? AIClientError {
            self = .aiClient(ai)
            return
        }
        if let insight = error as? RepoAIInsightError {
            self = .repoInsight(insight)
            return
        }

        let detail = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = detail.lowercased()
        let isRawSDKDump = normalized.contains("statuserror(")
            || normalized.contains("<nshttpurlresponse")
            || normalized.contains("nsurlerror")
        guard !detail.isEmpty, !isRawSDKDump else {
            self = .unknown(nil)
            return
        }
        self = .unknown(detail.count > 160 ? String(detail.prefix(157)) + "…" : detail)
    }

    /// 当前应用语言下的短文案。切换语言后重新求值，不缓存翻译结果。
    var localizedMessage: String {
        switch self {
        case .aiClient(let error):
            return error.localizedDescription
        case .repoInsight(let error):
            return error.localizedDescription
        case .cancelled:
            return String.l10n("batchAI.panel.cancelledByUser")
        case .unknown(let message):
            return message ?? String.l10n("batchAI.panel.row.failedUnknown")
        }
    }
}

// MARK: - BatchAIJob

/// 队列中单个 repo 的执行记录。
///
/// `id` 用 `repoId` 直接当主键：同一仓库不允许在队列中出现两次（去重在 enqueue 处保证）。
/// 这样 SwiftUI ForEach 用 `\.id` 即可稳定 diff，无需额外 UUID。
struct BatchAIJob: Identifiable, Equatable, Sendable {

    /// 复用 GitHub repo id 作为唯一键（队列内 repo 唯一）。
    var id: Int64 { repoId }

    let repoId: Int64
    /// 仅用于 UI 显示，避免每次渲染都回查 Repository。
    let repoFullName: String

    var status: BatchAIJobStatus = .queued

    /// 已经发起的尝试次数（不含尚未开始的本次）。失败重试上限见 BatchAIQueueOptions.maxRetries。
    var attempts: Int = 0

    /// 失败语义（status == .failed 时填）。UI 在渲染时才按当前应用语言生成短文案。
    var failure: BatchAIFailure?

    /// 可展开的短诊断（已脱敏），只保留 HTTP / URL / Content-Type 等摘要。
    /// 这里禁止存 Request / Response payload，避免 SwiftUI 展开时渲染超长文本。
    var errorDiagnostic: String?

    /// 仅供用户点击「复制详情」时读取的完整诊断，包含格式化 Request / Response JSON。
    /// 与 `errorDiagnostic` 分开保存，确保展开区保持轻量。
    var copyDiagnostic: String?

    /// 成功应用的标签名（status == .completed 时填）。
    /// 用 [String] 而非 [Tag]，避免 ViewModel 跨线程持有 GRDB 实体。
    var appliedTagNames: [String] = []

    /// 因低于置信度阈值被忽略的标签（status == .ignored 时填）。
    /// 仍保留 `(name, confidence)` 二元组以便 UI 提示"X% < 阈值 Y%"。
    var ignoredTagsBelowThreshold: [(name: String, confidence: Double)] = []

    /// 进入终态的时间戳，便于按"最近完成"排序。
    var finishedAt: Date?

    /// 是否生成了 AI 摘要（用于 UI 区分"只跑了标签"和"摘要 + 标签都跑了"）。
    var didGenerateSummary: Bool = false

    init(repoId: Int64, repoFullName: String) {
        self.repoId = repoId
        self.repoFullName = repoFullName
    }

    // `ignoredTagsBelowThreshold` 含元组数组，Equatable 需要手写。
    static func == (lhs: BatchAIJob, rhs: BatchAIJob) -> Bool {
        guard lhs.repoId == rhs.repoId,
              lhs.repoFullName == rhs.repoFullName,
              lhs.status == rhs.status,
              lhs.attempts == rhs.attempts,
              lhs.failure == rhs.failure,
              lhs.errorDiagnostic == rhs.errorDiagnostic,
              lhs.copyDiagnostic == rhs.copyDiagnostic,
              lhs.appliedTagNames == rhs.appliedTagNames,
              lhs.finishedAt == rhs.finishedAt,
              lhs.didGenerateSummary == rhs.didGenerateSummary,
              lhs.ignoredTagsBelowThreshold.count == rhs.ignoredTagsBelowThreshold.count
        else { return false }
        for (l, r) in zip(lhs.ignoredTagsBelowThreshold, rhs.ignoredTagsBelowThreshold) {
            if l.name != r.name || l.confidence != r.confidence { return false }
        }
        return true
    }
}

// MARK: - BatchAIAction

/// 本次批量整理需要执行的子任务。
///
/// 之所以拆成 Set 而不是布尔位字段：
/// - 后续扩展（如新增"AI 自动分类"）只需 case 增加一项，不破坏旧序列化。
/// - UI 多选 Toggle 与 Set 天然对齐，且预设勾选集合可由 Set 字面量表达。
enum BatchAIAction: String, CaseIterable, Codable, Hashable, Sendable {
    /// 生成 AI 摘要（写入 ai_summaries 表）。
    case summary
    /// 推荐并应用 / 暂存标签（依 Options.autoApplyTags 决定是否落库）。
    case tags
}

// MARK: - BatchAIQueueOptions

/// 单次启动批量整理时的执行配置。
///
/// 默认值与 dong4j 2026-06-06 评审一致：
/// - actions = [.summary, .tags]
/// - autoApplyTags = false（默认走详情页确认流，避免新用户误产生大量未确认标签）
/// - confidenceThreshold = 0.90（dong4j 16:22 明确要求默认 90%）
/// - maxRetries = 3（任务描述明确）
struct BatchAIQueueOptions: Equatable, Sendable {

    /// 本次要跑哪些 AI 子任务。空集合视为无效（UI 应禁用启动按钮）。
    var actions: Set<BatchAIAction> = [.summary, .tags]

    /// 是否自动应用 AI 推荐的标签（不弹确认框）。
    ///
    /// 设计取舍：默认 false。这是"破坏性 + 不可逆"的批量写入，
    /// 用户首次大批量整理时主动开启，平时小批量保持手动确认更安全。
    var autoApplyTags: Bool = false

    /// 自动应用标签时的置信度阈值（0.0 ~ 1.0）。
    ///
    /// 仅当 `autoApplyTags == true` 时生效；低于阈值的标签会进入 ignored 桶并展示原因。
    /// 默认 0.90，对应 dong4j 评审决议。
    var confidenceThreshold: Double = 0.90

    /// 失败重试上限。
    ///
    /// 区分两类错误：
    /// - **可重试**：网络超时 / 5xx / 解析失败 → 重试至 maxRetries
    /// - **不可重试**：API Key 缺失 / 401 等鉴权错误 → 直接 failed，不消耗重试次数
    /// 不可重试错误的判别由 BatchAIQueueService.isPermanentError 实现。
    var maxRetries: Int = 3

    /// Auto Tidy 把不同候选范围合并进一个队列时，限制摘要/标签只处理原“未打标签”集合。
    /// nil 保持现有手动批量整理对全部入队 repo 执行的语义。
    var standardActionRepoIDs: Set<Int64>?

    /// 至少要选一个标签整理子任务。
    var isValidForStart: Bool { !actions.isEmpty }

    func shouldRun(_ action: BatchAIAction, forRepoID repoID: Int64) -> Bool {
        guard actions.contains(action) else { return false }
        return standardActionRepoIDs?.contains(repoID) ?? true
    }
}
