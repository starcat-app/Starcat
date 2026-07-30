//
//  RAGContextBudget.swift
//  Starcat
//
//  RAG 请求的统一 Context Window 预算与用量快照。
//
//  所有会进入模型请求的文本必须通过这里分配，而不是各模块各自截断。这样 Composer
//  展示的输入占用、实际发送的 Prompt 与内部输出预留使用同一份预算数字。
//

import Foundation

/// Context Window 中可向用户解释的分段。`historySummary` 与 `recentMessages` 分开，
/// 让长期会话在压缩后能清楚看到“摘要”取代了多少原始消息。
enum RAGContextUsageSegmentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case historySummary
    case recentMessages
    case question
    case evidence
    case repositoryInsights
    case repoContext
    case remoteContext
    case attachments
    case reservedOutput

    var id: String { rawValue }

    var displayKey: String {
        switch self {
        case .system: return "rag.workspace.context.system"
        case .historySummary: return "rag.workspace.context.historySummary"
        case .recentMessages: return "rag.workspace.context.recentMessages"
        case .question: return "rag.workspace.context.question"
        case .evidence: return "rag.workspace.context.evidence"
        case .repositoryInsights: return "rag.workspace.context.repositoryInsights"
        case .repoContext: return "rag.workspace.context.repoContext"
        case .remoteContext: return "rag.workspace.context.remote"
        case .attachments: return "rag.workspace.context.attachments"
        case .reservedOutput: return "rag.workspace.context.reservedOutput"
        }
    }
}

/// 发送前构建出的 Context Window 快照。token 仍是 `TokenEstimator` 的本地近似值，
/// 但整个请求统一使用同一估算器，因而预算边界和 UI 占比保持一致。
///
/// 展示约定：圆环 / 分段只反映已装进 Prompt 的**输入**；`reservedOutputTokens`
/// 仍参与内部扣预算，但不计入 `usageRatio`，避免用户把「预留回答空间」当成已消耗内容。
struct RAGContextUsage: Equatable, Sendable {
    var windowTokens: Int
    var reservedOutputTokens: Int
    var tokensBySegment: [RAGContextUsageSegmentKind: Int]
    /// 构建期留下的请求预览快照，供测试 / 调试核对；UI 不再展示正文。
    var promptPreview: String

    static let empty = RAGContextUsage(
        windowTokens: 32 * 1_024,
        reservedOutputTokens: 0,
        tokensBySegment: [:],
        promptPreview: ""
    )

    var inputTokens: Int {
        tokensBySegment
            .filter { $0.key != .reservedOutput }
            .reduce(0) { $0 + $1.value }
    }

    /// 输入 + 输出预留；仅供预算校验，不直接驱动 Composer 圆环。
    var usedTokens: Int { inputTokens + reservedOutputTokens }

    /// Composer 展示占比：只除以窗口的输入占用。
    var usageRatio: Double {
        guard windowTokens > 0 else { return 0 }
        return min(max(Double(inputTokens) / Double(windowTokens), 0), 1)
    }

    func tokenCount(for kind: RAGContextUsageSegmentKind) -> Int {
        kind == .reservedOutput ? reservedOutputTokens : (tokensBySegment[kind] ?? 0)
    }
}

/// 可随会话保存的 Context Window 用量摘要。
///
/// 这里只保留 token 计数，不保存 `promptPreview`。后者可能包含问题、历史与证据正文，
/// 若写进 execution trace 会把调试级敏感内容复制到长期会话历史。
struct RAGContextUsageSnapshot: Codable, Equatable, Sendable {
    var windowTokens: Int
    var reservedOutputTokens: Int
    var tokensBySegment: [RAGContextUsageSegmentKind: Int]

    init(usage: RAGContextUsage) {
        windowTokens = usage.windowTokens
        reservedOutputTokens = usage.reservedOutputTokens
        tokensBySegment = usage.tokensBySegment
    }

    /// 恢复成 UI 共用的用量模型；持久化快照从不恢复 Prompt 正文。
    var usage: RAGContextUsage {
        RAGContextUsage(
            windowTokens: windowTokens,
            reservedOutputTokens: reservedOutputTokens,
            tokensBySegment: tokensBySegment,
            promptPreview: ""
        )
    }
}

