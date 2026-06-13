//
//  RepoWikiMenuStateTests.swift
//  StarcatTests
//
//  覆盖 Wiki 菜单的纯状态转换：只展示 indexed、过滤未知来源/危险 URL、固定来源顺序。
//

import Testing
import Foundation
@testable import Starcat

@Suite("RepoWikiMenu 状态转换")
struct RepoWikiMenuStateTests {
    private func item(source: WikiSource, status: WikiProbeStatus, url: String) -> WikiStatusItem {
        WikiStatusItem(
            source: source,
            status: status,
            url: URL(string: url)!,
            probeMethod: nil,
            httpStatus: nil,
            matchedSignals: nil
        )
    }

    @Test("只保留 indexed，并按 DeepWiki、Zread、Code Wiki 排序")
    func filtersAndSorts() {
        let links = RepoWikiMenuState.make(items: [
            item(source: .codeWiki, status: .indexed, url: "https://codewiki.google/github.com/a/b"),
            item(source: .zread, status: .indexed, url: "https://zread.ai/a/b"),
            item(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/a/b"),
            item(source: .zread, status: .error, url: "https://zread.ai/error")
        ])

        #expect(links.map(\.source) == [.deepWiki, .zread, .codeWiki])
    }

    @Test("全未收录或错误时返回空菜单")
    func emptyWhenNoIndexedResult() {
        let links = RepoWikiMenuState.make(items: [
            item(source: .deepWiki, status: .notIndexed, url: "https://deepwiki.com/a/b"),
            item(source: .zread, status: .error, url: "https://zread.ai/a/b")
        ])
        #expect(links.isEmpty)
    }

    @Test("未知来源和非 http/https URL 被过滤")
    func rejectsUnknownSourceAndUnsafeURL() {
        let links = RepoWikiMenuState.make(items: [
            item(source: .unknown("future"), status: .indexed, url: "https://future.example/a/b"),
            item(source: .zread, status: .indexed, url: "file:///tmp/wiki"),
            item(source: .deepWiki, status: .indexed, url: "https://deepwiki.com/a/b")
        ])
        #expect(links.map(\.source) == [.deepWiki])
    }
}
