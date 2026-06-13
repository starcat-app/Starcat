// MARK: - RepoContextPackerError
//
// Packer pipeline 的致命错误枚举（**抛出 → 中断整个 pipeline**）。
//
// ⚠️ 与「单文件错误」严格分离：
//   - 致命错误（本枚举）= 解压失败 / 输出目录不可写 / Zip slip 检测 / 取消等，整条 pipeline 没法继续 → 抛出
//   - 单文件错误（非致命）= 单个奇葩文件读不出来 / NUL 字节探测发现 binary / Tier 0 超 100KB 等
//     → **不抛**，走 `metadata.json.skippedFiles[]` 数组（reason 用 `SkipReason` 字符串常量）
//
// 决议来源：`docs/详细设计/27-RepoContextPacker设计.md` §22.4（Q3 / 分层错误处理）。
//
// 本枚举共 11 个 case，**严格对应** §22.4 的「致命错误清单」。新增 case 必须：
//   1. 确认是「致命」级别（pipeline 没法继续）
//   2. 同步更新 §22.4 文档
//   3. 同步本地化（localized `errorDescription`，未来 i18n 阶段处理）

import Foundation

public enum RepoContextPackerError: LocalizedError, Sendable {
    // MARK: - Pass 0 解压阶段（致命）

    /// 输入 ZIP 文件不存在或 size = 0。
    case zipFileNotFound(URL)

    /// ZIP 文件 size 超出上限（默认 100MB，见 `TierRules.zipMaxBytes`）。
    /// GitHub source ZIP 极少 > 50MB，超 100MB 大概率不是源码包。
    case zipTooLarge(actualBytes: Int, maxBytes: Int)

    /// 解压后总大小超出上限（默认 500MB，见 `TierRules.extractedMaxBytes`）。
    /// 这是 ZIP bomb 的兜底：恶意 ZIP 解出几 GB 会把磁盘填满。
    case extractedDirectoryTooLarge(actualBytes: Int, maxBytes: Int)

    /// ZIP 解压成功但目录里一个文件都没有（或全是 macOS 元数据 `__MACOSX` / `.DS_Store`）。
    case zipEmpty

    /// ZIPFoundation 抛出的底层错误（密码保护 / 损坏 / 不支持的压缩算法等）。
    case zipExtractionFailed(underlying: Error)

    /// Zip slip 防护：解压出的文件路径超出 rootURL 子树（恶意 ZIP 含 `../../etc/passwd`）。
    /// ZIPFoundation 0.9+ 自带防护，本检测是 defense-in-depth 兜底。
    case zipSlipDetected(path: String)

    // MARK: - Pass 1 过滤阶段（致命）

    /// 经过 ignore 规则过滤后没有任何文件，pipeline 没东西可处理。
    /// 触发场景：用户自定义 ignore 把整个仓库过滤干净 / 仓库本身就是空的。
    case noFilesAfterFiltering

    // MARK: - Pass 3-4 写入阶段（致命）

    /// 输出目录创建失败 / 不可写（磁盘只读 / 权限不足 / 沙箱限制）。
    case outputDirectoryNotWritable(URL, underlying: Error)

    /// XML 拼装失败（极少触发，正常情况下 String 拼接不会失败）。
    case xmlBuildFailed(underlying: Error)

    /// 写文件失败（context.xml / metadata.json 任一）。
    /// 写入策略是 `.tmp → rename` 原子写，失败时不会留半成品。
    case writeFailed(URL, underlying: Error)

    // MARK: - Task 生命周期（致命）

    /// Task.cancel() 被调用，pipeline 主动中止。
    /// 抛出时 caller 应负责清理：临时目录 defer 已经处理，输出目录不会有半成品（原子写）。
    case cancelled

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .zipFileNotFound(let url):
            return "ZIP 文件不存在：\(url.path)"
        case .zipTooLarge(let actual, let max):
            return "ZIP 文件过大：\(actual) bytes（上限 \(max) bytes）"
        case .extractedDirectoryTooLarge(let actual, let max):
            return "解压后目录过大：\(actual) bytes（上限 \(max) bytes，疑似 ZIP bomb）"
        case .zipEmpty:
            return "ZIP 解压后无任何文件"
        case .zipExtractionFailed(let error):
            return "ZIP 解压失败：\(error.localizedDescription)"
        case .zipSlipDetected(let path):
            return "Zip slip 攻击防护触发：\(path) 超出 root 子树"
        case .noFilesAfterFiltering:
            return "经过 ignore 规则过滤后无任何文件可处理"
        case .outputDirectoryNotWritable(let url, let error):
            return "输出目录不可写：\(url.path)（\(error.localizedDescription)）"
        case .xmlBuildFailed(let error):
            return "XML 构建失败：\(error.localizedDescription)"
        case .writeFailed(let url, let error):
            return "写入失败：\(url.path)（\(error.localizedDescription)）"
        case .cancelled:
            return "Packer 已取消"
        }
    }
}
