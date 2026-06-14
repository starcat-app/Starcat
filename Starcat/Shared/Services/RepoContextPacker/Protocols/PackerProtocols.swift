// MARK: - Packer 接口集
//
// pipeline 的 8 个模块全部以 protocol 定义，便于：
//   1. 单测注入 mock
//   2. V2 切换实现（如 TokenEstimator 切 tiktoken-swift / TierClassifier 切 tree-sitter）
//
// 模块签名严格按 §22.5 Q4 决议：
//   - Extractor / XmlOutputBuilder / Writer / Facade 标 `async throws`（含磁盘 IO 或 TaskGroup）
//   - 其余同步 `throws`（纯函数 / 算法）

import Foundation

// MARK: - Pass 0：SourceZipExtractor

public protocol SourceZipExtracting: Sendable {
    /// 把 ZIP 解压到临时目录，返回根目录引用 + cleanup 闭包。
    ///
    /// - Important: caller 必须用 `defer { extracted.cleanup() }` 保证清理。
    /// - Throws: `RepoContextPackerError.zip*` 系列致命错。
    func extract(_ zipURL: URL) async throws -> ExtractedSourceDirectory
}

// MARK: - Pass 1：FileFilter

public protocol FileFiltering: Sendable {
    /// 递归 walk 解压目录，应用 ignore 规则 + 安全防护，返回候选文件清单 + skipped 记录。
    ///
    /// - Note: 不读文件内容（懒读决议，§22.5 Q4），只 stat metadata。
    /// - Throws: `RepoContextPackerError.zipSlipDetected` / `.noFilesAfterFiltering`
    func scan(rootURL: URL) throws -> FileFilterResult
}

/// FileFilter 输出：候选文件清单 + 同时累积的 skipped 记录（symlink / 单文件 5MB 超限）。
public struct FileFilterResult: Sendable {
    public let files: [FilteredFile]
    public let skippedFiles: [SkippedFile]
}

// MARK: - Pass 2：TierClassifier

public protocol TierClassifying: Sendable {
    /// 给每个 FilteredFile 打 Tier 标签。
    ///
    /// 同时识别「Tier 0 候选但超 100KB」→ 返回降级到 Tier 2 + 追加 skippedFiles 记录。
    func classify(files: [FilteredFile]) -> TierClassifyResult
}

public struct TierClassifyResult: Sendable {
    public let tieredFiles: [TieredFile]
    public let skippedFiles: [SkippedFile]
}

// MARK: - Pass 2：BudgetAllocator

public protocol BudgetAllocating: Sendable {
    /// 按 Tier 优先级 + Token Budget 贪心分配每个文件的 strategy（全文 / 头 80 行 / 仅路径）。
    func allocate(_ tieredFiles: [TieredFile], budget: Int) -> AllocatedPlan
}

// MARK: - Pass 2/3：DirectoryTreeBuilder

public protocol DirectoryTreeBuilding: Sendable {
    /// 基于 FilteredFile 列表生成缩进列表格式的目录树（不读内容）。
    /// 缩进列表（不是 ASCII tree）—— §22.10 反对意见中决议「省 token，等价信息」。
    func build(_ files: [FilteredFile]) -> String
}

// MARK: - Pass 3：XmlOutputBuilder

public protocol XmlOutputBuilding: Sendable {
    /// Pass 3：并发读 Tier 0/1 文件内容（cap 8）→ 真 token 估算 → 拼装 XML。
    ///
    /// - Parameters:
    ///   - plan: BudgetAllocator 的执行计划
    ///   - directoryTree: DirectoryTreeBuilder 已生成的字符串
    ///   - metadata: 根元素需要的 owner/repo/sha 等
    ///   - tier1MaxLines: X3 引入（2026-06-13），Tier 1 头部行数运行期 override
    ///     （默认 80，用户可在 AI 设置页调）
    /// - Returns: XmlBuildResult（含 xml / actualTokens / skippedFiles / warnings）
    func build(
        plan: AllocatedPlan,
        directoryTree: String,
        metadata: XmlMetadata,
        tier1MaxLines: Int
    ) async throws -> XmlBuildResult
}

extension XmlOutputBuilding {
    /// 兼容旧签名：不传 tier1MaxLines 时按默认 80 处理（与 X3 之前行为完全一致）。
    /// 测试代码大量调用旧签名，保留这个 extension 避免改一片单测。
    public func build(
        plan: AllocatedPlan,
        directoryTree: String,
        metadata: XmlMetadata
    ) async throws -> XmlBuildResult {
        try await build(
            plan: plan,
            directoryTree: directoryTree,
            metadata: metadata,
            tier1MaxLines: TierTruncation.tier1MaxLines
        )
    }
}

/// XmlOutputBuilder 需要的元数据子集（避免传整个 PackInput / PackMetadata）。
public struct XmlMetadata: Sendable {
    public let owner: String
    public let repo: String
    public let ref: String
    public let commitSha: String
    public let generatedAt: Date
    public let tokenBudget: Int

    public init(
        owner: String, repo: String, ref: String, commitSha: String,
        generatedAt: Date, tokenBudget: Int
    ) {
        self.owner = owner
        self.repo = repo
        self.ref = ref
        self.commitSha = commitSha
        self.generatedAt = generatedAt
        self.tokenBudget = tokenBudget
    }
}

// MARK: - Pass 4：ContextWriter

public protocol ContextWriting: Sendable {
    /// 原子写盘：`context.xml` + `metadata.json` 到 `outputBaseDir/<owner>/<repo>/`。
    /// 用 `.tmp → rename` 保证半成品不被消费方读到。
    ///
    /// - Throws: `RepoContextPackerError.outputDirectoryNotWritable` / `.writeFailed`
    func write(
        xml: String,
        metadata: PackMetadata,
        outputBaseDir: URL,
        owner: String,
        repo: String
    ) async throws -> PackOutput
}
