//
//  StarcatWidgetTimeline.swift
//  StarcatWidgets
//
//  四个 Widget 共用的快照加载、错误降级和 Timeline 基础模型。
//

import Foundation
import OSLog
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
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.starcat.widgets",
        category: "WidgetSnapshot"
    )

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
            logger.debug("Widget snapshot is not available yet")
            return StarcatWidgetEntry(date: now, content: .preparing)
        } catch WidgetSnapshotStoreError.unsupportedSchemaVersion(let version) {
            logger.error("Widget snapshot schema is unsupported: \(version, privacy: .public)")
            return StarcatWidgetEntry(date: now, content: .upgradeRequired)
        } catch WidgetSnapshotStoreError.corruptedSnapshot {
            logger.error("Widget snapshot is corrupted")
            return StarcatWidgetEntry(date: now, content: .unavailable)
        } catch WidgetSharedConfigurationError.missingAppGroupIdentifier {
            logger.error("Widget App Group configuration is missing")
            return StarcatWidgetEntry(date: now, content: .unavailable)
        } catch WidgetSharedConfigurationError.invalidAppGroupIdentifier {
            logger.error("Widget App Group configuration is invalid")
            return StarcatWidgetEntry(date: now, content: .unavailable)
        } catch WidgetSharedConfigurationError.containerUnavailable {
            logger.error("Widget App Group container is unavailable")
            return StarcatWidgetEntry(date: now, content: .unavailable)
        } catch {
            // 不记录 URL、容器路径或 JSON 内容，日志只表达稳定的失败分类。
            logger.error("Widget snapshot load failed with an unexpected error")
            return StarcatWidgetEntry(date: now, content: .unavailable)
        }
    }

    static func nextRefresh(
        after date: Date,
        isReady: Bool,
        kind: WidgetTimelineKind,
        calendar: Calendar = .current
    ) -> Date {
        WidgetTimelineRefreshPolicy.nextRefresh(
            after: date,
            isReady: isReady,
            kind: kind,
            calendar: calendar
        )
    }
}

private extension WidgetSnapshot {
    /// Widget Gallery / Preview 使用的纯本地样例，不触发 App Group 或网络访问。
    static var placeholder: WidgetSnapshot {
        let now = Date()
        let swiftRepository = WidgetRepository(
            id: 1,
            owner: "apple",
            name: "swift",
            description: "The Swift Programming Language",
            language: "Swift",
            starsCount: 68_000,
            tags: ["Swift", "Language"],
            status: "using",
            focusSource: .pinned,
            avatarFileName: nil,
            openURL: URL(string: "starcat://repo/apple/swift?v=1&rid=1")!
        )
        let grdbRepository = WidgetRepository(
            id: 2,
            owner: "groue",
            name: "GRDB.swift",
            description: "A toolkit for SQLite databases, with a focus on application development",
            language: "Swift",
            starsCount: 7_600,
            tags: ["Database", "SQLite"],
            status: "using",
            focusSource: .using,
            avatarFileName: nil,
            openURL: URL(string: "starcat://repo/groue/GRDB.swift?v=1&rid=2")!
        )
        let architectureRepository = WidgetRepository(
            id: 3,
            owner: "pointfreeco",
            name: "swift-composable-architecture",
            description: "A library for building applications in a consistent way",
            language: "Swift",
            starsCount: 14_200,
            tags: ["Architecture", "SwiftUI"],
            status: "using",
            focusSource: .pinned,
            avatarFileName: nil,
            openURL: URL(
                string: "starcat://repo/pointfreeco/swift-composable-architecture?v=1&rid=3"
            )!
        )
        let releases = [
            WidgetRelease(
                id: 1,
                repositoryID: swiftRepository.id,
                owner: swiftRepository.owner,
                repositoryName: swiftRepository.name,
                tagName: "6.2.0",
                displayName: "Swift 6.2",
                publishedAt: now,
                isPrerelease: false,
                avatarFileName: nil,
                openURL: swiftRepository.openURL
            ),
            WidgetRelease(
                id: 2,
                repositoryID: grdbRepository.id,
                owner: grdbRepository.owner,
                repositoryName: grdbRepository.name,
                tagName: "v7.11.0",
                displayName: "GRDB 7.11",
                publishedAt: now.addingTimeInterval(-8 * 60 * 60),
                isPrerelease: false,
                avatarFileName: nil,
                openURL: grdbRepository.openURL
            ),
            WidgetRelease(
                id: 3,
                repositoryID: architectureRepository.id,
                owner: architectureRepository.owner,
                repositoryName: architectureRepository.name,
                tagName: "1.22.3",
                displayName: "Composable Architecture 1.22.3",
                publishedAt: now.addingTimeInterval(-26 * 60 * 60),
                isPrerelease: false,
                avatarFileName: nil,
                openURL: architectureRepository.openURL
            )
        ]
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let trendPoints = (0..<12).compactMap { offset -> WidgetCollectionTrendPoint? in
            guard let week = calendar.date(
                byAdding: .weekOfYear,
                value: offset - 11,
                to: currentWeek
            ) else {
                return nil
            }
            return WidgetCollectionTrendPoint(
                weekStart: week,
                count: [3, 5, 2, 7, 4, 8, 6, 9, 5, 11, 8, 13][offset]
            )
        }
        let heatmapStart = calendar.date(
            byAdding: .weekOfYear,
            value: -25,
            to: currentWeek
        )!
        let dailyPoints = (0..<(26 * 7)).compactMap { offset -> WidgetCollectionTrendDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: heatmapStart) else {
                return nil
            }
            // 固定伪随机分布同时包含空白、低频与少量峰值，让 Gallery 更接近真实收藏节奏。
            let seed = (offset * 37 + 11) % 17
            let count = switch seed {
            case 0...7: 0
            case 8...12: 1
            case 13...15: 2
            default: 4
            }
            return WidgetCollectionTrendDay(date: day, count: count)
        }

        return WidgetSnapshot(
            generatedAt: now,
            accountState: .ready,
            focusRepositories: [swiftRepository, grdbRepository, architectureRepository],
            rediscoveryRepository: grdbRepository,
            unreadReleaseCount: 5,
            unreadReleases: releases,
            collectionTrend: WidgetCollectionTrend(
                totalCount: 1_088,
                addedInLast30DaysCount: 37,
                weeklyPoints: trendPoints,
                dailyPoints: dailyPoints,
                statusBreakdown: WidgetCollectionStatusBreakdown(
                    unreadCount: 481,
                    readCount: 402,
                    usingCount: 205
                )
            )
        )
    }
}
