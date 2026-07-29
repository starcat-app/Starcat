//
//  WidgetRefreshCoordinator.swift
//  Starcat
//
//  主应用内 Widget 快照发布与刷新信号合并。
//
//  关键约束：
//  - 所有状态由 MainActor 串行驱动，避免用户切换与普通刷新并发覆盖；
//  - 数据库变化通知只负责发信号，500ms 去抖后重建一次完整快照；
//  - 测试 host 不访问真实 App Group，也不触发 WidgetCenter 系统副作用。
//

import Foundation
import WidgetKit

@MainActor
final class WidgetRefreshCoordinator {
    private let builder: WidgetSnapshotBuilder
    private var observers: [NSObjectProtocol] = []
    private var pendingRefreshTask: Task<Void, Never>?

    init(database: any DatabaseManaging) {
        self.builder = WidgetSnapshotBuilder(database: database)
    }

    /// 注册会改变 Widget 投影的本地事件。
    ///
    /// AppDependencies 与本对象同生命周期，只允许调用一次。显式启动而非 init 内注册，
    /// 便于测试 host 完全跳过系统通知副作用。
    func startObserving() {
        guard observers.isEmpty, !TestEnvironment.isRunning else { return }
        let names: [Notification.Name] = [
            .repoTagsDidChange,
            .repoStatusDidChange,
            .repoLibraryStateDidChange,
            .repoPinDidChange,
            .releaseRecordsDidChange,
            .releaseSubscriptionDidChange
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReadyRefresh()
                }
            }
        }
    }

    /// 合并同一批数据库写入产生的多个通知。
    func scheduleReadyRefresh() {
        guard !TestEnvironment.isRunning else { return }
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.publishReady()
        }
    }

    /// 立即构建并发布当前用户的 ready 快照。
    func publishReady() async {
        guard !TestEnvironment.isRunning else { return }
        do {
            let context = try makePublishingContext()
            let snapshot = try await builder.build()
            let enrichedSnapshot = await context.avatarCache.enrich(snapshot)
            try context.store.save(enrichedSnapshot)
            reloadTimelines()
        } catch {
            AppLog.general.error(
                "Widget ready snapshot publish failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 用户切换、登出和故障路径立即发布空快照。
    ///
    /// 该方法不去抖：旧账号内容必须在切库之前被清掉，不能等待普通刷新窗口。
    func publishEmpty(state: WidgetAccountState) {
        guard !TestEnvironment.isRunning else { return }
        pendingRefreshTask?.cancel()
        do {
            let context = try makePublishingContext()
            try context.store.save(.empty(state: state))
            if state == .signedOut {
                context.avatarCache.clear()
            }
            reloadTimelines()
        } catch {
            AppLog.general.error(
                "Widget empty snapshot publish failed state=\(state.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func makePublishingContext() throws -> (
        store: WidgetSnapshotStore,
        avatarCache: WidgetAvatarCache
    ) {
        let groupIdentifier = try WidgetSharedConfiguration.appGroupIdentifier()
        let containerURL = try WidgetSharedConfiguration.containerURL(
            groupIdentifier: groupIdentifier
        )
        return (
            WidgetSnapshotStore(containerURL: containerURL),
            WidgetAvatarCache(containerURL: containerURL)
        )
    }

    private func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
