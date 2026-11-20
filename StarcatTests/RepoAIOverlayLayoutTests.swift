//
//  RepoAIOverlayLayoutTests.swift
//  StarcatTests
//
//  锁定详情浮层在两条栏外侧的共享间距。
//

import SwiftUI
import Testing
@testable import Starcat

@Suite("AI 浮层高度")
struct RepoAIOverlayLayoutTests {

    @Test("笔记和 AI 浮层在两条栏的实测高度外各留 4pt")
    func addsGapToMeasuredChromeInsets() {
        let insets = RepoDetailOverlayLayout.verticalInsets(
            topChromeInset: 40,
            bottomChromeInset: 24
        )

        #expect(insets.top == 44)
        #expect(insets.bottom == 28)
    }

    @Test("详情模式没有对应栏时从正文容器边缘留 4pt")
    func usesBodyEdgesWhenChromeIsAbsent() {
        let insets = RepoDetailOverlayLayout.verticalInsets(
            topChromeInset: 0,
            bottomChromeInset: 0
        )

        #expect(insets.top == 4)
        #expect(insets.bottom == 4)
    }

    @Test("切换行高度 Preference 取较大值，避免被 0 默认值冲掉")
    func overlayTopInsetPreferenceKeepsMeasuredHeight() {
        var value: CGFloat = 0
        RepoDetailAIOverlayTopInsetPreference.reduce(value: &value) { 36 }
        RepoDetailAIOverlayTopInsetPreference.reduce(value: &value) { 0 }
        #expect(value == 36)
    }
}

@Suite("推荐标签行底色")
struct AITagSuggestionRowChromeTests {

    @Test("奇数行使用斑马纹，偶数行保持透明")
    func zebraAlternatesByIndex() {
        #expect(AITagSuggestionRowChrome.background(rowIndex: 0, isHovered: false) == Color.clear)
        #expect(
            AITagSuggestionRowChrome.background(rowIndex: 1, isHovered: false)
                == Color.primary.opacity(0.045)
        )
    }

    @Test("悬停覆盖斑马纹，表达光标所在行")
    func hoverOverridesZebra() {
        let hovered = AITagSuggestionRowChrome.background(rowIndex: 1, isHovered: true)
        #expect(hovered == Color.accentColor.opacity(0.10))
    }

    @Test("置信度按阈值着色，方便扫读高低")
    func confidenceUsesThresholdColors() {
        #expect(AITagSuggestionRowChrome.confidenceColor(0.95) == Color.green)
        #expect(AITagSuggestionRowChrome.confidenceColor(0.80) == Color.accentColor)
        #expect(AITagSuggestionRowChrome.confidenceColor(0.50) == Color.orange)
    }
}
