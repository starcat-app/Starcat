//
//  StarcatWidgetTimeline.swift
//  StarcatWidgets
//
//  三个 Widget 共用的快照加载、错误降级和 Timeline 基础模型。
//

import Foundation
import WidgetKit

enum StarcatWidgetContent: Equatable, Sendable {
    case snapshot(WidgetSnapshot)
    case preparing
    case signedOut
    case unavailable
    case upgradeRequired
}

struct StarcatWidgetEntry: TimelineEntry, Equatable, Sendable {
    let date: Date
    let content: StarcatWidgetContent

    var snapshot: WidgetSnapshot? {
        guard case .snapshot(let snapshot) = content else { return nil }
        return snapshot
    }

    /// 超过 24 小时仍可展示最后一次快照，但 UI 应提示打开 Starcat 更新。
    var isStale: Bool {
        guard let snapshot else { return false }
        return date.timeIntervalSince(snapshot.generatedAt) > 24 * 60 * 60
    }

    static let placeholder = StarcatWidgetEntry(
        date: Date(),
        content: .snapshot(.placeholder)
    )
}

enum StarcatWidgetSnapshotLoader {
    static func load(now: Date = Date()) -> StarcatWidgetEntry {
        do {
            let groupIdentifier = try WidgetSharedConfiguration.appGroupIdentifier()
            let containerURL = try WidgetSharedConfiguration.containerURL(
                groupIdentifier: groupIdentifier
            )
            let snapshot = try WidgetSnapshotStore(containerURL: containerURL).load()
            let content: StarcatWidgetContent
            switch snapshot.accountState {
            case .ready:
                content = .snapshot(snapshot)
            case .preparing:
                content = .preparing
            case .signedOut:
                content = .signedOut
            case .unavailable:
                content = .unavailable
            }
            return StarcatWidgetEntry(date: now, content: content)
        } catch WidgetSnapshotStoreError.snapshotMissing {
            return StarcatWidgetEntry(date: now, content: .preparing)
        } catch WidgetSnapshotStoreError.unsupportedSchemaVersion {
            return StarcatWidgetEntry(date: now, content: .upgradeRequired)
        } catch {
            return StarcatWidgetEntry(date: now, content: .unavailable)
        }
    }

    static func nextStandardRefresh(after date: Date) -> Date {
        date.addingTimeInterval(30 * 60)
    }

    /// 今日重逢需要在本地次日 00:05 后选择新仓库。
    static func nextRediscoveryRefresh(
        after date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let fallback = nextStandardRefresh(after: date)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
              let nextStart = calendar.date(
                bySettingHour: 0,
                minute: 5,
                second: 0,
                of: tomorrow
              ) else {
            return fallback
        }
        return nextStart
    }
}

private extension WidgetSnapshot {
    /// Widget Gallery / Preview 使用的纯本地样例，不触发 App Group 或网络访问。
    static var placeholder: WidgetSnapshot {
        let repository = WidgetRepository(
            id: 1,
            owner: "apple",
            name: "swift",
            description: "The Swift Programming Language",
            language: "Swift",
            starsCount: 68_000,
            tags: ["Swift", "Language"],
            status: "using",
            avatarFileName: nil,
            openURL: URL(string: "starcat://repo/apple/swift?v=1&rid=1")!
        )
        let release = WidgetRelease(
            id: 1,
            repositoryID: repository.id,
            owner: repository.owner,
            repositoryName: repository.name,
            tagName: "6.2.0",
            displayName: "Swift 6.2",
            publishedAt: Date(),
            isPrerelease: false,
            avatarFileName: nil,
            openURL: repository.openURL
        )
        return WidgetSnapshot(
            accountState: .ready,
            focusRepositories: [repository, repository, repository],
            rediscoveryRepository: repository,
            unreadReleaseCount: 1,
            unreadReleases: [release]
        )
    }
}
