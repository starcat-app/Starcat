// MARK: - TokenEstimator
//
// 两阶段 token 估算策略（§22.8 Q7 决议）：
//   - **Pass 2**：用 `file.size × 0.27` 估算（**不读内容**），喂给 BudgetAllocator 做 plan
//   - **Pass 3**：用真 `text.count × 0.27` 校准，写入 `metadata.stats.actualTokens`
//
// 经验系数 0.27 来源：repomix 实测 GPT-4 tokenizer（gpt-tokenizer o200k_base）在英文 + 代码
// 混合语料的均值。误差 ±10%（中文文本会高估约 30%，但中文代码极少；纯英文代码偏差最小）。
//
// V2 升级路径：保留 protocol-style 接口未来切 tiktoken-swift 时只换实现，metadata 里的
// `tokenEstimatorVersion` 字符串会自动从 `char-x-0.27` 变成 `tiktoken-cl100k`，旧产物可识别。
//
// **不变量**：
//   - estimate(byteCount:) 和 estimate(text:) 都用相同系数（保证 Pass 2 / Pass 3 公式一致）
//   - 系数从 `TierRules.charToTokenRatio` 取，单点修改

import Foundation

public enum TokenEstimator {

    /// **Pass 2 用**：基于 byte size 估算（零 IO）。
    ///
    /// 假设 ASCII 主导（源码 / 配置）；中文 README 会高估 3x，但 README 是 Tier 0 全文，
    /// 高估只会让 BudgetAllocator **更保守地**少 include Tier 1，对结果无害。
    public static func estimate(byteCount: Int) -> Int {
        max(0, Int(Double(byteCount) * TierRules.charToTokenRatio))
    }

    /// **Pass 3 用**：基于 char count 精确算（写入 metadata.stats.actualTokens）。
    public static func estimate(text: String) -> Int {
        max(0, Int(Double(text.count) * TierRules.charToTokenRatio))
    }

    /// Tier 1 头 80 行的估算上限（用经验值 80 行 × 50 字符 卡顶）。
    ///
    /// 例：文件 size = 30000 bytes（30KB），byte 估算 = 8100 token
    ///   但 Tier 1 只读头 80 行，实际不会超过 1080 token（80 × 50 × 0.27）。
    ///   所以返回 min(8100, 1080) = 1080，让 BudgetAllocator 更准确地预算。
    public static func estimateTier1Head(byteCount: Int) -> Int {
        let fullEstimate = estimate(byteCount: byteCount)
        let headCap = estimate(byteCount: TierTruncation.tier1MaxLines * 50)
        return min(fullEstimate, headCap)
    }
}
