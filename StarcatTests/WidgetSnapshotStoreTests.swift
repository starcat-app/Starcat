//
//  WidgetSnapshotStoreTests.swift
//  StarcatTests
//
//  Widget 共享契约、原子快照存储与双渠道 App Group 配置测试。
//
//  这些测试只使用临时目录，不访问真实 App Group，避免测试进程的签名状态影响结果。
//

import Foundation
import Testing
@testable import Starcat

@Suite("WidgetSnapshotStore")
struct WidgetSnapshotStoreTests {

    @Test("ready 快照可以按 v4 契约往返编码")
    func roundTripsReadySnapshot() throws {
        try withTemporaryDirectory { directory in
            // 取整秒，避免 JSON ISO8601 编解码的亚秒精度差异干扰契约断言。
            let generatedAt = Date(timeIntervalSince1970: 1_754_032_800)
            let snapshot = WidgetSnapshot(
                generatedAt: generatedAt,
                accountState: .ready,
                focusRepositories: [makeRepository(id: 1)],
                rediscoveryRepository: makeRepository(id: 2),
                unreadReleaseCount: 1,
                unreadReleases: [makeRelease(id: 10, repositoryID: 1)],
                collectionTrend: makeCollectionTrend(),
                contributionActivity: makeContributionActivity()
            )
            let store = WidgetSnapshotStore(containerURL: directory)

            try store.save(snapshot)

            #expect(try store.load() == snapshot)
        }
    }

    @Test("非 ready 状态在构造与解码边界都清空业务数据")
    func stripsBusinessDataForNonReadyStates() throws {
        for state in [WidgetAccountState.preparing, .signedOut, .unavailable] {
            let snapshot = WidgetSnapshot(
                accountState: state,
                focusRepositories: [makeRepository(id: 1)],
                rediscoveryRepository: makeRepository(id: 2),
                unreadReleaseCount: 99,
                unreadReleases: [makeRelease(id: 10, repositoryID: 1)],
                collectionTrend: makeCollectionTrend()
            )

            #expect(snapshot.focusRepositories.isEmpty)
            #expect(snapshot.rediscoveryRepository == nil)
            #expect(snapshot.unreadReleaseCount == 0)
            #expect(snapshot.unreadReleases.isEmpty)
            #expect(snapshot.collectionTrend == nil)
            #expect(snapshot.contributionActivity == nil)
        }

        try withTemporaryDirectory { directory in
            let store = WidgetSnapshotStore(containerURL: directory)
            try store.save(.empty(state: .signedOut))
            let loaded = try store.load()

            #expect(loaded.accountState == .signedOut)
            #expect(loaded.focusRepositories.isEmpty)
            #expect(loaded.unreadReleases.isEmpty)
            #expect(loaded.collectionTrend == nil)
            #expect(loaded.contributionActivity == nil)
        }
    }

    @Test("v4 Extension 可以读取缺少趋势字段的 v1 ready 快照")
    func loadsLegacyV1ReadySnapshot() throws {
        try withTemporaryDirectory { directory in
            let rawJSON = """
            {
              "schemaVersion": 1,
              "generatedAt": "2026-07-30T08:00:00Z",
              "accountState": "ready",
              "focusRepositories": [],
              "rediscoveryRepository": null,
              "unreadReleaseCount": 0,
              "unreadReleases": []
            }
            """
            try Data(rawJSON.utf8).write(
                to: WidgetSharedConfiguration.snapshotURL(containerURL: directory)
            )

            let loaded = try WidgetSnapshotStore(containerURL: directory).load()

            #expect(loaded.schemaVersion == 1)
            #expect(loaded.accountState == .ready)
            #expect(loaded.collectionTrend == nil)
            #expect(loaded.contributionActivity == nil)
        }
    }

    @Test("v4 Extension 可以读取缺少单日点的 v2 趋势快照")
    func loadsLegacyV2TrendSnapshot() throws {
        try withTemporaryDirectory { directory in
            let rawJSON = """
            {
              "schemaVersion": 2,
              "generatedAt": "2026-07-30T08:00:00Z",
              "accountState": "ready",
              "focusRepositories": [],
              "rediscoveryRepository": null,
              "unreadReleaseCount": 0,
              "unreadReleases": [],
              "collectionTrend": {
                "totalCount": 3,
                "addedInLast30DaysCount": 2,
                "weeklyPoints": [{
                  "weekStart": "2026-07-27T00:00:00Z",
                  "count": 2
                }],
                "statusBreakdown": {
                  "unreadCount": 1,
                  "readCount": 1,
                  "usingCount": 1
                }
              }
            }
            """
            try Data(rawJSON.utf8).write(
                to: WidgetSharedConfiguration.snapshotURL(containerURL: directory)
            )

            let loaded = try WidgetSnapshotStore(containerURL: directory).load()

            #expect(loaded.schemaVersion == 2)
            #expect(loaded.collectionTrend?.dailyPoints == nil)
            #expect(loaded.collectionTrend?.weeklyPoints.count == 1)
            #expect(loaded.contributionActivity == nil)
        }
    }

