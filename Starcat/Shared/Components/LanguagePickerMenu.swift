//
//  LanguagePickerMenu.swift
//  Starcat
//
//  自定义语言下拉选择器（Devicon 图标 + 名称 + 数量），用于替代受
//  macOS NSMenu 限制无法显示彩色 asset image 的 SwiftUI Picker。
//
//  设计约束：
//  - 视觉对齐 SidebarView 的 trendingLanguageRow（SF Symbol 占位 + Devicon + count）。
//  - 「全部」/「未分类」走 i18n key，普通语言用 `LanguageDisplayName.shortened` 短名。
//  - 键盘导航（↑/↓/Enter/Esc）+ hover 高亮 + 当前选中高亮。
//  - 高度自适应：选项 ≤ 8 全展开，超出限高 360pt + 内嵌 ScrollView。
//
//  为什么不复用原生 Picker / Menu：
//  - macOS 上 SwiftUI Picker 走 NSMenu，菜单项**只支持** Text / SF Symbol；
//    asset Image（Devicon SVG）传进 NSMenuItem 会被丢弃 → 「下拉每行有图标」无法实现。
//  - 自定义 popover 完全自由控制 row 视觉 + 行尾 count + 当前选中高亮。
//
//  关键约束（已踩过的坑）：
//  - selected 行不能用纯 accentColor 背景 + 白字：Devicon 是彩色 SVG，蓝底会视觉冲突。
//    改用 `accentColor.opacity(0.18)` 浅色蓝底 + primary 前景 + 行尾 checkmark 标记。
//  - `.onKeyPress` 需要视图被 focus 才会触发 → 给 ScrollView 加 `.focusable()`，
//    同时在 `.onAppear` 把焦点 key 同步到当前 selection，保证打开 popover 时立即可键盘操作。
//

import SwiftUI

/// 自定义语言下拉。视觉/交互替代受限的 `Picker(.menu)`。
///
/// - Parameters:
///   - selection: 当前选中的语言 key（"" 表示全部、`__uncategorized__` 未分类、其他为语言名）。
///   - aggregates: 后端 `/languages` 返回列表（不含「全部」哨兵；本组件内部 prepend）。
///   - labelPrefix: 按钮 label 左侧前缀文案的 i18n key（如 `weekly.filter.language`）。可选。
struct LanguagePickerMenu: View {
    @Binding var selection: String
    let aggregates: [TrendingLanguageAggregateDTO]
    var labelPrefix: LocalizedStringKey?

    @State private var isPresented: Bool = false
    @State private var hoveredKey: String?
    @State private var keyboardFocusedKey: String?

    /// 「全部」哨兵 key（与 ViewModel 约定 `selectedLanguage == ""` 一致）。
    private static let allKey: String = ""

    /// popover 内全部选项（含「全部」哨兵在最前）。
    private var displayedItems: [Item] {
        var items: [Item] = [Item(key: Self.allKey, count: 0)]
        for agg in aggregates {
            items.append(Item(key: agg.key, count: agg.count))
        }
        return items
    }

    private var currentItem: Item {
        displayedItems.first(where: { $0.key == selection }) ?? displayedItems[0]
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            buttonLabel
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
                .appLocaleEnvironment()
        }
    }

    // MARK: - Button label（picker 收起态）

    @ViewBuilder
    private var buttonLabel: some View {
        HStack(spacing: 6) {
            if let labelPrefix {
                Text(labelPrefix)
                    .foregroundStyle(.secondary)
            }
            iconView(for: currentItem.key, size: 14)
                .frame(width: 14, height: 14)
            Text(displayName(for: currentItem.key))
                .lineLimit(1)
            if currentItem.count > 0 {
                Text(currentItem.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Popover content

    @ViewBuilder
    private var popoverContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedItems) { item in
                        row(item)
                            .id(item.key)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            .focusable()
            .onAppear {
                keyboardFocusedKey = selection
                // 打开时把当前选中项滚到中心，避免长列表里看不到当前位置。
                DispatchQueue.main.async {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
            .onKeyPress(.upArrow) {
                moveFocus(by: -1)
                if let k = keyboardFocusedKey { proxy.scrollTo(k, anchor: .center) }
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveFocus(by: 1)
                if let k = keyboardFocusedKey { proxy.scrollTo(k, anchor: .center) }
                return .handled
            }
            .onKeyPress(.return) {
                if let k = keyboardFocusedKey { commit(k) }
                return .handled
            }
            .onKeyPress(.escape) {
                isPresented = false
                return .handled
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let isSelected = item.key == selection
        let isFocused = item.key == keyboardFocusedKey || item.key == hoveredKey

        Button {
            commit(item.key)
        } label: {
            HStack(spacing: 8) {
                iconView(for: item.key, size: 16)
                    .frame(width: 16, height: 16)
                Text(displayName(for: item.key))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.count > 0 {
                    Text(item.count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // 选中标记：accentColor 浅底 + checkmark 双重提示，避免 Devicon 与蓝底视觉冲突。
                Image(systemName: isSelected ? "checkmark" : "")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .frame(width: 10)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground(isSelected: isSelected, isFocused: isFocused))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            if hovering {
                hoveredKey = item.key
                keyboardFocusedKey = item.key
            } else if hoveredKey == item.key {
                hoveredKey = nil
            }
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool, isFocused: Bool) -> some View {
        if isSelected {
            Color.accentColor.opacity(0.18)
        } else if isFocused {
            Color.primary.opacity(0.08)
        } else {
            Color.clear
        }
    }

    // MARK: - Icon / display name 解析（与 SidebarView.trendingLanguageRow 视觉对齐）

    @ViewBuilder
    private func iconView(for key: String, size: CGFloat) -> some View {
        if key == Self.allKey {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.secondary)
        } else if key == TrendingLanguage.uncategorizedKey {
            UncategorizedLanguageIcon(size: size)
        } else {
            LanguageIconView(language: key, size: size)
        }
    }

    private func displayName(for key: String) -> String {
        if key == Self.allKey {
            return String.l10n("weekly.filter.allLanguages")
        }
        if key == TrendingLanguage.uncategorizedKey {
            return String.l10n("trending.language.uncategorized")
        }
        return LanguageDisplayName.shortened(for: key)
    }

    // MARK: - Selection helpers

    private func commit(_ key: String) {
        if selection != key {
            selection = key
        }
        isPresented = false
    }

    private func moveFocus(by delta: Int) {
        let items = displayedItems
        guard !items.isEmpty else { return }
        let currentIdx: Int = {
            if let focusKey = keyboardFocusedKey,
               let idx = items.firstIndex(where: { $0.key == focusKey }) {
                return idx
            }
            return items.firstIndex(where: { $0.key == selection }) ?? 0
        }()
        let newIdx = max(0, min(items.count - 1, currentIdx + delta))
        keyboardFocusedKey = items[newIdx].key
    }

    // MARK: - Item

    private struct Item: Identifiable, Equatable {
        let key: String
        let count: Int
        var id: String { key }
    }
}
