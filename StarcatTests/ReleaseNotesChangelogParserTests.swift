//
//  ReleaseNotesChangelogParserTests.swift
//  StarcatTests
//
//  覆盖更新说明窗口对 Keep a Changelog 的结构化解析。
//

import XCTest
@testable import Starcat

final class ReleaseNotesChangelogParserTests: XCTestCase {

    func testParseSplitsVersionsAndSections() throws {
        let markdown = """
        # Changelog

        ## 1.2.0

        Intro paragraph.

        ### 新增

        - 新增 Manage 仓库置顶，支持 Pin / Unpin。
        - 新增分享链接功能。

        ### 优化

        - 优化添加标签 UI。

        ### 修复

        - 修复偶发无响应。

        ## 1.1.0

        ### New

        - Added hybrid retrieval.
        """

        let document = ChangelogParser.parse(markdown)
        XCTAssertEqual(document.versions.count, 2)

        let latest = try XCTUnwrap(document.latestVersion)
        XCTAssertEqual(latest.title, "1.2.0")
        XCTAssertEqual(latest.summary, "Intro paragraph.")
        XCTAssertEqual(latest.sections.map(\.title), ["新增", "优化", "修复"])
        XCTAssertEqual(latest.sections.map(\.kind), [.added, .improved, .fixed])
        XCTAssertEqual(latest.sections[0].items.count, 2)
        XCTAssertEqual(latest.sections[0].items[0].title, "Manage 仓库置顶")
        XCTAssertEqual(latest.sections[0].items[0].detail, "支持 Pin / Unpin。")
        XCTAssertEqual(latest.sections[0].items[1].title, "分享链接功能。")
        XCTAssertNil(latest.sections[0].items[1].detail)

        let previous = try XCTUnwrap(document.previousVersions.first)
        XCTAssertEqual(previous.sections.first?.kind, .added)
    }

    func testSplitItemPrefersEmDashAndStripsCategoryVerb() {
        let split = ChangelogParser.splitItem("Added repository pinning — with Pin and Unpin")
        XCTAssertEqual(split.title, "repository pinning")
        XCTAssertEqual(split.detail, "with Pin and Unpin")
    }

    func testBulletTextSupportsTaskListPrefix() {
        XCTAssertEqual(
            ChangelogParser.bulletText(from: "- [x] Done item"),
            "Done item"
        )
        XCTAssertNil(ChangelogParser.bulletText(from: "not a bullet"))
    }

    func testBodyWithoutSectionsStaysEmptyForMarkdownFallback() {
        let body = ChangelogParser.parseBody("Just a free-form note without headings.")
        XCTAssertEqual(body.summary, "Just a free-form note without headings.")
        XCTAssertTrue(body.sections.isEmpty)
    }
}
