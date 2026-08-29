//
//  GitHubStarListVisibilityBadgeTests.swift
//  StarcatTests
//
//  中栏数量行只给真实 GitHub List 挂公开 / 私有标识。
//  未分组和其它星标入口没有可见性，附件槽必须保持空。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubStarListVisibilityBadge")
struct GitHubStarListVisibilityBadgeTests {

    @Test("公开分组使用 globe，并给出公开 tooltip")
    func publicListShowsGlobe() {
        let badge = GitHubStarListVisibilityBadge.make(
            selection: .githubStarList("list-ai"),
            lists: [makeList(id: "list-ai", isPrivate: false)]
        )

        #expect(badge == .public)
        #expect(badge?.systemImage == "globe")
        #expect(badge?.helpKey == "githubStarLists.visibility.public")
    }

    @Test("私有分组使用 lock.fill，并给出私有 tooltip")
    func privateListShowsLock() {
        let badge = GitHubStarListVisibilityBadge.make(
            selection: .githubStarList("list-secret"),
            lists: [makeList(id: "list-secret", isPrivate: true)]
        )

        #expect(badge == .private)
        #expect(badge?.systemImage == "lock.fill")
        #expect(badge?.helpKey == "githubStarLists.visibility.private")
    }

    @Test("未分组没有公开私有属性，不显示标识")
    func ungroupedHasNoBadge() {
        #expect(
            GitHubStarListVisibilityBadge.make(
                selection: .githubStarListUngrouped,
                lists: [makeList(id: "list-ai", isPrivate: true)]
            ) == nil
        )
    }

    @Test("全部星标和其它星标入口不显示标识")
    func otherStarredEntriesHaveNoBadge() {
        let lists = [makeList(id: "list-ai", isPrivate: false)]

        #expect(GitHubStarListVisibilityBadge.make(selection: .allStars, lists: lists) == nil)
        #expect(GitHubStarListVisibilityBadge.make(selection: .untagged, lists: lists) == nil)
        #expect(GitHubStarListVisibilityBadge.make(selection: .tag("swift"), lists: lists) == nil)
    }

    @Test("侧栏选中的 List 还没同步到本地时不显示标识")
    func missingListHasNoBadge() {
        #expect(
            GitHubStarListVisibilityBadge.make(
                selection: .githubStarList("missing"),
                lists: [makeList(id: "list-ai", isPrivate: false)]
            ) == nil
        )
    }

    private func makeList(id: String, isPrivate: Bool) -> GitHubStarList {
        GitHubStarList(
            id: id,
            name: "AI",
            description: nil,
            isPrivate: isPrivate,
            colorHex: "#0A84FF",
            position: 0,
            createdAt: nil,
            updatedAt: nil,
            syncedAt: "2026-08-29T00:00:00Z"
        )
    }
}