/// 单次 Prompt 构建期间的可变预算。输出预留从一开始扣除，因此输入永远不会挤占生成空间。
struct RAGContextBudget: Sendable {
    let windowTokens: Int
    let reservedOutputTokens: Int
    let inputLimitTokens: Int
    private(set) var tokensBySegment: [RAGContextUsageSegmentKind: Int] = [:]

    init(contextWindowTokens: Int, requestedOutputTokens: Int) {
        // 未识别模型默认 32K；既避免把 128K 的“最大输出”误当成模型窗口，也给用户
        // 一个保守且可在设置中明确覆盖的行为。上限防止异常配置造成不必要的大对象。
        let normalizedWindow = min(max(contextWindowTokens, 4 * 1_024), 2 * 1_024 * 1_024)
        let reserveCeiling = max(1_024, normalizedWindow / 4)
        let normalizedReserve = min(max(requestedOutputTokens, 1_024), reserveCeiling)
        self.windowTokens = normalizedWindow
        self.reservedOutputTokens = normalizedReserve
        self.inputLimitTokens = normalizedWindow - normalizedReserve
    }

    var remainingInputTokens: Int {
        max(inputLimitTokens - tokensBySegment.values.reduce(0, +), 0)
    }

    /// 历史最多只能占可输入空间的一部分，必须为当前问题和 RAG 分片留下位置。
    /// 这份规则同时供 Prompt Builder 与会话压缩策略使用，避免两处对“历史快满”的
    /// 判断漂移：前者悄悄裁掉原文，后者却还没有开始生成摘要。
    static func historyTokenLimit(
        contextWindowTokens: Int,
        requestedOutputTokens: Int
    ) -> Int {
        let budget = RAGContextBudget(
            contextWindowTokens: contextWindowTokens,
            requestedOutputTokens: requestedOutputTokens
        )
        return historyTokenLimit(
            remainingInputTokens: budget.inputLimitTokens,
            inputLimitTokens: budget.inputLimitTokens
        )
    }

    static func historyTokenLimit(
        remainingInputTokens: Int,
        inputLimitTokens: Int
    ) -> Int {
        min(remainingInputTokens, max(inputLimitTokens * 35 / 100, 512))
    }

    /// 截断并归属一个实际会进入请求的分段。返回的字符串就是调用方必须使用的文本，
    /// 不能再拿原始值拼 Prompt，否则 UI 会与真实请求脱节。
    mutating func consume(
        _ value: String,
        kind: RAGContextUsageSegmentKind,
        preferredLimit: Int? = nil
    ) -> String {
        let allowed = min(remainingInputTokens, preferredLimit ?? remainingInputTokens)
        let clipped = Self.clip(value, toTokenBudget: allowed)
        tokensBySegment[kind, default: 0] += TokenEstimator.estimate(text: clipped)
        return clipped
    }

    func usage(promptPreview: String) -> RAGContextUsage {
        var segments = tokensBySegment
        segments[.reservedOutput] = reservedOutputTokens
        return RAGContextUsage(
            windowTokens: windowTokens,
            reservedOutputTokens: reservedOutputTokens,
            tokensBySegment: segments,
            promptPreview: promptPreview
        )
    }

    /// 用二分而非简单的字符乘数截断：中文、代码与 URL 的 token 密度差异很大，只有
    /// 直接回测同一 `TokenEstimator` 才能保证最终估算不跨越请求预算。
    static func clip(_ value: String, toTokenBudget budget: Int) -> String {
        guard budget > 0 else { return "" }
        guard TokenEstimator.estimate(text: value) > budget else { return value }

        let suffix = "\n[truncated]"
        let suffixTokens = TokenEstimator.estimate(text: suffix)
        let suffixToUse = suffixTokens < budget ? suffix : ""
        let characters = Array(value)
        var lower = 0
        var upper = characters.count
        var best = ""
        while lower <= upper {
            let middle = (lower + upper) / 2
            let candidate = String(characters.prefix(middle)) + suffixToUse
            if TokenEstimator.estimate(text: candidate) <= budget {
                best = candidate
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        return best
    }
}
