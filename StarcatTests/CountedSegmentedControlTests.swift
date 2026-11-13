//
//  CountedSegmentedControlTests.swift
//  StarcatTests
//
//  AI 整理计数 Tab 的离屏尺寸契约；不创建窗口或操作用户桌面。
//

import SwiftUI
import Testing
@testable import Starcat

/// 数字更新、选中态和国际化都不能改变同一批次的计数槽位。
@MainActor
@Suite("Counted segmented control layout")
struct CountedSegmentedControlTests {
    private static let boundaryCounts = [0, 1, 9, 10, 99, 100, 999, 1_000, 1_495]
    private static let groupingTabs: [GitHubStarListAIResultFilter] = [.actionable, .suggestions, .applied, .applyFailed, .all]

    /// 只通过 SwiftUI ImageRenderer 测量自然尺寸；固定宽度用来模拟较窄的工具栏。
    private func size<Content: View>(of view: Content, width: CGFloat? = nil) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }

    @Test("计数跨位数与分组符不改变标签宽度", arguments: ["en", "zh-Hans", "de", "fr", "hi-IN"], InterfaceScale.allCases)
    func labelReservesLocalizedTotal(localeID: String, scale: InterfaceScale) throws {
        let locale = Locale(identifier: localeID)
        let baseline = try size(of: CountedSegmentLabel(title: "batchAI.panel.counter.pendingReview", count: 0, totalCount: 1_495)
            .font(scale.font(.body, weight: .medium)).environment(\.locale, locale))
        for count in Self.boundaryCounts {
            let measured = try size(of: CountedSegmentLabel(title: "batchAI.panel.counter.pendingReview", count: count, totalCount: 1_495)
                .font(scale.font(.body, weight: .medium)).environment(\.locale, locale))
            #expect(abs(measured.width - baseline.width) < 0.01)
            #expect(abs(measured.height - baseline.height) < 0.01)
        }
    }

    @Test("仓库整理 Tab 在计数和选中项变化时尺寸不变", arguments: ["en", "zh-Hans", "de"], [ColorScheme.light, .dark])
    func groupingTabsStayStable(localeID: String, colorScheme: ColorScheme) throws {
        let baseline = try controlSize(items: Self.groupingTabs, selected: .actionable, title: { LocalizedStringKey($0.tabTitleKey) },
                                       count: 0, localeID: localeID, colorScheme: colorScheme)
        for selected in Self.groupingTabs {
            for count in Self.boundaryCounts {
                let measured = try controlSize(items: Self.groupingTabs, selected: selected, title: { LocalizedStringKey($0.tabTitleKey) },
                                               count: count, localeID: localeID, colorScheme: colorScheme)
                #expect(abs(measured.width - baseline.width) < 0.01)
                #expect(abs(measured.height - baseline.height) < 0.01)
            }
        }
    }

    @Test("标签整理六个 Tab 使用同一稳定布局", arguments: ["en", "zh-Hans", "de"])
    func tagTabsStayStable(localeID: String) throws {
        let items = BatchAIResultFilter.allCases
        let baseline = try controlSize(items: items, selected: .actionable, title: tagTitle, count: 0, localeID: localeID)
        for selected in items {
            for count in Self.boundaryCounts {
                let measured = try controlSize(items: items, selected: selected, title: tagTitle, count: count, localeID: localeID)
                #expect(abs(measured.width - baseline.width) < 0.01)
                #expect(abs(measured.height - baseline.height) < 0.01)
            }
        }
    }

    @Test("新批次容量与字号变化仍能重新测量")
    func newCapacityAndFontResizeNormally() throws {
        let small = try size(of: CountedSegmentLabel(title: "general.all", count: 0, totalCount: 99).font(.system(size: 13)))
        let large = try size(of: CountedSegmentLabel(title: "general.all", count: 0, totalCount: 1_234_567).font(.system(size: 13)))
        let largerFont = try size(of: CountedSegmentLabel(title: "general.all", count: 0, totalCount: 1_234_567).font(.system(size: 18)))
        #expect(large.width > small.width)
        #expect(largerFont.width > large.width)
    }

    @Test("标准字号保持原有分段控件高度")
    func preservesRegularControlHeight() throws {
        let original = try size(of: Picker("githubStarLists.aiGrouping.filter.label", selection: .constant(GitHubStarListAIResultFilter.actionable)) {
            ForEach(Self.groupingTabs, id: \.self) { filter in
                Text(verbatim: "\(String.l10n(filter.tabTitleKey))  1,495").monospacedDigit().tag(filter)
            }
        }.pickerStyle(.segmented).controlSize(.regular).labelsHidden().fixedSize(horizontal: true, vertical: false))
        let stable = try controlSize(items: Self.groupingTabs, selected: .actionable, title: { LocalizedStringKey($0.tabTitleKey) },
                                     count: 1_495, localeID: "en")
        #expect(stable.height == original.height)
    }

    @Test("窄工具栏允许截断标题，数字更新仍不改变尺寸")
    func constrainedToolbarStaysStable() throws {
        let baseline = try controlSize(items: Self.groupingTabs, selected: .actionable, title: { _ in "A much longer localized state title" },
                                       count: 0, localeID: "de", width: 500)
        let changed = try controlSize(items: Self.groupingTabs, selected: .all, title: { _ in "A much longer localized state title" },
                                      count: 1_000, localeID: "de", width: 500)
        #expect(baseline.width <= 500)
        #expect(changed == baseline)
    }

    @Test("Skill 筛选在窄栏使用图标 Tab，计数与选中项变化不挤占高度",
          arguments: ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR", "it", "ru", "nl", "pl", "uk", "tr", "vi", "id"],
          InterfaceScale.allCases)
    func skillFiltersAdaptWithoutResizing(localeID: String, scale: InterfaceScale) throws {
        let width: CGFloat = 240
        for colorScheme in [ColorScheme.light, .dark] {
            let wide = try size(of: skillControl(
                contentTabs: false, selected: 0, count: 0, localeID: localeID, scale: scale, colorScheme: colorScheme
            ), width: 1_000)
            let compact = try size(of: skillControl(
                contentTabs: false, selected: 0, count: 0, localeID: localeID, scale: scale, colorScheme: colorScheme
            ), width: width)
            #expect(compact.width <= width)
            #expect(compact.width < wide.width)
            #expect(compact.height == wide.height)
            for selected in 0..<3 {
                let updated = try size(of: skillControl(
                    contentTabs: false, selected: selected, count: 1_495,
                    localeID: localeID, scale: scale, colorScheme: colorScheme
                ), width: width)
                #expect(updated == compact)
            }
        }
    }

    @Test("Skill 正文 Tab 支持仅文件显示数量，宽窄模式保持紧凑高度",
          arguments: ["en", "zh-Hans", "de", "ja"], InterfaceScale.allCases)
    func skillContentTabsStayCompact(localeID: String, scale: InterfaceScale) throws {
        let wide = try size(of: skillControl(
            contentTabs: true, selected: 0, count: 1_495, localeID: localeID, scale: scale
        ), width: 1_000)
        let compact = try size(of: skillControl(
            contentTabs: true, selected: 0, count: 1_495, localeID: localeID, scale: scale
        ), width: scale.scaled(180))
        #expect(compact.width <= scale.scaled(180))
        #expect(compact.width < wide.width)
        #expect(compact.height == wide.height)
        #expect(wide.height == scale.scaled(20) + 4)
        for selected in 1..<3 {
            let updated = try size(of: skillControl(
                contentTabs: true, selected: selected, count: 1_495, localeID: localeID, scale: scale
            ), width: scale.scaled(180))
            #expect(updated == compact)
        }
    }

    /// 使用真实界面文案和四位计数验证布局，不创建窗口或触发 Skill 会话、扫描与正文加载。
    private func skillControl(
        contentTabs: Bool, selected: Int, count: Int, localeID: String,
        scale: InterfaceScale, colorScheme: ColorScheme = .light
    ) -> some View {
        let titles: [LocalizedStringKey] = contentTabs
            ? ["SKILL.md", "repo.files.tab.files", "repo.skills.content.tree"]
            : ["repo.skills.list.all", "repo.skills.list.pending", "repo.skills.list.installed"]
        let symbols = contentTabs
            ? ["doc.text", "doc.on.doc", "folder"]
            : ["square.stack.3d.up", "arrow.down.circle", "checkmark.circle"]
        let colors: [Color] = [.blue, .orange, .green]
        return CountedSegmentedControl(
            items: [0, 1, 2], selection: .constant(selected), totalCount: 1_495,
            title: { titles[$0] },
            count: { contentTabs && $0 != 1 ? nil : count },
            accessibilityLabel: "repo.skills.preview.selection",
            symbol: { symbols[$0] },
            tint: { colors[$0] }
        )
        .environment(\.locale, Locale(identifier: localeID))
        .environment(\.starcatInterfaceScale, scale)
        .environment(\.colorScheme, colorScheme)
    }

    /// 两个真实筛选枚举走相同的共享控件，确保没有只修仓库整理而漏掉标签整理。
    private func controlSize<Item: Hashable>(
        items: [Item], selected: Item, title: @escaping (Item) -> LocalizedStringKey,
        count: Int, localeID: String, colorScheme: ColorScheme = .light, width: CGFloat? = nil
    ) throws -> CGSize {
        try size(of: CountedSegmentedControl(
            items: items, selection: .constant(selected), totalCount: 1_495,
            title: title, count: { item in items.last == item ? 1_495 : count },
            accessibilityLabel: "githubStarLists.aiGrouping.filter.label"
        ).environment(\.locale, Locale(identifier: localeID)).environment(\.colorScheme, colorScheme), width: width)
    }

    /// 测试沿用页面已有的本地化短标题，不新增测试专用 Catalog key。
    private func tagTitle(_ filter: BatchAIResultFilter) -> LocalizedStringKey {
        switch filter {
        case .actionable: "githubStarLists.aiGrouping.filter.tab.actionable"
        case .pendingReview: "batchAI.panel.counter.pendingReview"
        case .completed: "batchAI.panel.counter.completed"
        case .failed: "batchAI.panel.counter.failed"
        case .ignored: "batchAI.panel.counter.ignored"
        case .all: "general.all"
        }
    }
}
