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

    @Test("ready 快照可以按 v1 契约往返编码")
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
                unreadReleases: [makeRelease(id: 10, repositoryID: 1)]
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
                unreadReleases: [makeRelease(id: 10, repositoryID: 1)]
            )

            #expect(snapshot.focusRepositories.isEmpty)
            #expect(snapshot.rediscoveryRepository == nil)
            #expect(snapshot.unreadReleaseCount == 0)
            #expect(snapshot.unreadReleases.isEmpty)
        }

        try withTemporaryDirectory { directory in
            let store = WidgetSnapshotStore(containerURL: directory)
            try store.save(.empty(state: .signedOut))
            let loaded = try store.load()

            #expect(loaded.accountState == .signedOut)
            #expect(loaded.focusRepositories.isEmpty)
            #expect(loaded.unreadReleases.isEmpty)
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
                    "group.com.starcat.app.direct.widgets"
            ]
        )

        #expect(store == "group.com.starcat.app.store.widgets")
        #expect(direct == "group.com.starcat.app.direct.widgets")
        #expect(store != direct)
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
}
