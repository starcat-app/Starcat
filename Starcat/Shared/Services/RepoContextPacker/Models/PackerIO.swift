// MARK: - Packer 输入 / 输出模型
//
// `RepoContextPacker.pack(_:)` 的入参 / 出参类型 + pipeline 内部传递的中间数据结构。
//
// 设计原则（§22.5 Q4 决议）：
//   - 全部 value type（struct）
//   - 每个 Pass 输入输出独立可断言（单测友好）
//   - Sendable 标注让跨 actor 边界安全
//
// 6 个核心类型：
//   1. PackInput     — `pack(_:)` 入参
//   2. PackOutput    — `pack(_:)` 出参
//   3. FilteredFile  — Pass 1 输出（FileFilter）
//   4. Tier          — Pass 2 标签（TierClassifier 给每个 FilteredFile 打的）
//   5. TieredFile    — Pass 2 输出（带 tier）
//   6. AllocatedPlan — Pass 2 末输出（BudgetAllocator 决定每个文件的处理策略）
//   7. ExtractedSourceDirectory — Pass 0 输出（解压后的根目录 + 清理闭包）
//   8. XmlBuildResult — Pass 3 输出（XML 字符串 + 真实 token 数 + warnings）
//   9. PackMetadata   — 写入 metadata.json 的完整模型
//   10. PackStats     — metadata.stats 子结构

import Foundation

// MARK: - 1. PackInput

/// `RepoContextPacker.pack(_:)` 入参。
///
/// 由 `RepoAIContextProvider`（未来集成 step）从 CodeFlow 共享 ZIP 快照层取到 zipURL，
/// 加上 owner/repo/commitSha 元信息以及 outputBaseDir 后构造。
public struct PackInput: Sendable {
    /// 源码 ZIP 文件 URL（来自 `repository-snapshots/<sha>.zip`，**只读**）。
    public let zipURL: URL

    /// 仓库 owner（如 `vapor`）。
    public let owner: String

    /// 仓库名（如 `vapor`）。
    public let repo: String

    /// 分支或 tag 引用（如 `main` / `v4.0.0`）。
    public let ref: String

    /// 完整 commit SHA（40 字符），写入 metadata 用。
    public let commitSha: String

    /// 输出根目录（产物会写到 `outputBaseDir/<owner>/<repo>/`）。
    /// 一般传 `Application Support/Starcat/analysis/`。
    public let outputBaseDir: URL

    /// Token budget 上限（默认 8000，用户可在 AI 设置页调）。
    public let tokenBudget: Int

    /// Tier 1 文件头部保留行数（X3 引入，2026-06-13）。
    ///
    /// 默认 80 行，对应 `TierTruncation.tier1MaxLines` 的历史值。允许用户通过
    /// `AppSettings.aiRepoContextTier1MaxLines` 改成 40-200。
    ///
    /// **关键约束**：
    ///   - 字符数上限 `tier1MaxChars=4000` 不参数化（§22.9 决议双约束语义，行数 + 字符数共同决定截断点）；
    ///   - 增大此值会让单个 Tier 1 文件估算 token 翻倍，由 `BudgetAllocator` 在 Plan 阶段统一约束；
    ///   - 写入 `PackMetadata.tier1MaxLines`，W6 `RepoContextStorage.lookupMetadata` 把它纳入
    ///     缓存命中判断（用户调过 settings 后旧 metadata 失效，强制重 pack）。
    public let tier1MaxLines: Int

    public init(
        zipURL: URL,
        owner: String,
        repo: String,
        ref: String,
        commitSha: String,
        outputBaseDir: URL,
        tokenBudget: Int = 8000,
        tier1MaxLines: Int = 80
    ) {
        self.zipURL = zipURL
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.commitSha = commitSha
        self.outputBaseDir = outputBaseDir
        self.tokenBudget = tokenBudget
        self.tier1MaxLines = tier1MaxLines
    }
}

// MARK: - 2. PackOutput

/// `RepoContextPacker.pack(_:)` 出参 —— pipeline 成功后的产物索引。
public struct PackOutput: Sendable, Equatable {
    /// `context.xml` 绝对路径（给 LLM 看）。
    public let contextURL: URL

    /// `metadata.json` 绝对路径（给 Starcat 自己看：调试、UI 展示、数据管理）。
    public let metadataURL: URL

    /// 实际写入 metadata 的 stats 副本，方便 caller 直接拿统计数据（不必再读 JSON）。
    public let stats: PackStats

    /// 生成时间（也写入 metadata.generatedAt）。
    public let generatedAt: Date
}

// MARK: - 3. FilteredFile

