//
//  MarkdownTypographyTests.swift
//  StarcatTests
//
//  锁住跨渲染器的阅读偏好契约：四档只缩放一次，历史偏移越界时统一钳制。
//

import Testing
@testable import Starcat

@Suite("Markdown 阅读字号")
@MainActor
struct MarkdownTypographyTests {
    @Test("四档倍率与阅读偏移共用同一公式", arguments: InterfaceScale.allCases)
    func readingSize(scale: InterfaceScale) {
        #expect(MarkdownTypography.bodyFontSize(scale: scale) == 16 * scale.multiplier)
        #expect(MarkdownTypography.bodyFontSize(scale: scale, adjustment: 2) == 18 * scale.multiplier)
        #expect(MarkdownTypography.bodyFontSize(scale: scale, adjustment: -99) == 14 * scale.multiplier)
        #expect(MarkdownTypography.bodyFontSize(scale: scale, adjustment: 99) == 20 * scale.multiplier)
    }

    @Test("HTML 与原生标题和代码使用同一层级")
    func hierarchy() {
        #expect(MarkdownTypography.Heading.allCases.map(\.ratio) == [1.8, 1.45, 1.2, 1, 0.9, 0.85])
        #expect(MarkdownTypography.inlineCodeRatio == 0.85)
        #expect(MarkdownTypography.codeBlockRatio == 1)
    }
}
