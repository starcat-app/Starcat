//
//  InsightsColumnHeaderTests.swift
//  StarcatTests
//
//  验证洞察顶栏的紧凑高度、自然增高及共享高度规则；只做离屏布局，不建立窗口或读取桌面。
//

import SwiftUI
import Testing
@testable import Starcat

/// 字体和按钮不能为压缩留白而缩小，顶栏必须容纳实际内容，而不是固定裁成 64pt。
@MainActor
@Suite("Insights compact column headers")
struct InsightsColumnHeaderTests {
    @Test("常规顶栏保持 64pt，而非原来的 84pt")
    func compactHeight() throws {
        let size = try measuredSize(InsightsColumnHeader(height: 64) {
            Color.clear.frame(height: 36)
        }, width: 320)
        #expect(size.height == 64)
        #expect(size.width == 320)
        #expect(InsightsColumnChrome.headerVerticalPadding == 8)
        #expect(InsightsColumnChrome.contentTopPadding == 10)
    }

    @Test("父栏分配剩余高度时，顶栏仍贴合内容而不挤占正文", arguments: [CGFloat(64), 200, 600])
    func finiteParentHeightDoesNotStretchHeader(proposedHeight: CGFloat) throws {
        let size = try measuredSize(InsightsColumnHeader(height: 64) {
            Color.clear.frame(height: 36)
        }, width: 320, height: proposedHeight)
        #expect(size.height == 64)
    }

    @Test("内容超出紧凑高度时自然增高，不缩放或裁切", arguments: [CGFloat(52), 80, 112])
    func tallContentGrows(contentHeight: CGFloat) throws {
        let size = try measuredSize(InsightsColumnHeader(height: 64) {
            Color.clear.frame(height: contentHeight)
        }, width: 260)
        #expect(size.height == contentHeight + 2 * InsightsColumnChrome.headerVerticalPadding)
    }

    @Test("两栏按当前较高内容对齐，也能从较高布局恢复紧凑高度")
    func currentMeasurementsDetermineHeight() throws {
        func sharedHeight(_ measurements: [CGFloat]) -> CGFloat {
            var height = InsightsColumnHeaderHeightPreferenceKey.defaultValue
            for measurement in measurements {
                InsightsColumnHeaderHeightPreferenceKey.reduce(value: &height) { measurement }
            }
            return InsightsColumnChrome.headerHeight(fitting: height)
        }
        #expect(sharedHeight([48, 60]) == 64)
        #expect(sharedHeight([60, 93.2]) == 94)
        #expect(sharedHeight([93.2, 60]) == 94)
        // 不把上一轮 94pt 当输入；宽度恢复后两栏必须能重新收缩。
        #expect(sharedHeight([48, 60]) == 64)
        for height in [CGFloat(64), 94, 120] {
            let leading = try measuredSize(InsightsColumnHeader(height: height) {
                Color.clear.frame(height: 32)
            }, width: 260)
            let trailing = try measuredSize(InsightsColumnHeader(height: height) {
                Color.clear.frame(height: 44)
            }, width: 420)
            #expect(leading.height == trailing.height)
            #expect(leading.height == height)
        }
    }

    /// 使用真实分类译文验证容器；仍不代替主窗口拖拽、分栏和按钮点击的人工验收。
    @Test("18 语言的两行说明在窄宽、大字号和 RTL 下仍由内容撑高",
          arguments: AppLocale.allCases.filter { $0 != .system })
    func localizedContentIsNotHeightClipped(locale: AppLocale) throws {
        for scale in InterfaceScale.allCases {
            for topic in InsightsTopic.allCases {
                for width in [CGFloat(260), 420] {
                    let content = VStack(alignment: .leading, spacing: 2) {
                        Text(topic.titleKey)
                            .font(scale.font(.panelTitle))
                            .lineLimit(1)
                        Text(topic.subtitleKey)
                            .font(scale.font(.caption))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .environment(\.locale, locale.effectiveLocale)
                    let naturalSize = try measuredSize(content.fixedSize(horizontal: false, vertical: true), width: width)
                    let headerSize = try measuredSize(InsightsColumnHeader(height: 64) { content }, width: width)
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