/// Pass 1 FileFilter 输出 —— 经过 ignore + 安全防护后保留的候选文件。
///
/// **不含文件内容**（懒读决议 §22.5 Q4），只有路径元信息 + size。
public struct FilteredFile: Sendable, Equatable {
    /// 相对仓库根的路径（POSIX `/`，如 `src/index.swift`）。
    public let relativePath: String

    /// 绝对路径 URL（在解压临时目录内）。
    public let absoluteURL: URL

    /// 文件大小（bytes）。
    public let sizeBytes: Int
}

// MARK: - 4. Tier

/// 文件分级标签。
///
/// `rawValue` 直接对应 XML 输出的 `tier` 属性（0/1/2）。
public enum Tier: Int, Sendable, Comparable {
    /// 全文输出（Tier 0：README / LICENSE / package.json / Dockerfile 等）。
    case zero = 0

    /// 头 80 行 + 4000 字符双约束截断（Tier 1：明确入口文件如 `src/index.ts` / `src/main.swift`）。
    case one = 1

    /// 仅路径列入 `<fileList>`，不读内容（Tier 2：其它源码）。
    case two = 2

    public static func < (lhs: Tier, rhs: Tier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 5. TieredFile

/// Pass 2 TierClassifier 输出 —— FilteredFile 打上 Tier 标签。
public struct TieredFile: Sendable, Equatable {
    public let file: FilteredFile
    public let tier: Tier

    /// 命中的具体规则（如 `exact:package.json` / `glob:src/main.*` / `default:tier2`），仅用于调试。
    public let matchReason: String
}

// MARK: - 6. AllocatedPlan

/// 单个文件的处理策略。
public enum FileStrategy: Sendable, Equatable {
    /// Tier 0 默认：读全文。
    case fullContent

    /// Tier 1 默认：头 80 行 + 4000 字符双约束截断。
    case headTruncated

    /// Tier 2 默认：只列路径，不读内容。
    case pathOnly
}

/// 单个文件的分配结果（带 strategy + 估算 token 数）。
public struct AllocatedFile: Sendable, Equatable {
    public let tieredFile: TieredFile
    public let strategy: FileStrategy

    /// Pass 2 估算的 token 数（基于 size × 0.27）。
    /// Pass 3 真读后会得到 `actualTokens`，但本字段保留作为 Plan 时刻的快照。
    public let estimatedTokens: Int
}

/// Pass 2 BudgetAllocator 输出 —— pipeline 的「执行计划」。
///
/// Pass 3 XmlOutputBuilder 直接消费本结构，按 `items` 顺序生成 XML 段落。
public struct AllocatedPlan: Sendable {
    /// 全部 allocated 文件（按 path 字典序排序，保证 XML 输出顺序可重现）。
    public let items: [AllocatedFile]

    /// Tier 2 中**未被截断**的文件路径列表（按 §6.2 三档截断策略）。
    /// 这部分文件不在 `items` 里（items 只含 Tier 0/1 + Tier 2 截断后保留的路径）。
    /// **注**：MVP 简化为 items 含全部 Tier 2 截断后保留路径，本字段保留为 future-proof。
    public let tier2TruncatedCount: Int

    /// Plan 阶段累计估算的 token 数。
    public let totalEstimatedTokens: Int

    /// 配置快照（写入 metadata 用）。
    public let budget: Int
}

// MARK: - 7. ExtractedSourceDirectory

/// Pass 0 SourceZipExtractor 输出 —— 解压后的根目录引用 + 清理闭包。
///
/// **关键约束**：
///   - `rootURL` 是「真正的项目根目录」（已经识别过 GitHub source ZIP 一层 wrapper / flat layout）
///   - `cleanup` 是 idempotent 闭包，pipeline 必须用 `defer { extracted.cleanup() }` 在任何分支下保证执行
///   - cleanup 失败不抛错（最坏情况：磁盘上留个 UUID 临时目录，OS reboot 自动清）
public struct ExtractedSourceDirectory: Sendable {
    public let rootURL: URL

    /// 清理闭包（删除解压临时目录）。
    /// 用 `@Sendable` 让闭包能跨 actor / Task 传递；用 `() -> Void` 不抛错避免污染 defer。
    public let cleanup: @Sendable () -> Void

    public init(rootURL: URL, cleanup: @escaping @Sendable () -> Void) {
        self.rootURL = rootURL
        self.cleanup = cleanup
    }
}

// MARK: - 8. XmlBuildResult

/// Pass 3 XmlOutputBuilder 输出。
public struct XmlBuildResult: Sendable {
    /// 完整 XML 字符串（已 UTF-8 化，可直接写盘）。
    public let xml: String

    /// 真实 token 数（基于 char count，写入 metadata.stats.actualTokens）。
    public let actualTokens: Int

    /// Pass 3 期间累积的 skippedFiles（如 NUL 字节探测发现 binary、读失败）。
    public let skippedFiles: [SkippedFile]

    /// 警告（如 `actualTokensExceededBudget`），写入 metadata.warnings。
    public let warnings: [String]
}

// MARK: - 9. PackMetadata（写入 metadata.json）

/// `metadata.json` 的完整结构（§22.10 Q9 决议 + 2026-06-13 W7 扩字段）。
///
/// **W7 扩字段（2026-06-13）**：
///   - `tier1MaxLines` / `lastAccessedAt` / `generationCount` 三个新增字段全部
///     声明为 Optional，**保证向后兼容**——旧版 `metadata.json`（不含这些字段）
///     反序列化时为 nil，UI / 缓存命中逻辑要做空值兜底。
///   - 加字段不 bump `schemaVersion`：Optional 即兼容，无需走 migration 路径。
public struct PackMetadata: Codable, Sendable {
    public let schemaVersion: Int
    public let tierRulesVersion: String
    public let tokenEstimatorVersion: String
    public let owner: String
    public let repo: String
    public let ref: String
    public let commitSha: String

    /// ISO-8601 with `Z` 后缀（UTC）。
    public let generatedAt: String

    public let tokenBudget: Int
    public let stats: PackStats
    public let skippedFiles: [SkippedFile]
    public let warnings: [String]

    // MARK: - W7 扩字段（向后兼容）

    /// W7：Tier 1 头部保留行数（来自 `PackInput.tier1MaxLines`）。
    ///
    /// `RepoAIContextProvider` 命中缓存的判定要求 `commitSha + tokenBudget +
    /// tier1MaxLines + tierRulesVersion` 全部一致。用户在 settings 里调整 Tier 1
    /// 行数后旧 metadata 自动失效，强制重 pack。
    ///
    /// 旧 metadata.json 反序列化时为 nil（默认按 `TierTruncation.tier1MaxLines`
    /// 也就是 80 处理；nil 时缓存判定额外检查 `settings 当前值 == 80` 才命中）。
    public let tier1MaxLines: Int?

    /// W7：最近一次被 AI 摘要消费的时间（ISO-8601 with `Z`）。
    ///
    /// 用于 StorageSettingsTab 按"最近使用"排序，以及未来 V2 加 LRU 自动清理。
    /// 每次 `RepoAIContextProvider.context(for:)` 命中缓存或 pack 完成都会被刷新。
    public let lastAccessedAt: String?

    /// W7：累计生成次数（首次写盘 1，后续 `existing.generationCount + 1`）。
    ///
    /// 用于 StorageSettingsTab 的 "累计生成 N 次" 统计列，给用户直观反馈"这个
    /// 仓库被反复重打了多少次"（重 pack 一般意味着 settings 调过 / commit 变了）。
    public let generationCount: Int?

    public init(
        schemaVersion: Int,
        tierRulesVersion: String,
        tokenEstimatorVersion: String,
        owner: String,
        repo: String,
        ref: String,
        commitSha: String,
        generatedAt: String,
        tokenBudget: Int,
        stats: PackStats,
        skippedFiles: [SkippedFile],
        warnings: [String],
        tier1MaxLines: Int? = nil,
        lastAccessedAt: String? = nil,
        generationCount: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tierRulesVersion = tierRulesVersion
        self.tokenEstimatorVersion = tokenEstimatorVersion
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.commitSha = commitSha
        self.generatedAt = generatedAt
        self.tokenBudget = tokenBudget
        self.stats = stats
        self.skippedFiles = skippedFiles
        self.warnings = warnings
        self.tier1MaxLines = tier1MaxLines
        self.lastAccessedAt = lastAccessedAt
        self.generationCount = generationCount
    }
}

// MARK: - 10. PackStats（metadata.stats 子结构）

public struct PackStats: Codable, Sendable, Equatable {
    public let totalFiles: Int
    public let tier0Count: Int
    public let tier1Count: Int
    public let tier2Count: Int
    public let estimatedTokens: Int
    public let actualTokens: Int

    /// context.xml 字节大小（写盘后回填）。
    public let contextXmlBytes: Int

    public init(
        totalFiles: Int,
        tier0Count: Int,
        tier1Count: Int,
        tier2Count: Int,
        estimatedTokens: Int,
        actualTokens: Int,
        contextXmlBytes: Int
    ) {
        self.totalFiles = totalFiles
        self.tier0Count = tier0Count
        self.tier1Count = tier1Count
        self.tier2Count = tier2Count
        self.estimatedTokens = estimatedTokens
        self.actualTokens = actualTokens
        self.contextXmlBytes = contextXmlBytes
    }
}
