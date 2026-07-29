//
//  WidgetAvatarCacheTests.swift
//  StarcatTests
//
//  Widget 头像缓存的本地安全边界测试。
//
//  测试预置缓存命中，不发网络请求；重点验证文件名不可注入路径、同 owner 复用，
//  以及登出清理只删除 avatars 子目录。
//

import Foundation
import Testing
@testable import Starcat

@Suite("WidgetAvatarCache")
struct WidgetAvatarCacheTests {

    @Test("owner 使用稳定哈希文件名且不包含原始路径字符")
    func createsStableSafeFileName() {
        let first = WidgetAvatarCache.fileName(owner: "SwiftLang")
        let second = WidgetAvatarCache.fileName(owner: "swiftlang")
        let hostile = WidgetAvatarCache.fileName(owner: "../escape")

        #expect(first == second)
        #expect(first.count == 68)
        #expect(first.hasSuffix(".png"))
        #expect(hostile.hasSuffix(".png"))
        #expect(!hostile.contains("/"))
        #expect(!hostile.contains(".."))
    }

    @Test("缓存命中会为同 owner 的仓库与 Release 复用相对文件名")
    func enrichesSnapshotFromExistingCache() async throws {
        try await withTemporaryDirectory { directory in
            let cache = WidgetAvatarCache(containerURL: directory)
            let owner = "swiftlang"
            let fileName = WidgetAvatarCache.fileName(owner: owner)
            let avatarDirectory = WidgetSharedConfiguration.avatarsDirectoryURL(
                containerURL: directory
            )
            try FileManager.default.createDirectory(
                at: avatarDirectory,
                withIntermediateDirectories: true
            )
            try Data([0x89, 0x50, 0x4E, 0x47]).write(
                to: avatarDirectory.appendingPathComponent(fileName)
            )

            let snapshot = WidgetSnapshot(
                accountState: .ready,
                focusRepositories: [makeRepository(owner: owner)],
                unreadReleaseCount: 1,
                unreadReleases: [makeRelease(owner: owner)]
            )
            let enriched = await cache.enrich(snapshot)

            #expect(enriched.focusRepositories.first?.avatarFileName == fileName)
            #expect(enriched.unreadReleases.first?.avatarFileName == fileName)
        }
    }

    @Test("clear 只删除 avatars 子目录并保留共享容器其它文件")
    func clearsOnlyAvatarDirectory() throws {
        try withTemporaryDirectory { directory in
            let avatarDirectory = WidgetSharedConfiguration.avatarsDirectoryURL(
                containerURL: directory
            )
            try FileManager.default.createDirectory(
                at: avatarDirectory,
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: avatarDirectory.appendingPathComponent("avatar.png"))
            let marker = directory.appendingPathComponent("keep.json")
            try Data([2]).write(to: marker)

            WidgetAvatarCache(containerURL: directory).clear()

            #expect(!FileManager.default.fileExists(atPath: avatarDirectory.path))
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-widget-avatar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-widget-avatar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func makeRepository(owner: String) -> WidgetRepository {
        WidgetRepository(
            id: 1,
            owner: owner,
            name: "swift",
            description: nil,
            language: "Swift",
            starsCount: 1,
            tags: [],
            status: "using",
            focusSource: .using,
            avatarFileName: nil,
            openURL: URL(string: "starcat://repo/\(owner)/swift?v=1&rid=1")!
        )
    }

    private func makeRelease(owner: String) -> WidgetRelease {
        WidgetRelease(
            id: 2,
            repositoryID: 1,
            owner: owner,
            repositoryName: "swift",
            tagName: "v1",
            displayName: nil,
            publishedAt: nil,
            isPrerelease: false,
            avatarFileName: nil,
            openURL: URL(
                string: "starcat://repo/\(owner)/swift/releases?v=1&rid=1&release_id=2"
            )!
        )
    }
}
