//
//  DailyRadarReaderLayoutTests.swift
//  Starcat
//
//  锁定每日热点详情阅读区的宽度策略，避免回归到固定 720pt。
//

import XCTest
@testable import Starcat

final class DailyRadarReaderLayoutTests: XCTestCase {
    func testContentWidthAdaptsAndHasLowerBound() {
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: 300), 244)
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: 760), 704)
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: 1_000), 840)
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: 1_200), 1_008)
    }

    func testContentWidthCapsOnWideWindowsAndInvalidInput() {
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: 1_600), 1_120)
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: .infinity), 760)
        XCTAssertEqual(DailyRadarReaderLayout.contentMaxWidth(in: 0), 760)
    }
}
