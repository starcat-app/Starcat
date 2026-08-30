//
//  StarHistoryAxisValueFormatterTests.swift
//  StarcatTests
//
//  验证 Star 历史曲线纵轴在不同数量级下保持紧凑且可预测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Star History Axis Value Formatter")
struct StarHistoryAxisValueFormatterTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    @Test("千位以下保留完整整数")
    func preservesSmallValues() {
        #expect(format(0) == "0")
        #expect(format(999) == "999")
    }

    @Test("千位数使用 K 并最多保留一位小数")
    func formatsThousands() {
        #expect(format(1_000) == "1K")
        #expect(format(1_500) == "1.5K")
        #expect(format(50_000) == "50K")
        #expect(format(200_000) == "200K")
    }

    @Test("百万位使用 M 并避免显示一千 K")
    func formatsMillions() {
        #expect(format(999_500) == "1M")
        #expect(format(1_200_000) == "1.2M")
    }

    private func format(_ value: Double) -> String {
        StarHistoryAxisValueFormatter.string(from: value, locale: locale)
    }
}
