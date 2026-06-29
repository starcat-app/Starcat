//
//  RepoDetailScaffoldTests.swift
//  StarcatTests
//
//  详情页 Hero 折叠门控与 progress 映射的单元测试。
//

import SwiftUI
import XCTest
@testable import Starcat

final class RepoDetailScaffoldTests: XCTestCase {

    // MARK: - metadataCollapseProgress

    func testMetadataCollapseProgress_staysZeroBeforeStartThreshold() {
        XCTAssertEqual(RepoDetailScaffold<EmptyView, EmptyView>.metadataCollapseProgress(for: 0), 0)
        XCTAssertEqual(RepoDetailScaffold<EmptyView, EmptyView>.metadataCollapseProgress(for: 8), 0)
    }

    func testMetadataCollapseProgress_reachesOneAfterFullDistance() {
        XCTAssertEqual(RepoDetailScaffold<EmptyView, EmptyView>.metadataCollapseProgress(for: 72), 1, accuracy: 0.001)
        XCTAssertEqual(RepoDetailScaffold<EmptyView, EmptyView>.metadataCollapseProgress(for: 200), 1)
    }

    func testMetadataCollapseProgress_isHalfAtMidpoint() {
        XCTAssertEqual(
            RepoDetailScaffold<EmptyView, EmptyView>.metadataCollapseProgress(for: 40),
            0.5,
            accuracy: 0.001
        )
    }

    // MARK: - canCollapseHero

    func testCanCollapseHero_rejectsUnknownOverflow() {
        XCTAssertFalse(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: nil,
            panelHeight: 300
        ))
    }

    func testCanCollapseHero_rejectsUnmeasuredPanel() {
        XCTAssertFalse(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: 400,
            panelHeight: 0
        ))
    }

    func testCanCollapseHero_rejectsShortOverflow() {
        // HelloGitHub 类边界：有滚动条但余量小于 Hero 高度。
        XCTAssertFalse(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: 120,
            panelHeight: 320
        ))
    }

    func testCanCollapseHero_allowsSufficientOverflow() {
        XCTAssertTrue(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: 400,
            panelHeight: 320
        ))
    }

    func testCanCollapseHero_allowsExactThreshold() {
        XCTAssertTrue(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: 320,
            panelHeight: 320
        ))
    }

    // MARK: - expandedScrollOverflow

    func testExpandedScrollOverflow_recoversExpandedHeroOverflow() throws {
        // README 边界场景：Hero 折叠后 WebView 可视区变高，当前 overflow 会变小；
        // 折算回展开态后，折叠资格不应因为布局反馈而反复翻转。
        let recovered = RepoDetailScaffold<EmptyView, EmptyView>.expandedScrollOverflow(
            currentOverflow: 120,
            panelHeight: 320,
            collapseProgress: 0.75
        )
        let unwrapped = try XCTUnwrap(recovered)

        XCTAssertEqual(unwrapped, 360, accuracy: 0.001)
        XCTAssertTrue(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: unwrapped,
            panelHeight: 320
        ))
    }

    func testExpandedScrollOverflow_clampsCollapseProgress() throws {
        let recovered = try XCTUnwrap(RepoDetailScaffold<EmptyView, EmptyView>.expandedScrollOverflow(
            currentOverflow: 100,
            panelHeight: 200,
            collapseProgress: 1.5
        ))

        XCTAssertEqual(
            recovered,
            300,
            accuracy: 0.001
        )
    }
}
