//
//  ReleaseWorkspaceTests.swift
//  StarcatTests
//
//  验证版本选择、构件匹配和下载会话；测试不弹保存面板，也不需要操作真实窗口。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Release workspace")
struct ReleaseWorkspaceTests {
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(id: 42, name: name, contentType: "application/octet-stream", size: 12,
                     browserDownloadUrl: "https://example.com/file", downloadCount: 0)
    }

    @Test("只推荐明确适用本机的 macOS 包，不推荐签名、符号包、其他平台或未知架构")
    func macRecommendations() {
        for name in ["DBX-arm64.dmg", "tool-aarch64-apple-darwin.tar.gz", "DBX-macOS-arm64.zip"] {
            let build = ReleaseBuildArtifact(asset(name))
            #expect(build.isRecommended(for: .arm64))
            #expect(!build.isRecommended(for: .intel))
        }
        for name in ["DBX-macOS-universal2.zip", "app-universal.pkg"] {
            let build = ReleaseBuildArtifact(asset(name))
            #expect(build.isRecommended(for: .arm64) && build.isRecommended(for: .intel))
        }
        #expect(ReleaseBuildArtifact(asset("tool-x86_64-apple-darwin.tar.xz")).isRecommended(for: .intel))
        for name in ["app-arm64.dmg.sha256", "app-arm64.pkg.sig", "app-arm64.dmg.blockmap", "app.dmg",
                     "debug-darwin-arm64.zip", "app-linux-arm64.tar.gz", "app-android-arm64.zip",
                     "app-win-arm64.zip", "app-arm64.zip", "app-macos-windows-arm64.zip"] {
            #expect(!ReleaseBuildArtifact(asset(name)).isRecommended(for: .arm64))
        }
    }

    @Test("名称或 MIME 与平台架构取交集；未识别的附件仍可搜索")
    func combinedFilters() {
        let builds = ["tool-darwin-arm64.zip", "tool-linux-amd64.tgz", "app-win-arm64.exe", "checksums.txt"]
            .map { ReleaseBuildArtifact(asset($0)) }
        let filter = ReleaseArtifactFilter(query: " OCTET ", platform: .linux, architecture: .intel)
        #expect(builds.filter(filter.matches).map(\.asset.name) == ["tool-linux-amd64.tgz"])
        #expect(builds.filter(ReleaseArtifactFilter(query: "checksums").matches).count == 1)
        #expect(builds.filter(ReleaseArtifactFilter(platform: .windows, architecture: .intel).matches).isEmpty)
    }

    @Test("下载文件区区分平台安装包、压缩包、签名、校验文件和普通文件")
    func assetIconsUseFileTypes() {
        let cases: [(filename: String, source: BusinessIcon.Source)] = [
            ("app-arm64.DMG", .asset("apple")),
            ("app-universal.pkg", .asset("apple")),
            ("app-x64.exe", .asset("windows11")),
            ("app-x64.msi", .asset("windows11")),
            ("app-arm64.rpm", .asset("linux")),
            ("app-x64.deb", .asset("linux")),
            ("app-x64.AppImage", .asset("linux")),
            ("app-arm64.apk", .asset("android")),
            ("app.tar.gz", .business(.fileArchive)),
            ("app.rpm.SIG", .system("checkmark.seal")),
            ("app.zip.sha256", .system("number")),
            ("latest.json", .system("curlybraces")),
            ("data.unknownext", .business(.file)),
        ]
        for (filename, source) in cases {
            #expect(ReleaseAssetIcon.workspaceStyle(for: filename).source == source)
        }
        #expect(ReleaseAssetIcon.workspaceStyle(for: "app.exe").keepsOriginalColors)
        #expect(ReleaseAssetIcon.workspaceStyle(for: "app.rpm").keepsOriginalColors)
        #expect(ReleaseAssetIcon.iconSource(for: "latest.json") == .business(.file))
    }

    @Test("跨页深链只消费一次，历史已读版本与其他版本都可搜索和定位")
    @MainActor func selectionAndPaging() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBReleaseRepository(database: database)
        try await database.insertRepoFixture(id: 10)
        try await GRDBReleaseSubscriptionRepository(database: database)
            .subscribe(repoId: 10, primingReleaseId: nil, primingTagName: nil)
        let records = (1...25).map { number in
            let date = String(format: "2026-10-%02dT00:00:00Z", number)
            return ReleaseRecord(id: Int64(number), repoId: 10, tagName: "v\(number)", name: "Build \(number)",
                                 htmlUrl: "https://example.com/v\(number)", isPrerelease: false, isDraft: false,
                                 publishedAt: date, isRead: false, fetchedAt: date)
        }
        try await repository.upsertMany(records, isReadDefault: false)
        try await repository.markRead(releaseId: 2, isRead: true)
        let model = ReleaseTimelineViewModel(repository: repository, poll: {})
        model.locate(1)
        await model.reload()
        #expect(model.pendingTarget == 1)
        await model.loadMore()
        #expect(model.selectedID == 1 && model.pendingTarget == nil)
        model.select(2)
        await model.checkNow()
        #expect(model.selectedID == 2)
        model.search = "bUiLd 1"
        #expect(model.selection?.release.name == "Build 19")
        model.search = "does not exist"
        #expect(model.selection == nil)
        model.locate(2)
        #expect(model.search.isEmpty && model.selectedID == 2)
        #expect(model.selection?.release.isRead == true)
        model.search = "Build 2"
        #expect(model.visibleEntries.contains { $0.id == 2 })
        #expect(model.selectedID == 2)
    }

    @Test("下载失败可重试，完成保存真实路径，重新保存取消后不丢 Finder 位置")
    @MainActor func downloadLifecycle() async {
        let destination = URL(fileURLWithPath: "/tmp/user-selected.zip")
        var outcomes: [ReleaseAssetDownloadCoordinator.Outcome] = [.failed(message: "Failed"), .saved(destination), .cancelled]
        let downloads = ReleaseWorkspaceDownloads { _, progress in
            progress(0.4)
            return outcomes.removeFirst()
        }
        let file = asset("app.zip")
        await downloads.start(file)
        #expect(downloads.states[file.id] == .failed("Failed"))
        await downloads.start(file)
        #expect(downloads.states[file.id] == .saved(destination) && downloads.fileURL == destination)
        await downloads.start(file)
        await Task.yield()
        #expect(downloads.states[file.id] == .saved(destination))
    }

    @Test("停止当前下载后可原位重试，取消不会弹错误提示")
    @MainActor func cancelAndRetry() async {
        let file = asset("app.zip")
        let destination = URL(fileURLWithPath: "/tmp/app.zip")
        let (starts, signal) = AsyncStream<Void>.makeStream()
        var attempts = 0
        let downloads = ReleaseWorkspaceDownloads { _, _ in
            attempts += 1
            guard attempts == 1 else { return .saved(destination) }
            signal.yield(())
            do {
                try await Task.sleep(for: .seconds(3))
                return .failed(message: "transfer was not cancelled")
            } catch { return .cancelled }
        }
        let first = Task { await downloads.start(file) }
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
        downloads.cancel(file.id)
        #expect(downloads.states[file.id] == .cancelling)
        await first.value
        #expect(downloads.states[file.id] == nil && downloads.message == nil)
        await downloads.start(file)
        #expect(attempts == 2 && downloads.states[file.id] == .saved(destination))
    }
}
