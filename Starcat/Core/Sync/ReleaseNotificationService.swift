//
//  ReleaseNotificationService.swift
//  Starcat
//
//  Release 系统通知封装（HOM-47）。
//
//  目标：
//  - 把 ReleaseMonitor 报告的 "新 Release" 转换成 macOS 系统通知（UNUserNotificationCenter）
//  - 启动期请求一次授权，授权失败时静默不弹通知（不影响列表 / 时间线 UI）
//  - 通知点击可识别 repo / release（userInfo 携带 id 与 url）
//
//  设计取舍：
//  - 协议化（NotificationDispatching）让单测可注入 fake，避免依赖真实 UNUserNotificationCenter
//  - 测试期 / 沙盒未授权时降级为 no-op
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

actor ReleaseNotificationService {

    private let dispatcher: any NotificationDispatching

    /// 是否已请求过授权（一次会话内仅请求一次）。
    private var didRequestAuthorization = false

    /// 上次授权请求结果（缓存避免重复弹系统对话框）。
    private var isAuthorized = false

    init(dispatcher: any NotificationDispatching = SystemNotificationDispatcher()) {
        self.dispatcher = dispatcher
    }

    /// 启动期 / 首次订阅时调用。请求失败不抛错（用户拒绝是合法选择）。
    func ensureAuthorized() async {
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
        await ensureAuthorized()
        guard isAuthorized else { return }

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

            do {
                try await dispatcher.add(request: request)
            } catch {
                AppLog.general.error("Add release notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeBody(for release: ReleaseRecord) -> String {
        if let name = release.name, !name.isEmpty, name != release.tagName {
            return String(format: String.l10n("release.notification.bodyFormat"), release.tagName, name)
        }
        return release.tagName
    }
}
