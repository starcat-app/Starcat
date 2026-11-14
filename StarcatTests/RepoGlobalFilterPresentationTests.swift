//
//  RepoGlobalFilterPresentationTests.swift
//  StarcatTests
//
//  离屏验证全局筛选的紧凑布局，覆盖长译文、界面字号和多选后尺寸稳定性。
//

import SwiftUI
import Testing
@testable import Starcat

/// 使用实际筛选组件测量布局，不依赖运行中窗口或屏幕尺寸。
@MainActor
@Suite("Global filter compact presentation")
struct RepoGlobalFilterPresentationTests {
    /// 显式给定浮层宽度，让测量过程使用与筛选面板一致的布局提案。
    private func size<Content: View>(of content: Content, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }

    /// 单独渲染共享 Tab，避免 Skill 扫描服务影响布局测量。
    private func tabs(selection: RepoSkillFilter) -> some View {
        RepoFilterTabs(
            label: "repo.skills.filter.title",
            options: RepoSkillFilter.allCases,
            selection: .constant(selection),
            title: { LocalizedStringKey("repo.skills.filter." + $0.rawValue) },
            shortTitle: { LocalizedStringKey("repo.skills.filter.short." + $0.rawValue) },
            symbol: { _ in "circle" }
        )
    }

    @Test(
        "全部语言和四档字号下保持单行，切换选中项不改变尺寸",
        arguments: AppLocale.allCases.filter { $0 != .system }, InterfaceScale.allCases
    )
    func tabsStayCompact(locale: AppLocale, scale: InterfaceScale) throws {
        for width in [CGFloat(140), CGFloat(236)] {
            let normal = try size(of: tabs(selection: .any)
                .environment(\.locale, Locale(identifier: locale.rawValue))
                .environment(\.starcatInterfaceScale, scale), width: width)
            let selected = try size(of: tabs(selection: .unknown)
                .environment(\.locale, Locale(identifier: locale.rawValue))
                .environment(\.starcatInterfaceScale, scale), width: width)
            #expect(normal.width <= width)
            #expect(normal.height >= 24 && normal.height <= 32)
            #expect(selected == normal)
        }
    }

    @Test("多个语言共用一行，比逐项排列更紧凑", arguments: [140.0, 236.0])
    func languageChipsShareRows(width: Double) throws {
        let languages = ["C#", "Go", "Java", "JavaScript", "Ruby", "Shell", "Swift"]
        let single = try size(of: RepoLanguageFilterChip(
            title: "Go", isSelected: false, action: {}
        ) {
            Image(systemName: "globe")
        }, width: width)
        let pair = try size(of: TagChipFlowLayout(spacing: 6, constrainsItemWidth: true) {
            ForEach(["C#", "Go"], id: \.self) { language in
                RepoLanguageFilterChip(title: language, isSelected: false, action: {}) {
                    Image(systemName: "globe")
                }
            }
        }, width: width)
        let all = try size(of: TagChipFlowLayout(spacing: 6, constrainsItemWidth: true) {
            ForEach(languages, id: \.self) { language in
                RepoLanguageFilterChip(title: language, isSelected: false, action: {}) {
                    Image(systemName: "globe")
                }
            }
        }, width: width)
        #expect(pair.height == single.height)
        #expect(all.height < single.height * CGFloat(languages.count))
    }

    @Test("长语言名保持单行，选中不会改变胶囊尺寸", arguments: [140.0, 236.0])
    func longLanguageNameFits(width: Double) throws {
        let title = String(repeating: "Long Language Name ", count: 12)
        let normal = try size(of: RepoLanguageFilterChip(
            title: title, isSelected: false, action: {}
        ) {
            Image(systemName: "globe")
        }, width: width)
        let selected = try size(of: RepoLanguageFilterChip(
            title: title, isSelected: true, action: {}
        ) {
            Image(systemName: "globe")
        }, width: width)
        let singleLine = try size(of: RepoLanguageFilterChip(
            title: "Swift", isSelected: false, action: {}
        ) {
            Image(systemName: "globe")
        }, width: width)
        #expect(normal.width <= width)
        #expect(normal.height == singleLine.height)
        #expect(selected == normal)
    }
}
