//
//  UnifiedFilterMenu.swift
//  Starcat
//
//  顶部 toolbar 通用筛选下拉菜单。
//
//  存在意义（W12 toolbar 专项 PR-1）：
//  - Manage 的筛选项是 hideArchived / hideForks / statusFilter，Weekly 的筛选项是
//    language picker，Trending 不接入。**字段差异太大不强行合并 model**，但 UI
//    形态完全可以统一：「漏斗图标 + Picker + Toggle 混合的筛选浮层」。
//  - 把 UI 容器抽出来，每个 page 自己组装 `FilterMenuItem` 数组传进来。
//
//  关键约束：
//  - `FilterMenuItem` 用 enum case 而非协议：让调用方一眼看清能用哪些控件类型
//    （toggle / content / divider）。
//  - `.content` case 接受 `AnyView`：picker 的 selection / 标签 / .tag 由调用方
//    完整持有，避免本组件帮 caller 写半截 binding（之前的 picker case 尝试这样
//    做反而把代码弄复杂）。
//  - icon 激活态由调用方传入 `isAnyFilterActive` 决定，组件不再扫描 items 自己算，
//    避免「toggle 是否激活」与「picker 选了什么算激活」的判定逻辑分散到本组件。
//

import SwiftUI

/// 单个筛选项的声明式描述。
///
/// 调用方按页面需要组装数组传入；菜单按数组顺序原样渲染（含分隔符）。
enum FilterMenuItem: Identifiable {

    /// 二态开关项（如 hideArchived / hideForks）。
    case toggle(id: String, label: LocalizedStringKey, icon: String, isOn: Binding<Bool>)

    /// 任意自定义视图插槽（典型用法：内嵌 Picker）。
    /// AnyView 内部要自己持 binding + 写 .tag，本组件不参与。
    case content(id: String, view: AnyView)

    /// 分隔符。
    case divider(id: String)

    var id: String {
        switch self {
        case .toggle(let id, _, _, _): return "toggle-\(id)"
        case .content(let id, _):      return "content-\(id)"
        case .divider(let id):         return "divider-\(id)"
        }
    }
}

/// 通用筛选菜单。toolbar primaryAction 槽内调用。
///
/// `isAnyFilterActive` 决定漏斗图标的"激活态"渲染（实心 vs 空心）。
struct UnifiedFilterMenu: View {

    @Environment(\.colorScheme) private var colorScheme

    @State private var isPresented = false

    let items: [FilterMenuItem]
    let isAnyFilterActive: Bool
    let accessibilityLabel: LocalizedStringKey
    let helpKey: LocalizedStringKey
    /// 可选的"重置筛选"回调；非 nil 且 `isAnyFilterActive == true` 时在菜单底部显示。
    var onReset: (() -> Void)?

    init(
        items: [FilterMenuItem],
        isAnyFilterActive: Bool,
        accessibilityLabel: LocalizedStringKey = "list.filter.status",
        helpKey: LocalizedStringKey = "list.filter.hint",
        onReset: (() -> Void)? = nil
    ) {
        self.items = items
        self.isAnyFilterActive = isAnyFilterActive
        self.accessibilityLabel = accessibilityLabel
        self.helpKey = helpKey
        self.onReset = onReset
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            filterIcon
        }
        .focusEffectDisabled()
        .help(isAnyFilterActive ? Text("list.filter.active") : Text(helpKey))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        switch item {
                        case .toggle(_, let label, let icon, let isOn):
                            Toggle(isOn: isOn) {
                                Label(label, systemImage: icon)
                            }

                        case .content(_, let view):
                            view

                        case .divider:
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)

                if let onReset, isAnyFilterActive {
                    Divider()
                        .padding(.horizontal, 12)

                    Button(role: .destructive) {
                        isPresented = false
                        onReset()
                    } label: {
                        Label("list.filter.reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .frame(width: 260, alignment: .leading)
            .appLocaleEnvironment()
        }
    }

    /// 筛选激活态必须足够明显：仅把 symbol 从空心换成实心，在透明 toolbar 上不容易被注意到。
    /// 这里只通过颜色与底色表达 active，不加数字 / 文案，避免 toolbar 信息过载。
    private var filterIcon: some View {
        ToolbarIcon(isAnyFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            .foregroundStyle(isAnyFilterActive ? activeIconColor : Color.primary)
            .accessibilityLabel(accessibilityLabel)
        .frame(width: ToolbarIconMetrics.frameSize, height: ToolbarIconMetrics.frameSize)
        .background {
            if isAnyFilterActive {
                Circle()
                    .fill(activeBackgroundColor)
            }
        }
        .overlay {
            if isAnyFilterActive {
                Circle()
                    .stroke(activeBorderColor, lineWidth: 1)
            }
        }
    }

    private var activeIconColor: Color {
        colorScheme == .dark ? Color.accentColor.opacity(0.95) : Color.accentColor
    }

    private var activeBackgroundColor: Color {
        colorScheme == .dark ? Color.accentColor.opacity(0.24) : Color.accentColor.opacity(0.18)
    }

    private var activeBorderColor: Color {
        colorScheme == .dark ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.45)
    }
}
