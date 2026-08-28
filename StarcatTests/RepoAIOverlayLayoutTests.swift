//
//  RepoAIOverlayLayoutTests.swift
//  StarcatTests
//
//  锁定 inline AI 浮层高度：有 README / 洞察 tab 时扣掉实测高度，
//  没有 tab 的详情页继续留原来的 16pt 顶距。
//

import SwiftUI
import Testing
@testable import Starcat

@Suite("AI 浮层高度")
struct RepoAIOverlayLayoutTests {

    @Test("Manage 详情扣掉 tab 行高度，顶边贴在切换行底部")
    func subtractsTabChromeInset() {
        let height = RepoAIOverlayLayout.panelHeight(
            availableHeight: 800,
            topChromeInset: 40,
            isMaximized: false
        )

        #expect(height == 800 - RepoAIOverlayLayout.panelBottomInset - 40)
    }

    @Test("没有 tab 行时保留原来的 16pt 顶距")
    func usesFallbackTopInsetWhenChromeMissing() {
        let height = RepoAIOverlayLayout.panelHeight(
            availableHeight: 800,
            topChromeInset: 0,
            isMaximized: false
        )

        #expect(height == 800 - RepoAIOverlayLayout.panelBottomInset - RepoAIOverlayLayout.fallbackTopInset)
    }

    @Test("最大化只提高最小高度下限，顶距规则与展开态相同")
    func maximizedUsesSameTopInsetRule() {
        let expanded = RepoAIOverlayLayout.panelHeight(
            availableHeight: 400,
            topChromeInset: 36,
            isMaximized: false
        )
        let maximized = RepoAIOverlayLayout.panelHeight(
            availableHeight: 400,
            topChromeInset: 36,
            isMaximized: true
        )

        #expect(expanded == max(RepoAIOverlayLayout.panelMinHeight, 400 - 34 - 36))
        #expect(maximized == max(RepoAIOverlayLayout.maximizedMinHeight, 400 - 34 - 36))
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
