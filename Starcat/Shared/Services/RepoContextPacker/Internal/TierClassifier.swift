// MARK: - DefaultTierClassifier
//
// Pass 2 第一步：给每个 FilteredFile 打 Tier 标签（0/1/2）。
//
// 决议来源：§22.9 Q8（Tier 0 100KB 上限降级）。
//
// 算法（按优先级从高到低）：
//   1. 精确名命中 `tier0ExactNames`（如 `README.md` / `LICENSE` / `package.json`）→ Tier 0
//   2. glob 命中 `tier0GlobPatterns`（如 `*.csproj` / `.github/workflows/*.yml`）→ Tier 0
//   3. glob 命中 `tier1GlobPatterns`（如 `src/index.ts` / `Sources/*/main.swift`）→ Tier 1
//   4. 其它 → Tier 2
//
// **Tier 0 100KB 上限**：
//   命中 Tier 0 后立刻 check `file.sizeBytes`，超 100KB → 强制降级 Tier 2 + 写 skippedFiles
//   reason = `tier0FileTooLarge`。原因：超大 README 头部是 logo + badge，无信息密度。
//
// 关键不变量：
//   - 同一 FilteredFile 多次 classify 结果完全一致（无随机 / 状态）
//   - 输出列表与输入顺序相同（caller 可能依赖此顺序）

import Foundation

public struct DefaultTierClassifier: TierClassifying {

    /// 预编译的 Tier 0 / Tier 1 glob regex 缓存。
    private let tier0Regexes: [NSRegularExpression]
    private let tier1Regexes: [NSRegularExpression]

    public init(
        tier0GlobPatterns: [String] = TierRules.tier0GlobPatterns,
        tier1GlobPatterns: [String] = TierRules.tier1GlobPatterns
    ) throws {
        self.tier0Regexes = try GlobCompiler.compileAll(tier0GlobPatterns)
        self.tier1Regexes = try GlobCompiler.compileAll(tier1GlobPatterns)
    }

    public func classify(files: [FilteredFile]) -> TierClassifyResult {
        var tieredFiles: [TieredFile] = []
        var skipped: [SkippedFile] = []
        tieredFiles.reserveCapacity(files.count)

        for file in files {
            let (tier, matchReason) = determineTier(file: file)

            // Tier 0 100KB 上限检查（§22.9）
            if tier == .zero && file.sizeBytes > TierTruncation.tier0MaxBytes {
                // 降级为 Tier 2 + 记 skippedFiles
                skipped.append(SkippedFile(
                    path: file.relativePath,
                    reason: SkipReason.tier0FileTooLarge,
                    tier: 0,
                    fileSize: file.sizeBytes
                ))
                tieredFiles.append(TieredFile(
                    file: file,
                    tier: .two,
                    matchReason: "demoted-from-tier0:tier0FileTooLarge"
                ))
                continue
            }

            tieredFiles.append(TieredFile(
                file: file,
                tier: tier,
                matchReason: matchReason
            ))
        }

        return TierClassifyResult(tieredFiles: tieredFiles, skippedFiles: skipped)
    }

    // MARK: - determineTier

    /// 决定单个 FilteredFile 的 Tier + 命中原因（仅调试用）。
    private func determineTier(file: FilteredFile) -> (Tier, String) {
        let relativePath = file.relativePath
        let filename = (relativePath as NSString).lastPathComponent

        // 1. 精确名命中 Tier 0
        if TierRules.tier0ExactNames.contains(filename) {
            return (.zero, "exact:\(filename)")
        }

        // 2. glob 命中 Tier 0
        for regex in tier0Regexes {
            if GlobCompiler.matches(regex, path: relativePath) {
                return (.zero, "tier0-glob:\(regex.pattern)")
            }
        }

        // 3. glob 命中 Tier 1
        for regex in tier1Regexes {
            if GlobCompiler.matches(regex, path: relativePath) {
                return (.one, "tier1-glob:\(regex.pattern)")
            }
        }

        // 4. 其它 → Tier 2
        return (.two, "default:tier2")
    }
}
