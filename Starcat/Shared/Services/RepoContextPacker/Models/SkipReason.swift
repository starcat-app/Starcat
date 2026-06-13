// MARK: - SkipReason
//
// 单文件错误的「reason」字符串常量。
//
// 与 `RepoContextPackerError`（致命错抛出）形成「分层错误处理」：
//   - 致命错误 → 抛 `RepoContextPackerError`
//   - 单文件错误 → skip 并把 `reason` 写入 `metadata.json.skippedFiles[]`
//
// 决议来源：`docs/详细设计/27-RepoContextPacker设计.md` §22.4（Q3 / 分层错误处理）。
//
// **关键约束**：reason 是写入 `metadata.json` 的字符串，不能改！如果产品演进想改 reason 名字，
// 必须在 §22.4 同步更新「reason 字符串 → 含义」对照表，否则旧 metadata 读不出来。

import Foundation

/// 单文件 skip 的原因常量（写入 `metadata.json.skippedFiles[].reason`）。
///
/// 共 6 类 reason，**严格对应** §22.4 决议；新增时必须同步设计文档。
public enum SkipReason {
    /// NUL 字节探测发现是 binary 文件。
    public static let binaryDetected = "binaryDetected"

    /// Tier 0 候选文件超出 100KB 硬上限（§22.9 Q8 决议）。
    /// 超大 README 头部是 logo + badge，无信息密度，直接降级为 Tier 2（仅路径）。
    public static let tier0FileTooLarge = "tier0FileTooLarge"

    /// 单源码文件超出 5MB 硬上限（§22.11 Q10 决议）。
    /// 任何 tier 触发，强制降级为 Tier 2（仅路径）。
    public static let singleFileTooLarge = "singleFileTooLarge"

    /// 检测到 symlink，全部跳过（§22.11 Q10 决议）。
    /// 跟随 symlink 有沙箱外读取的安全风险，MVP 一律跳过。
    public static let symlinkSkipped = "symlinkSkipped"

    /// 文件读取失败（权限 / 文件突然消失 / 损坏的 symlink / I/O 错误）。
    public static let fileReadFailed = "fileReadFailed"

    /// 文本编码识别失败（UTF-8 decode 失败的非 UTF-8 文件）。
    /// MVP 不支持 UTF-16 / UTF-32 / latin-1，遇到一律跳过。
    public static let encodingDetectionFailed = "encodingDetectionFailed"
}

// MARK: - SkippedFile（写入 metadata.json 的单条记录）

/// `metadata.json.skippedFiles[]` 的单条记录。
///
/// 设计权衡：
/// - `tier` 用 `Int?` 而非 `Tier?` 枚举，因为 `Tier` 是内部类型 + 想保留 nil 语义（symlink 没 tier）
/// - `fileSize` 可选：tier0FileTooLarge / singleFileTooLarge 才有意义
/// - 字段名小驼峰，与 metadata.json 整体风格对齐
public struct SkippedFile: Codable, Sendable, Equatable {
    /// 相对仓库根的路径（POSIX `/`）。
    public let path: String

    /// SkipReason 字符串常量。
    public let reason: String

    /// Tier 数字（0/1/2），nil 表示尚未 classify 或与 tier 无关（如 symlink）。
    public let tier: Int?

    /// 文件大小（仅 `tier0FileTooLarge` / `singleFileTooLarge` 写入）。
    public let fileSize: Int?

    public init(path: String, reason: String, tier: Int?, fileSize: Int? = nil) {
        self.path = path
        self.reason = reason
        self.tier = tier
        self.fileSize = fileSize
    }
}
