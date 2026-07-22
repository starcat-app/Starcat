//
//  RepoDetailScaffoldTests.swift
//  StarcatTests
//
//  详情页 Hero 折叠门控与 progress 映射的单元测试。
//

import SwiftUI
import XCTest
@testable import Starcat

@MainActor
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

    // MARK: - cappedMetadataPanelHeight

    func testCappedMetadataPanelHeight_keepsShortHeroNaturalHeight() throws {
        let height = try XCTUnwrap(
            RepoDetailScaffold<EmptyView, EmptyView>.cappedMetadataPanelHeight(
                naturalHeight: 420,
                availableHeight: 900,
                minimumBodyHeight: 160
            )
        )

        XCTAssertEqual(height, 420)
    }

    func testCappedMetadataPanelHeight_reservesBodyViewportForOverflowingHero() throws {
        let height = try XCTUnwrap(
            RepoDetailScaffold<EmptyView, EmptyView>.cappedMetadataPanelHeight(
                naturalHeight: 980,
                availableHeight: 900,
                minimumBodyHeight: 160
            )
        )

        XCTAssertEqual(height, 740)
    }

    func testCappedMetadataPanelHeight_keepsMinimumWindowWithinParentViewport() throws {
        let minimumWindowContentHeight: CGFloat = 763
        let minimumBodyHeight: CGFloat = 160
        let heroHeight = try XCTUnwrap(
            RepoDetailScaffold<EmptyView, EmptyView>.cappedMetadataPanelHeight(
                naturalHeight: 1_200,
                availableHeight: minimumWindowContentHeight,
                minimumBodyHeight: minimumBodyHeight
            )
        )

        XCTAssertEqual(heroHeight, 603)
        XCTAssertEqual(heroHeight + minimumBodyHeight, minimumWindowContentHeight)
    }

    func testCappedMetadataPanelHeight_waitsForValidMeasurements() {
        XCTAssertNil(RepoDetailScaffold<EmptyView, EmptyView>.cappedMetadataPanelHeight(
            naturalHeight: 0,
            availableHeight: 900,
            minimumBodyHeight: 160
        ))
        XCTAssertNil(RepoDetailScaffold<EmptyView, EmptyView>.cappedMetadataPanelHeight(
            naturalHeight: 500,
            availableHeight: 150,
            minimumBodyHeight: 160
        ))
    }

    func testCappedMetadataPanelHeight_allowsCollapseUsingVisibleHeroHeight() throws {
        let visibleHeight = try XCTUnwrap(
            RepoDetailScaffold<EmptyView, EmptyView>.cappedMetadataPanelHeight(
                naturalHeight: 980,
                availableHeight: 900,
                minimumBodyHeight: 160
            )
        )

        XCTAssertTrue(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: 760,
            panelHeight: visibleHeight
        ))
        XCTAssertFalse(RepoDetailScaffold<EmptyView, EmptyView>.canCollapseHero(
            scrollOverflow: 760,
            panelHeight: 980
        ))
    }
}
