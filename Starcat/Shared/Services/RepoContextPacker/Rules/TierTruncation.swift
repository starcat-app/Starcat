// MARK: - TierTruncation
//
// 文件内容截断规则的**唯一信息源** —— Tier 0 / Tier 1 / 单文件上限的常量 + 截断函数。
//
// 决议来源：`docs/详细设计/27-RepoContextPacker设计.md` §22.9 Q8。
//
// 5 个常量 + 1 个截断函数：
//   1. tier0MaxBytes        — Tier 0 单文件 100KB 硬上限（超出降级 Tier 2）
//   2. tier1MaxLines        — Tier 1 行数上限 80 行
//   3. tier1MaxChars        — Tier 1 字符数上限 4000（挡 minified JS 单行 10KB）
//   4. singleFileMaxBytes   — 任何 tier 单文件 5MB 硬上限（强制降级 Tier 2）
//   5. tier1Head(_:)        — 双约束 + 统一 `// ... [truncated: ...]` marker 截断
//
// 已踩过的坑（写入注释作为永久记录）：
//   - **换行归一**：`\r\n` / `\r` 必须先归一为 `\n`，否则 Windows 仓库 split 行数错乱
//   - **marker 用 `// ...` 不切语言**：实测 GPT-4 / Claude 都能跨语言 parse `// ...`，
//     按 Python `#` / HTML `<!--` 切会让 testing 复杂、易出错
//   - **空白字符串**：empty input 不能命中 truncate（exceedsLines=false / exceedsChars=false），
//     直接返回 `""`

import Foundation

public enum TierTruncation {

    // MARK: - 5 个常量

    /// Tier 0 单文件上限（100KB）。超出直接降级 Tier 2 + skippedFiles `tier0FileTooLarge`。
    /// 不降级为「头 N 行」—— 超大 README 头部是 logo + badge，无信息密度。
    public static let tier0MaxBytes = 100 * 1024

    /// Tier 1 行数上限（默认 80，未来可由用户在 AI 设置页调）。
    public static let tier1MaxLines = 80

    /// Tier 1 字符数上限（4000）。挡 minified JS / 压缩 CSS / 单行 SQL 大段等单行超长。
    /// 经验值：80 行 × 50 字符 = 4000。
    public static let tier1MaxChars = 4000

    /// 单源码文件上限（5MB）。任何 tier 触发，强制降级 Tier 2 + skippedFiles `singleFileTooLarge`。
    /// 与 `TierRules.singleFileMaxBytes` **同步常量**（写在两处避免 import 循环）。
    public static let singleFileMaxBytes = 5 * 1024 * 1024

    // MARK: - Tier 1 截断函数

    /// Tier 1 截断主入口：行数 80 + 字符数 4000 双约束。
    ///
    /// **算法**：
    ///   1. 换行归一：`\r\n` / `\r` → `\n`（防 Windows 仓库 split 错乱）
    ///   2. 都没超 → 返回归一后字符串（不加 marker，保持文件原样）
    ///   3. 按行截：取前 `tier1MaxLines` 行 joined
    ///   4. 字符数再 check：如果按行截后仍超 `tier1MaxChars`，再按字符卡
    ///   5. 追加 marker：
    ///      - 字符数超 → `// ... [truncated: exceeded 4000 chars]`
    ///      - 行数超   → `// ... [truncated: showing first 80 of N lines]`
    ///
    /// **不变量**：
    ///   - 返回字符串**始终** ≤ `tier1MaxChars` + marker 长度（约 60 字符）
    ///   - marker **始终**以 `\n\n//` 开头（前面空行让 LLM 视觉分隔清晰）
    ///   - 同一输入字符串多次调用结果完全一致（无随机 / 时间依赖）
    public static func tier1Head(_ text: String) -> String {
        // Step 1：换行归一
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Step 2：检查是否需要截断
        // 注意：split(omittingEmptySubsequences: false) 会保留尾随空行，line count 更准确
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let exceedsLines = lines.count > tier1MaxLines
        let exceedsChars = normalized.count > tier1MaxChars

        if !exceedsLines && !exceedsChars {
            return normalized
        }

        // Step 3：按行截
        var result = lines.prefix(tier1MaxLines).joined(separator: "\n")

        // Step 4：字符数再卡上限
        if result.count > tier1MaxChars {
            result = String(result.prefix(tier1MaxChars))
            return result + "\n\n// ... [truncated: exceeded \(tier1MaxChars) chars]\n"
        }

        // Step 5：行数超的 marker
        return result + "\n\n// ... [truncated: showing first \(tier1MaxLines) of \(lines.count) lines]\n"
    }
}
