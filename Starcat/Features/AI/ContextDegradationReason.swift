//
//  ContextDegradationReason.swift
//  Starcat
//
//  Y4（2026-06-13）：摘要生成时代码上下文为什么没拿到的分类原因。
//
//  设计目标：让用户在 AI 摘要 UI 顶部看到一行"为什么这次摘要没用上代码"的解释，
//  而不是默默降级成 README-only 让用户疑惑"我开了代码上下文为什么没生效"。
//
//  分类原则：
//    - `featureDisabled` 故意不放进 banner —— 用户自己关了 settings 不应该再提醒；
//    - 其它 4 case 都对应"用户开了上下文但环境/网络/数据有问题"的情况，需要弹 banner。
//
//  常用映射：
//    - SharedSnapshotError.privateRepository → .privateRepository
//    - SharedSnapshotError.requestFailed / URLError → .networkUnavailable
//    - SharedSnapshotError.archiveTooLarge → .archiveTooLarge
//    - RepoContextPackerError.* / RepoContextStorageError.* → .packFailure
//

import Foundation

/// 代码上下文被降级的原因（Y4）。
enum ContextDegradationReason: Sendable, Equatable {
    /// 私有仓库：OAuth scope (`public_repo`) 不允许访问。
    case privateRepository

    /// ZIP 下载失败：网络异常 / GitHub 5xx / 超时等。
    case networkUnavailable

    /// 仓库 ZIP 超过当前调用方生效的大小上限。
    ///
    /// 单仓 AI 与知识库 RAG 使用同一用户配置阈值。展示文案必须走
    /// `bannerMessage(maximumArchiveMB:)`，不要直接读 `bannerMessageKey` 的固定 100MB 文案。
    case archiveTooLarge

    /// RepoContextPacker pipeline 失败（解压 / Tier 分类 / XML 拼装等）。
    case packFailure

    /// RepoContextStorage 输出目录失效（用户主动选的目录被外部删除 / bookmark 失效）。
    case outputDirectoryUnavailable

    /// 本地化的 banner 文案 key（i18n 在 Y4 一并补齐）。
    ///
    /// `.archiveTooLarge` 仍保留固定 100MB key，供旧调用方兜底；新代码请用
    /// `bannerMessage(maximumArchiveMB:)`，以免用户阈值与提示对不上。
    var bannerMessageKey: String {
        switch self {
        case .privateRepository: return "ai.context.degraded.privateRepository"
        case .networkUnavailable: return "ai.context.degraded.networkUnavailable"
        case .archiveTooLarge: return "ai.context.degraded.archiveTooLarge"
        case .packFailure: return "ai.context.degraded.packFailure"
        case .outputDirectoryUnavailable: return "ai.context.degraded.outputDirectoryUnavailable"
        }
    }

    /// 按当前生效阈值渲染用户可读降级文案。
    ///
    /// - Parameter maximumArchiveMB: 本次拒绝实际使用的上限（MB）。省略时仅为旧调用方
    ///   按历史 100MB 安全上限兜底；单仓 AI 与 RAG UI 都应显式传当前设置值。
    func bannerMessage(
        maximumArchiveMB: Int = SharedSnapshotService.maximumArchiveBytes / 1_000_000
    ) -> String {
        if self == .archiveTooLarge {
            return String(
                format: String.l10n("ai.context.degraded.archiveTooLargeFormat"),
                maximumArchiveMB
            )
        }
        return String.l10n(bannerMessageKey)
    }

    /// 把任意 error 分类到 5 case 之一。
    /// 不属于已知错误类型 → .packFailure 兜底（语义上"上下文准备阶段未知失败"）。
    static func classify(_ error: Error) -> ContextDegradationReason {
        if let snapshotError = error as? SharedSnapshotError {
            switch snapshotError {
            case .privateRepository: return .privateRepository
            case .archiveTooLarge: return .archiveTooLarge
            case .requestFailed, .invalidGitHubURL, .emptyArchive, .branchNotFound:
                return .networkUnavailable
            }
        }
        if error is URLError {
            return .networkUnavailable
        }
        if error is RepoContextStorageError {
            return .outputDirectoryUnavailable
        }
        return .packFailure
    }
}
