//
//  CodebaseMemoryError.swift
//  Starcat
//
//  CodebaseMemory 模块统一错误类型。
//
//  所有对外文案走 `String.l10n("codebaseMemory.error.*")`，
//  与 CodeFlowError / RepoContextPackerError 同款模式。

import Foundation

enum CodebaseMemoryError: LocalizedError, Sendable, Equatable {
    /// 二进制未打包进 Bundle（Resources/Codebase/codebase 缺失）。
    case binaryMissing
    /// 二进制不是可执行文件（chmod 失败或 Xcode 损坏）。
    case binaryNotExecutable
    /// 空 ZIP 存档。
    case emptyArchive
    /// ZIP 文件过大（超过 100MB 上限）。
    case archiveTooLarge(actualBytes: Int)
    /// 解压后目录过大（超过 500MB 上限）。
    case extractedTooLarge(actualBytes: Int)
    /// cli index_repository 子命令失败。
    case indexFailed(underlying: String)
    /// 启动 UI 子进程失败。
    case uiStartFailed(underlying: String)
    /// 端口探测失败（16 次随机全占满）。
    case portExhausted
    /// 系统浏览器打开失败。
    case browserOpenFailed
    /// 输入参数非法。
    case invalidArguments(String)

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return String.l10n("codebaseMemory.error.binaryMissing")
        case .binaryNotExecutable:
            return String.l10n("codebaseMemory.error.binaryNotExecutable")
        case .emptyArchive:
            return String.l10n("codebaseMemory.error.emptyArchive")
        case .archiveTooLarge(let actualBytes):
            return String(format: String.l10n("codebaseMemory.error.archiveTooLargeFormat"), actualBytes)
        case .extractedTooLarge(let actualBytes):
            return String(format: String.l10n("codebaseMemory.error.extractedTooLargeFormat"), actualBytes)
        case .indexFailed(let message):
            return String(format: String.l10n("codebaseMemory.error.indexFailedFormat"), message)
        case .uiStartFailed(let message):
            return String(format: String.l10n("codebaseMemory.error.uiStartFailedFormat"), message)
        case .portExhausted:
            return String.l10n("codebaseMemory.error.portExhausted")
        case .browserOpenFailed:
            return String.l10n("codebaseMemory.error.browserOpenFailed")
        case .invalidArguments(let message):
            return String(format: String.l10n("codebaseMemory.error.invalidArgumentsFormat"), message)
        }
    }
}
