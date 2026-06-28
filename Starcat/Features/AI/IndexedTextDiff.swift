//
//  IndexedTextDiff.swift
//  Starcat
//
//  判定向量索引是否需要重建的差分算法（决策 F2，详见 `docs/3-设计/详细设计/26-向量搜索改进.md`）。
//
//  模块职责：
//  - 输入 `(old: IndexedSnapshot?, new: IndexedSnapshot, thresholds: DiffThresholds)`，
//    输出 `Bool`：是否要调 embedding API 重建向量。
//
//  关键约束：
//  - **取代旧的 SHA256 hash 全等比对**。旧方案对 stars / forks 等高频字段过敏，每次同步
//    就误触发，烧 API 配额。新方案：metadata 任一变更立刻重建；body / notes 走行级
//    diff，比例超阈值才重建。
//  - **不实现 Myers diff 等结构化算法**：实测 README 量级（1-12k 行）下，集合差集
//    （`symmetricDifference`）已经足够。决策点不是"diff 是否最小化"，而是"变化量是否
//    跨阈值"——集合差集对插入大量重复行（如 changelog 追加）会高估变化量，但这
//    恰恰是我们希望的"重要变化要重建"，所以是一个 trade-off 而不是 bug。
//  - **阈值闭区间向上**：`changed_lines / total_lines > threshold`（严格大于），与
//    设计文档保持一致。等于阈值时**不**重建，避免 0.10 / 0.10 边界震荡。
//  - `total_lines == 0` 的边界：旧 body 为空但新 body 非空时，必须返回 true（认为
//    "从无到有就是 100% 变更"，确保用户首次写完 README / 摘要后立即上索引）。
//

import Foundation

/// 三档阈值预设 + 折叠区暴露的具体数字（决策 G）。
///
/// - `bodyDiffRatio`：主体 diff 比例阈值（默认 0.10 = 10%）
/// - `notesDiffRatio`：笔记 diff 比例阈值（默认 0.20 = 20%）
///
/// 默认值为何 body 比 notes 严格：
/// - body 长且语义稳定，10% 的变化已经足够触发"明显内容修订"；
/// - notes 是用户随手改的小本子，常见的"加一行 TODO" / "改个错别字"如果按 10% 触发，
///   每改一次都全量重算向量，体验和成本都不划算；20% 更宽容。
struct DiffThresholds: Equatable, Sendable {
    var bodyDiffRatio: Double
    var notesDiffRatio: Double

    static let `default` = DiffThresholds(bodyDiffRatio: 0.10, notesDiffRatio: 0.20)
}

/// AI 索引阈值预设（决策 G：严格 5% / 标准 10% / 宽松 20%）。
/// Settings UI 折叠区允许用户在预设之外自定义具体数字（写入 `AppSettings.aiIndexBodyDiffRatio`
/// 与 `aiIndexNotesDiffRatio`），此时 `preset` 字段保持为 `custom`，避免 UI 显示混乱。
enum AIIndexPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case strict
    case standard
    case relaxed
    case custom

    var id: String { rawValue }

    var thresholds: DiffThresholds {
        switch self {
        case .strict:
            return DiffThresholds(bodyDiffRatio: 0.05, notesDiffRatio: 0.10)
        case .standard:
            return DiffThresholds(bodyDiffRatio: 0.10, notesDiffRatio: 0.20)
        case .relaxed:
            return DiffThresholds(bodyDiffRatio: 0.20, notesDiffRatio: 0.30)
        case .custom:
            return .default
        }
    }

    var displayNameKey: String {
        switch self {
        case .strict:   return "settings.aiIndex.diffPreset.strict"
        case .standard: return "settings.aiIndex.diffPreset.standard"
        case .relaxed:  return "settings.aiIndex.diffPreset.relaxed"
        case .custom:   return "settings.aiIndex.diffPreset.custom"
        }
    }
}

enum IndexedTextDiff {

    /// 判定是否需要重建向量。
    ///
    /// 决策顺序：
    /// 1. `old == nil` → true（首次索引）
    /// 2. metadata 任一字段不等 → true（元数据变更即重建）
    /// 3. body 行级 diff 比例 > `bodyDiffRatio` → true
    /// 4. notes 行级 diff 比例 > `notesDiffRatio` → true
    /// 5. 否则 → false
    static func shouldRebuild(
        old: IndexedSnapshot?,
        new: IndexedSnapshot,
        thresholds: DiffThresholds
    ) -> Bool {
        guard let old else { return true }
        if old.metadata != new.metadata { return true }
        if lineDiffRatio(old: old.body, new: new.body) > thresholds.bodyDiffRatio {
            return true
        }
        let oldNotes = old.notes ?? ""
        let newNotes = new.notes ?? ""
        if lineDiffRatio(old: oldNotes, new: newNotes) > thresholds.notesDiffRatio {
            return true
        }
        return false
    }

    // MARK: - 行级 diff

    /// 行级 diff 比例：`|sym_diff| / max(|old_lines|, |new_lines|)`。
    ///
    /// - 旧空 + 新空 → 0（视为完全没变）
    /// - 旧空 + 新非空 → 1.0（从无到有）
    /// - 旧非空 + 新空 → 1.0（从有到无，比如笔记全删）
    /// - 否则用 multiset 思想：拆行 → 各自 Set → 对称差 / max(行数)
    ///
    /// 为何用 max 做分母（不是 union 也不是 old）：
    /// - 分母用 old：删光所有行后 new 是空集，对称差 == old 行数，比例 == 1.0，对；
    ///   但 new 巨幅追加（changelog 加 100 行）时分母仍是 old 几行，比例可能 > 1.0，
    ///   超出语义。
    /// - 分母用 union：在大量重复行下高估"没变"的部分，让阈值变得过宽。
    /// - 分母用 max：天然落在 [0, 1] 区间，单调直观，与 dong4j 描述"相差的字符行数 /
    ///   总行数"语义吻合。
    static func lineDiffRatio(old: String, new: String) -> Double {
        let oldLines = nonEmptyLines(old)
        let newLines = nonEmptyLines(new)
        if oldLines.isEmpty && newLines.isEmpty { return 0 }
        if oldLines.isEmpty || newLines.isEmpty { return 1 }
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let symDiff = oldSet.symmetricDifference(newSet)
        let denominator = Double(max(oldLines.count, newLines.count))
        guard denominator > 0 else { return 0 }
        return Double(symDiff.count) / denominator
    }

    /// 按 `\n` 切分并 trim、丢空行。
    /// 丢空行是为了让"插入一段空行"这种纯格式调整不被算成变化。
    private static func nonEmptyLines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