    @Test("磁盘异常 JSON 即使在 signedOut 中夹带旧数据也会在解码时清空")
    func stripsInjectedBusinessDataWhileDecoding() throws {
        try withTemporaryDirectory { directory in
            let rawJSON = """
            {
              "schemaVersion": 1,
              "generatedAt": "2026-07-30T08:00:00Z",
              "accountState": "signedOut",
              "focusRepositories": [{
                "id": 1,
                "owner": "old-user",
                "name": "private-context",
                "description": "must disappear",
                "language": "Swift",
                "starsCount": 1,
                "tags": ["old"],
                "status": "using",
                "focusSource": "using",
                "avatarFileName": "old.png",
                "openURL": "starcat://repo/old-user/private-context?v=1&rid=1"
              }],
              "rediscoveryRepository": null,
              "unreadReleaseCount": 1,
              "unreadReleases": [{
                "id": 2,
                "repositoryID": 1,
                "owner": "old-user",
                "repositoryName": "private-context",
                "tagName": "v1",
                "displayName": null,
                "publishedAt": null,
                "isPrerelease": false,
                "avatarFileName": "old.png",
                "openURL": "starcat://repo/old-user/private-context/releases?v=1&rid=1&release_id=2"
              }]
            }
            """
            try Data(rawJSON.utf8).write(
                to: WidgetSharedConfiguration.snapshotURL(containerURL: directory)
            )

            let loaded = try WidgetSnapshotStore(containerURL: directory).load()

            #expect(loaded.accountState == .signedOut)
            #expect(loaded.focusRepositories.isEmpty)
            #expect(loaded.rediscoveryRepository == nil)
            #expect(loaded.unreadReleaseCount == 0)
            #expect(loaded.unreadReleases.isEmpty)
            #expect(loaded.collectionTrend == nil)
            #expect(loaded.contributionActivity == nil)
        }
    }

    @Test("缺失、损坏和更高 schema 返回稳定错误")
    func rejectsMissingCorruptedAndFutureSnapshots() throws {
        try withTemporaryDirectory { directory in
            let store = WidgetSnapshotStore(containerURL: directory)
            #expect(throws: WidgetSnapshotStoreError.snapshotMissing) {
                try store.load()
            }

            let snapshotURL = WidgetSharedConfiguration.snapshotURL(containerURL: directory)
            try Data("{not-json".utf8).write(to: snapshotURL)
            #expect(throws: WidgetSnapshotStoreError.corruptedSnapshot) {
                try store.load()
            }

