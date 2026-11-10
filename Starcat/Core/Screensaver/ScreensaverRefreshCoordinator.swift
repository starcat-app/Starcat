//
//  ScreensaverRefreshCoordinator.swift
//  Starcat
//
//  Direct 主应用内屏保快照发布。测试 host 与 App Store 构建都不碰真实快照目录。
//

import Foundation
import Observation

/// 屏保头像准备进度。设置页只展示这份快照，不自己数文件。
struct ScreensaverAvatarProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
}

/// Direct 主应用内屏保快照发布。测试 host 与 App Store 构建都不碰真实快照目录。
@MainActor
@Observable
final class ScreensaverRefreshCoordinator {
    private(set) var avatarProgress: ScreensaverAvatarProgress?

    private let loadCards: @MainActor () async throws -> [AmbientCardModel]
    private let userIDProvider: @MainActor () -> Int64?
    private let isEnabled: Bool
    private let makePublisher: () throws -> ScreensaverSnapshotPublisher
    private let bypassTestHostGate: Bool
    private var observers: [NSObjectProtocol] = []
    private var pendingRefreshTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var publishGeneration: UInt64 = 0

    init(
        repository: any RepoRepositoryProtocol,
        userIDProvider: @escaping @MainActor () -> Int64?,
        isEnabled: Bool = DistributionChannel.current.isDirect
    ) {
        self.userIDProvider = userIDProvider
        self.isEnabled = isEnabled
        self.loadCards = {
            try await LocalAmbientCatalog(repository: repository).loadCards(scene: .owners)
        }
        self.makePublisher = {
            let containerURL = ScreensaverSharedConfiguration.productionContainerURL()
            return ScreensaverSnapshotPublisher(
                loadCards: {
                    try await LocalAmbientCatalog(repository: repository).loadCards(scene: .owners)
                },
                store: ScreensaverSnapshotStore(containerURL: containerURL),
                cache: ScreensaverAvatarCache(containerURL: containerURL),
                downloader: ScreensaverSnapshotPublisher.makeNetworkDownloader(),
                localImageSource: ScreensaverSnapshotPublisher.makeLocalImageSource()
            )
        }
        self.bypassTestHostGate = false
    }

    /// 测试可替换发布器构造，避免访问真实快照目录。
    init(
        loadCards: @escaping @MainActor () async throws -> [AmbientCardModel],
        userIDProvider: @escaping @MainActor () -> Int64?,
        isEnabled: Bool,
        makePublisher: @escaping () throws -> ScreensaverSnapshotPublisher,
        bypassTestHostGate: Bool = true
    ) {
        self.loadCards = loadCards
        self.userIDProvider = userIDProvider
        self.isEnabled = isEnabled
        self.makePublisher = makePublisher
        self.bypassTestHostGate = bypassTestHostGate
    }

    func startObserving() {
        guard observers.isEmpty, isEnabled, !TestEnvironment.isRunning else { return }
        observers = [
            NotificationCenter.default.addObserver(
                forName: .repoLibraryStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReadyRefresh()
                }
            }
        ]
    }

    func scheduleReadyRefresh() {
        guard isEnabled, !TestEnvironment.isRunning else { return }
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

    func publishReady() async {
        guard isEnabled else { return }
        guard bypassTestHostGate || !TestEnvironment.isRunning else { return }
        guard userIDProvider() != nil else { return }
        if let publishTask {
            await publishTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPublish()
        }
        publishTask = task
        await task.value
        publishTask = nil
    }

    private func performPublish() async {
        guard let userID = userIDProvider() else { return }
        publishGeneration &+= 1
        let generation = publishGeneration
        avatarProgress = ScreensaverAvatarProgress(completed: 0, total: 0)
        defer {
            if generation == publishGeneration {
                // 发布回调通过 MainActor Task 排队；结束后使其失效，避免最后一条进度重建幽灵任务。
                publishGeneration &+= 1
                avatarProgress = nil
            }
        }
        do {
            let publisher = try makePublisher()
            try await publisher.publish(userID: userID) { [weak self] completed, total in
                Task { @MainActor in
                    guard let self, generation == self.publishGeneration else { return }
                    self.avatarProgress = ScreensaverAvatarProgress(
                        completed: completed,
                        total: total
                    )
                }
            }
        } catch {
            AppLog.general.error(
                "Screensaver snapshot publish failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func clear() {
        guard isEnabled else { return }
        guard bypassTestHostGate || !TestEnvironment.isRunning else { return }
        publishGeneration &+= 1
        avatarProgress = nil
        pendingRefreshTask?.cancel()
        publishTask?.cancel()
        publishTask = nil
        do {
            try makePublisher().clear()
        } catch {
            AppLog.general.error(
                "Screensaver snapshot clear failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
