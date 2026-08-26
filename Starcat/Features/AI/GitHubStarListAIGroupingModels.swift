//
//  GitHubStarListAIGroupingModels.swift
//  Starcat
//
//  GitHub Lists AI 分组的数据边界与封闭候选集校验。
//
//  模块职责：
//  - 冻结一次 AI 分组任务可见的现有 Lists 与用户规则；
//  - 定义模型返回的结构化建议；
//  - 在任何 GitHub 写入前收敛未知 List、重复建议和已有 membership。
//
//  关键约束：模型输出始终是不可信输入。只有用户预先创建、规则非空且本轮明确
//  提供的 list ID 才能成为有效建议；本文件不提供创建、删除或移除 membership 的动作。
//

import Foundation

/// 一次 AI 分组任务中的现有 List 快照。
struct GitHubStarListAIContext: Encodable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { listId }

    let listId: String
    let name: String
    let instruction: String
    /// 仅由本地执行层读取，不能作为模型分类信号写进 Prompt。
    let autoApplyEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case name
        case instruction
    }
}

/// AI 对一个 repo-list 关系给出的可审核建议。
struct GitHubStarListAISuggestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { listId }

    let listId: String
    let confidence: Double
    let reason: String

    private enum CodingKeys: String, CodingKey {
        case listId = "list_id"
        case confidence
        case reason
    }
}

/// 批量队列一次运行所需的 Lists 快照。
struct GitHubStarListAIGroupingConfiguration: Equatable, Sendable {
    let candidates: [GitHubStarListAIContext]
    let existingListIDsByRepo: [Int64: Set<String>]
    /// Auto Tidy 合并“未打标签仓库”和“全部 Stars”两个范围时，用它限制 Lists 子任务。
    /// nil 表示手动模式中的全部入队仓库。
    let eligibleRepoIDs: Set<Int64>?
    /// true 只用于用户明确开启的后台 Auto Tidy；手动审核必须保持 false。
    let autoApply: Bool
    /// 自动分组始终需要阈值，即使用户为旧的自动标签关闭了“使用阈值”。手动审核为 nil。
    let confidenceThreshold: Double?

    init(
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        eligibleRepoIDs: Set<Int64>?,
        autoApply: Bool,
        confidenceThreshold: Double? = nil
    ) {
        self.candidates = candidates
        self.existingListIDsByRepo = existingListIDsByRepo
        self.eligibleRepoIDs = eligibleRepoIDs
        self.autoApply = autoApply
        self.confidenceThreshold = confidenceThreshold
    }

    var hasCandidates: Bool {
        candidates.contains { !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// 封闭候选集的最终执行边界。
enum GitHubStarListAISuggestionPolicy {
    /// 清洗模型建议，并且只返回本轮候选集内、尚未存在的新增 membership。
    ///
    /// 同一 List 重复出现时保留最高置信度项；这不会扩大模型权限，只让偶发重复 JSON
    /// 有确定结果。reason 只用于审核展示，截断后不会进入执行判断或诊断日志。
    static func validatedSuggestions(
        _ suggestions: [GitHubStarListAISuggestion],
        candidates: [GitHubStarListAIContext],
        existingListIDs: Set<String>
    ) -> [GitHubStarListAISuggestion] {
        let allowedIDs = Set(candidates.compactMap { candidate -> String? in
            let instruction = candidate.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return instruction.isEmpty ? nil : candidate.listId
        })

        var bestByListID: [String: GitHubStarListAISuggestion] = [:]
        for suggestion in suggestions {
            guard allowedIDs.contains(suggestion.listId),
                  !existingListIDs.contains(suggestion.listId),
                  suggestion.confidence.isFinite,
                  (0...1).contains(suggestion.confidence)
            else { continue }

            let reason = suggestion.reason
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = GitHubStarListAISuggestion(
                listId: suggestion.listId,
                confidence: suggestion.confidence,
                reason: reason.count > 240 ? String(reason.prefix(237)) + "…" : reason
            )
            if let current = bestByListID[suggestion.listId],
               current.confidence >= normalized.confidence {
                continue
            }
            bestByListID[suggestion.listId] = normalized
        }

        return bestByListID.values.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.listId < $1.listId
        }
    }

    /// 自动模式的第二道执行门：只保留 List 级开关开启且达到阈值的已校验建议。
    static func automaticSuggestions(
        from validatedSuggestions: [GitHubStarListAISuggestion],
        candidates: [GitHubStarListAIContext],
        confidenceThreshold: Double
    ) -> [GitHubStarListAISuggestion] {
        let autoEnabledIDs = Set(candidates.filter(\.autoApplyEnabled).map(\.listId))
        return validatedSuggestions.filter {
            autoEnabledIDs.contains($0.listId) && $0.confidence >= confidenceThreshold
        }
    }

    /// 把审核页选择转换成可执行 List 集合。没有显式确认时始终返回空集合，且即使
    /// 调用方传入未知选择，也只能落在本轮已展示的建议闭集中。
    static func confirmedListIDs(
        from suggestions: [GitHubStarListAISuggestion],
        selectedListIDs: Set<String>,
        confirmationGranted: Bool
    ) -> Set<String> {
        guard confirmationGranted else { return [] }
        return Set(suggestions.map(\.listId)).intersection(selectedListIDs)
    }
}