            try store.save(
                WidgetSnapshot(
                    schemaVersion: WidgetSnapshot.currentSchemaVersion + 1,
                    accountState: .ready
                )
            )
            #expect(
                throws: WidgetSnapshotStoreError.unsupportedSchemaVersion(
                    WidgetSnapshot.currentSchemaVersion + 1
                )
            ) {
                try store.load()
            }
        }
    }

    @Test("连续原子替换后只保留正式快照且无临时文件")
    func atomicallyReplacesSnapshotWithoutTemporaryFiles() throws {
        try withTemporaryDirectory { directory in
            let store = WidgetSnapshotStore(containerURL: directory)
            try store.save(.empty(state: .preparing))
            try store.save(.empty(state: .signedOut))

            #expect(try store.load().accountState == .signedOut)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(names == [WidgetSharedConfiguration.snapshotFileName])
        }
    }

    @Test("Store 与 Direct 从 Info.plist 读取各自 App Group")
    func resolvesDistributionSpecificAppGroups() throws {
        let store = try WidgetSharedConfiguration.appGroupIdentifier(
            infoDictionary: [
                WidgetSharedConfiguration.appGroupInfoKey:
                    "group.com.starcat.app.store.widgets"
            ]
        )
        let direct = try WidgetSharedConfiguration.appGroupIdentifier(
            infoDictionary: [
                WidgetSharedConfiguration.appGroupInfoKey:
                    "8WCUMGCWMB.com.starcat.app.direct.widgets"
            ]
        )

        #expect(store == "group.com.starcat.app.store.widgets")
        #expect(direct == "8WCUMGCWMB.com.starcat.app.direct.widgets")
        #expect(store != direct)
    }

    @Test("Direct 发布重签保留 Widget 共享组，Host 与 Extension 配置一致")
    func directDistributionRetainsWidgetAppGroup() throws {
        // 只检查仓库配置，不请求真实容器；发布重签曾漏掉共享组，普通快照读写测试
        // 无法发现这种错误，必须把发布 entitlement 与运行时注入值一起校验。
        let groupKey = "com.apple.security.application-groups"
        let expectedGroup = "8WCUMGCWMB.com.starcat.app.direct.widgets"
        let development = try repositoryPlist("Starcat/StarcatDirect.entitlements")
        let distribution = try repositoryPlist("Starcat/StarcatDirectDistribution.entitlements")
        let widget = try repositoryPlist("Starcat/Resources/Widget/StarcatDirectWidgets.entitlements")
        let widgetGroups = try #require(widget[groupKey] as? [String])
        #expect(widgetGroups == [expectedGroup])
        for host in [development, distribution] {
            let groups = try #require(host[groupKey] as? [String])
            #expect(Set(groups) == Set([expectedGroup, "8WCUMGCWMB.com.starcat.app.localai"]))
        }
        #expect(widget["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(distribution["com.apple.security.app-sandbox"] == nil)
        #expect(distribution["com.apple.security.get-task-allow"] == nil)

        for path in [
            "Starcat/Generated/Info.direct.generated.plist",
            "Starcat/Generated/WidgetInfo.direct.generated.plist",
        ] {
            let info = try repositoryPlist(path)
            #expect(try WidgetSharedConfiguration.appGroupIdentifier(infoDictionary: info) == expectedGroup)
        }
        #expect(AppStoreToDirectImportIdentity.directWidgetGroupID == expectedGroup)
    }

    @Test("App Group 缺失或不属于 Starcat Widget 命名空间时拒绝")
    func rejectsInvalidAppGroups() {
        #expect(throws: WidgetSharedConfigurationError.missingAppGroupIdentifier) {
            try WidgetSharedConfiguration.appGroupIdentifier(infoDictionary: [:])
        }
        #expect(
            throws: WidgetSharedConfigurationError.invalidAppGroupIdentifier(
                "group.example.widgets"
            )
        ) {
            try WidgetSharedConfiguration.appGroupIdentifier(
                infoDictionary: [
                    WidgetSharedConfiguration.appGroupInfoKey: "group.example.widgets"
                ]
            )
        }
        #expect(
            throws: WidgetSharedConfigurationError.invalidAppGroupIdentifier(
                "1234567890.com.starcat.app.direct.widgets"
            )
        ) {
            try WidgetSharedConfiguration.appGroupIdentifier(
                infoDictionary: [
                    WidgetSharedConfiguration.appGroupInfoKey:
                        "1234567890.com.starcat.app.direct.widgets"
                ]
            )
        }
    }

    /// 从源码位置定位配置文件，避免测试进程工作目录随 Xcode / CLI 入口变化。
    private func repositoryPlist(_ path: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-widget-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeRepository(id: Int64) -> WidgetRepository {
        WidgetRepository(
            id: id,
            owner: "owner",
            name: "repo-\(id)",
            description: "description",
            language: "Swift",
            starsCount: 42,
            tags: ["Widget"],
            status: "using",
            focusSource: .using,
            avatarFileName: nil,
            openURL: URL(string: "starcat://repo/owner/repo-\(id)?v=1&rid=\(id)")!
        )
    }

    private func makeRelease(id: Int64, repositoryID: Int64) -> WidgetRelease {
        WidgetRelease(
            id: id,
            repositoryID: repositoryID,
            owner: "owner",
            repositoryName: "repo-\(repositoryID)",
            tagName: "v1.0.0",
            displayName: "Release",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPrerelease: false,
            avatarFileName: nil,
            openURL: URL(
                string: "starcat://repo/owner/repo-\(repositoryID)/releases?v=1&rid=\(repositoryID)&release_id=\(id)"
            )!
        )
    }

    private func makeCollectionTrend() -> WidgetCollectionTrend {
        WidgetCollectionTrend(
            totalCount: 3,
            addedInLast30DaysCount: 2,
            weeklyPoints: [
                WidgetCollectionTrendPoint(
                    weekStart: Date(timeIntervalSince1970: 1_753_660_800),
                    count: 2
                )
            ],
            dailyPoints: [
                WidgetCollectionTrendDay(
                    date: Date(timeIntervalSince1970: 1_753_660_800),
                    count: 2
                )
            ],
            statusBreakdown: WidgetCollectionStatusBreakdown(
                unreadCount: 1,
                readCount: 1,
                usingCount: 1
            )
        )
    }

    private func makeContributionActivity() -> WidgetContributionActivity {
        WidgetContributionActivity(
            totalContributions: 1_088,
            todayContributions: 5,
            bestDayContributions: 57,
            weeks: [
                WidgetContributionWeek(days: [
                    WidgetContributionDay(
                        date: "2026-08-29",
                        count: 5,
                        level: .secondQuartile,
                        weekday: 6
                    )
                ])
            ],
            stats: WidgetContributionStats(
                commits: 900,
                issues: 78,
                pullRequests: 103,
                reviews: 120,
                repositories: 7
            )
        )
    }
}
