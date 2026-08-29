//
//  SnapshotAvatarImageTests.swift
//  StarcatTests
//
//  锁定导出 logo 必须能命中详情页 / 列表已经缓存过的 Kingfisher key，
//  不能只查 28pt 改写后的 `size=56`。
//

import AppKit
import Kingfisher
import Testing
@testable import Starcat

@Suite("Snapshot avatar image")
struct SnapshotAvatarImageTests {

    @Test("导出 28pt 仍会查 hero 64pt 和列表 40pt 的 cache key")
    func cacheKeysIncludeHeroAndListSizes() {
        let keys = SnapshotAvatarImage.cacheKeys(
            owner: "starcat-app",
            ownerAvatar: "https://avatars.githubusercontent.com/u/1?v=4",
            displayDiameter: 28
        )

        #expect(keys.contains("https://github.com/starcat-app.png?size=128"))
        #expect(keys.contains("https://github.com/starcat-app.png?size=80"))
        #expect(keys.contains("https://avatars.githubusercontent.com/u/1?v=4&s=56"))
        #expect(keys.contains("https://avatars.githubusercontent.com/u/1?v=4"))
        #expect(keys.first == "https://avatars.githubusercontent.com/u/1?v=4&s=56")
    }

    @Test("没有 ownerAvatar 时仍能靠 RepoAvatarURL 命中列表缓存")
    func cacheKeysFallBackToRepoAvatarURL() {
        let keys = SnapshotAvatarImage.cacheKeys(
            owner: "starcat-app",
            ownerAvatar: nil,
            displayDiameter: 28
        )

        #expect(keys.contains("https://github.com/starcat-app.png?size=80"))
        #expect(keys.contains("https://github.com/starcat-app.png?size=128"))
        #expect(keys.contains("https://github.com/starcat-app.png?size=56"))
    }

    @Test @MainActor
    func cachedNSImageHitsHeroSizedKey() {
        let cache = ImageCache(name: "SnapshotAvatarImageTests-\(UUID().uuidString)")
        defer {
            cache.clearMemoryCache()
            cache.clearDiskCache()
        }

        let stored = NSImage(size: NSSize(width: 4, height: 4))
        stored.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: stored.size).fill()
        stored.unlockFocus()

        cache.store(stored, forKey: "https://github.com/starcat-app.png?size=128", toDisk: false)

        let found = SnapshotAvatarImage.cachedNSImage(
            owner: "starcat-app",
            ownerAvatar: "https://avatars.githubusercontent.com/u/1?v=4",
            displayDiameter: 28,
            cache: cache
        )
        #expect(found != nil)
    }

    @Test @MainActor
    func cachedNSImageReturnsNilWhenCacheMisses() {
        let cache = ImageCache(name: "SnapshotAvatarImageMiss-\(UUID().uuidString)")
        defer {
            cache.clearMemoryCache()
            cache.clearDiskCache()
        }

        let found = SnapshotAvatarImage.cachedNSImage(
            owner: "missing-owner",
            ownerAvatar: nil,
            displayDiameter: 28,
            cache: cache
        )
        #expect(found == nil)
    }
}
