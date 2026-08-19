//
//  ReleaseNotificationService.swift
//  Starcat
//
//  Starcat 系统通知封装（HOM-47 / 2026-06-20 通知策略优化）。
//
//  目标：
//  - 把「需要用户回来处理」的低频事件转换成 macOS 系统通知（UNUserNotificationCenter）
//  - 首次需要通知时请求授权，授权失败时静默不弹通知（不影响主流程 UI）
//  - 通知点击可识别 repo / release（userInfo 携带 id 与 url）
//  - 非必要事件不发系统通知：普通同步完成、MCP 正常启停、状态面板变化都留在 App 内展示
//
//  设计取舍：
//  - 协议化（NotificationDispatching）让单测可注入 fake，避免依赖真实 UNUserNotificationCenter
//  - 测试期 / 沙盒未授权时降级为 no-op
//  - 失败类通知统一在这里做冷却，避免 Sync / MCP 重试循环刷通知中心
//

import Foundation
@preconcurrency import UserNotifications

/// 通知派发的最小协议（仅暴露 add，授权由 service 内部处理）。
///
/// 抽象成协议是为了：
/// - 真实运行：UNUserNotificationCenter.current()
/// - 单测：用 SpyNotificationDispatcher 验证"是否调用了 add 以及 content 内容"
protocol NotificationDispatching: Sendable {
    func requestAuthorization() async throws -> Bool
    func add(request: UNNotificationRequest) async throws
}

