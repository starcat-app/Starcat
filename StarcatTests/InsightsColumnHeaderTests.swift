//
//  InsightsColumnHeaderTests.swift
//  StarcatTests
//
//  离屏验证洞察统一顶栏的紧凑高度及窄宽换行。
//

import SwiftUI
import Testing
@testable import Starcat

/// 字体和按钮不能为压缩留白而缩小，顶栏必须容纳实际内容，而不是固定裁成 64pt。
@MainActor
@Suite("Insights compact header")
struct InsightsColumnHeaderTests {
    @Test("常规顶栏保持 64pt，而非原来的 84pt")
    func compactHeight() throws {
        let size = try measuredSize(InsightsColumnHeader {
            Color.clear.frame(height: 36)
        } controls: {
            EmptyView()
        }, width: 320)
        #expect(size.height == 64)
        #expect(size.width == 320)
        #expect(InsightsColumnChrome.headerVerticalPadding == 8)
        #expect(InsightsColumnChrome.contentTopPadding == 10)
    }

    @Test("父栏分配剩余高度时，顶栏仍贴合内容而不挤占正文", arguments: [CGFloat(64), 200, 600])
    func finiteParentHeightDoesNotStretchHeader(proposedHeight: CGFloat) throws {
        let size = try measuredSize(InsightsColumnHeader {
            Color.clear.frame(height: 36)
        } controls: {
            EmptyView()
        }, width: 320, height: proposedHeight)
        #expect(size.height == 64)
    }

    @Test("内容超出紧凑高度时自然增高，不缩放或裁切", arguments: [CGFloat(52), 80, 112])
    func tallContentGrows(contentHeight: CGFloat) throws {
        let size = try measuredSize(InsightsColumnHeader {
            Color.clear.frame(height: contentHeight)
        } controls: {
            EmptyView()
        }, width: 260)
        #expect(size.height == contentHeight + 2 * InsightsColumnChrome.headerVerticalPadding)
    }

    @Test("窄栏控件另起一行，恢复宽度后顶栏收紧")
    func controlsStackOnlyWhenNeeded() throws {
        let header = InsightsColumnHeader {
            Color.clear.frame(width: 150, height: 32)
        } controls: {
            Color.clear.frame(width: 150, height: 28)
        }
        let wide = try measuredSize(header, width: 720)
        let narrow = try measuredSize(header, width: 320)
        let widened = try measuredSize(header, width: 720)
        #expect(wide.height == 64)
        #expect(narrow.height == 86)
        #expect(narrow.width == 320)
        #expect(widened.height == wide.height)
    }

    /// 使用真实分类译文验证容器；仍不代替主窗口拖拽、分栏和按钮点击的人工验收。
    @Test("所有支持语言的标题与控件在窄宽、大字号和 RTL 下仍由内容撑高",
          arguments: AppLocale.allCases.filter { $0 != .system })
    func localizedContentIsNotHeightClipped(locale: AppLocale) throws {
        for scale in InterfaceScale.allCases {
            for topic in InsightsTopic.allCases {
                for width in [CGFloat(320), 720] {
                    let content = VStack(alignment: .leading, spacing: 2) {
                        Text(topic.titleKey)
                            .font(scale.font(.panelTitle))
                        Text(topic.subtitleKey)
                            .font(scale.font(.caption))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let naturalSize = try measuredSize(
                        content.fixedSize(horizontal: false, vertical: true)
                            .environment(\.locale, locale.effectiveLocale),
                        width: width - 48
                    )
                    let header = InsightsColumnHeader {
                        content
                    } controls: {
                        HStack {
                            Text("insights.scope.starred")
                            Text("insights.scope.knowledge")
                        }
                        .font(scale.font(.caption))
                    }
                    let headerSize = try measuredSize(header.environment(\.locale, locale.effectiveLocale), width: width)
                    #expect(headerSize.width <= width)
                    #expect(headerSize.height >= 64)
                    #expect(headerSize.height + 0.5 >= naturalSize.height + 2 * InsightsColumnChrome.headerVerticalPadding)
                }
            }
        }
    }

    /// 高度不设提案，确保测到的是自然尺寸，不能用测试自身的固定 frame 掩盖裁切。
    private func measuredSize<Content: View>(_ view: Content, width: CGFloat, height: CGFloat? = nil) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        return try #require(renderer.nsImage).size
    }
}
