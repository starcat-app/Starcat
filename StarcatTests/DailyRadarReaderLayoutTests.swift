//
//  DailyRadarReaderLayoutTests.swift
//  Starcat
//
//  锁定每日热点阅读区与日期按钮的宽度策略，避免阅读区过窄或切日期时布局跳动。
//

import AppKit
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

    /// 仅测量字体，不创建窗口；补零日期在所有语言和字号下都不应随月份、日期伸缩。
    @MainActor func testCompactDateWidthStaysStableAtEveryInterfaceScale() {
        for appLocale in AppLocale.allCases where appLocale != .system {
            let reference = DailyRadarDateFormatting.compactLabel("2026-01-01", locale: appLocale.effectiveLocale)
            for month in 1...12 {
                for day in [1, 11, 28] {
                    let businessDate = String(format: "2026-%02d-%02d", month, day)
                    let label = DailyRadarDateFormatting.compactLabel(businessDate, locale: appLocale.effectiveLocale)
                    for scale in InterfaceScale.allCases {
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: scale.scaled(12), weight: .regular)
                        ]
                        let textWidth = (label as NSString).size(withAttributes: attributes).width
                        let referenceWidth = (reference as NSString).size(withAttributes: attributes).width
                        XCTAssertEqual(
                            textWidth, referenceWidth, accuracy: 0.1,
                            "\(appLocale.rawValue) / \(scale.rawValue): \(label)"
                        )
                    }
                }
            }
        }
    }
}