/// 默认实现：包装 UNUserNotificationCenter。
struct SystemNotificationDispatcher: NotificationDispatching {
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func add(request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class AppNotificationService {

    private let dispatcher: any NotificationDispatching
    private let settings: AppSettings

    /// 是否已请求过授权（一次会话内仅请求一次）。
    private var didRequestAuthorization = false

    /// 上次授权请求结果（缓存避免重复弹系统对话框）。
    private var isAuthorized = false

    /// 通知冷却表。key 是业务语义，不是 UNNotificationRequest.identifier。
    private var lastSentAtByCooldownKey: [String: Date] = [:]

    init(
        dispatcher: any NotificationDispatching = SystemNotificationDispatcher(),
        settings: AppSettings
    ) {
        self.dispatcher = dispatcher
        self.settings = settings
    }

    /// 启动期 / 首次订阅时调用。请求失败不抛错（用户拒绝是合法选择）。
    func ensureAuthorized() async {
        guard settings.notificationsEnabled else { return }
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            isAuthorized = try await dispatcher.requestAuthorization()
            AppLog.general.info("Release notification authorization: \(self.isAuthorized, privacy: .public)")
        } catch {
            isAuthorized = false
            AppLog.general.error("Release notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 把一个新 Release 转成通知并 dispatch。授权未通过时静默忽略。
    /// - Parameter notifications: ReleaseMonitor 报告中的待通知项
    func dispatch(_ notifications: [ReleaseMonitorReport.NewReleaseItem]) async {
        guard !notifications.isEmpty else { return }
        guard settings.notificationsEnabled, settings.releaseNotificationsEnabled else { return }

        for item in notifications {
            let content = UNMutableNotificationContent()
            // 标题：用仓库 fullName 替代单独的 owner / name，便于用户在通知中心一眼看到来源。
            content.title = String(format: String.l10n("release.notification.titleFormat"), item.repo.fullName)
            content.body = makeBody(for: item.release)
            content.sound = .default
            content.userInfo = [
                "repoId": item.repo.id,
                "releaseId": item.release.id,
                "releaseUrl": item.release.htmlUrl
            ]

            // identifier：同一个 repo 同一个 release 反复巡检都用同一个 id，
            // 避免授权后第二轮巡检又把同一条 release 通知一次。
            // UNUserNotificationCenter 会用 identifier 去重。
            let request = UNNotificationRequest(
                identifier: "release-\(item.repo.id)-\(item.release.id)",
                content: content,
                trigger: nil // 立即触发
            )

            await add(request, logContext: "release")
        }
    }

    /// 高信号 GitHub 通知（mention / assign / review / security）。回填路径不会走到这里。
    func dispatchGitHubInbox(_ records: [GitHubNotificationThreadRecord]) async {
        guard !records.isEmpty else { return }
        guard settings.notificationsEnabled, settings.githubInboxNotificationsEnabled else { return }

        for record in records {
            let content = UNMutableNotificationContent()
            content.title = record.repositoryFullName
            content.body = record.subjectTitle
            content.sound = .default
            content.userInfo = [
                "kind": "githubInbox",
                "threadId": record.id
            ]
            let request = UNNotificationRequest(
                identifier: "github-inbox-\(record.id)",
                content: content,
                trigger: nil
            )
            await add(request, logContext: "githubInbox")
        }
    }

    /// 批量 AI 整批结束通知。单个 repo 完成不通知；小于 2 个 job 的批次也不打扰。
    func dispatchBatchAIFinished(completed: Int, ignored: Int, failed: Int, total: Int) async {
        guard settings.notificationsEnabled, settings.batchAINotificationsEnabled else { return }
        guard total >= 2 else { return }

        let title = failed > 0
            ? String.l10n("notification.batchAI.finishedWithFailures.title")
            : String.l10n("notification.batchAI.finished.title")
        let body = failed > 0
            ? String(format: String.l10n("notification.batchAI.finishedWithFailures.bodyFormat"), completed, ignored, failed, total)
            : String(format: String.l10n("notification.batchAI.finished.bodyFormat"), completed, ignored, total)

        await dispatchNotification(
            identifier: "batch-ai-\(Int(Date().timeIntervalSince1970))",
            title: title,
            body: body,
            userInfo: ["kind": "batchAI"]
        )
    }

    /// 同步需要用户处理时通知。普通成功 / App 内可见的短暂失败不通知。
    func dispatchSyncIssue(kind: SyncNotificationIssue, message: String) async {
        guard settings.notificationsEnabled, settings.syncIssueNotificationsEnabled else { return }
        guard shouldSend(cooldownKey: "sync-\(kind.rawValue)", interval: kind.cooldown) else { return }

        await dispatchNotification(
            identifier: "sync-\(kind.rawValue)",
            title: kind.title,
            body: message,
            userInfo: ["kind": "sync", "issue": kind.rawValue]
        )
    }

    /// MCP Service 启动失败通知。正常启动 / 停止不通知。
    func dispatchMCPFailure(message: String) async {
        guard settings.notificationsEnabled, settings.mcpIssueNotificationsEnabled else { return }
        guard settings.mcpServiceEnabled else { return }
        guard shouldSend(cooldownKey: "mcp-failed", interval: 60 * 60) else { return }

        await dispatchNotification(
            identifier: "mcp-failed",
            title: String.l10n("notification.mcp.failed.title"),
            body: message,
            userInfo: ["kind": "mcp"]
        )
    }

    private func makeBody(for release: ReleaseRecord) -> String {
        if let name = release.name, !name.isEmpty, name != release.tagName {
            return String(format: String.l10n("release.notification.bodyFormat"), release.tagName, name)
        }
        return release.tagName
    }

    private func dispatchNotification(
        identifier: String,
        title: String,
        body: String,
        userInfo: [AnyHashable: Any] = [:]
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        await add(request, logContext: identifier)
    }

    private func add(_ request: UNNotificationRequest, logContext: String) async {
        await ensureAuthorized()
        guard isAuthorized else { return }
        do {
            try await dispatcher.add(request: request)
        } catch {
            AppLog.general.error("Add notification failed context=\(logContext, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldSend(cooldownKey: String, interval: TimeInterval) -> Bool {
        let now = Date()
        if let last = lastSentAtByCooldownKey[cooldownKey], now.timeIntervalSince(last) < interval {
            return false
        }
        lastSentAtByCooldownKey[cooldownKey] = now
        return true
    }
}

typealias ReleaseNotificationService = AppNotificationService

enum SyncNotificationIssue: String {
    case rateLimited
    case unauthorized
    case failed

    var title: String {
        switch self {
        case .rateLimited:
            return String.l10n("notification.sync.rateLimited.title")
        case .unauthorized:
            return String.l10n("notification.sync.unauthorized.title")
        case .failed:
            return String.l10n("notification.sync.failed.title")
        }
    }

    var cooldown: TimeInterval {
        switch self {
        case .rateLimited:
            return 2 * 60 * 60
        case .unauthorized, .failed:
            return 6 * 60 * 60
        }
    }
}
