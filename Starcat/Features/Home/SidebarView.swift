//
//  SidebarView.swift
//  Starcat
//
//  左栏：侧边栏。
//
//  Week 3 三个分组：
//  - 主：All Stars / Untagged
//  - Languages：按语言聚合，每项带计数
//
//  设计约束：
//  - 不直接做查询，数据来自 HomeViewModel
//  - 用 NavigationSplitView 的 selection binding 与 ViewModel 联动
//  - Languages 行点击 → 设置 selection 为 .language(lang)
//

import SwiftUI

struct SidebarView: View {

    @Environment(HomeViewModel.self) private var viewModel

    /// 当前打开/收起 Languages 组的状态。
    @State private var languagesExpanded: Bool = true

    var body: some View {
        @Bindable var vm = viewModel

        List(selection: $vm.selection) {
            Section("主导航") {
                row(.allStars, count: viewModel.totalCount)
                row(.untagged, count: viewModel.untaggedCount)
            }

            if !viewModel.languageStats.isEmpty {
                Section(isExpanded: $languagesExpanded) {
                    ForEach(viewModel.languageStats) { stat in
                        row(.language(stat.languageOrNil),
                            displayOverride: stat.displayName,
                            count: stat.count)
                    }
                } header: {
                    Text("Languages")
                }
            }
        }
        .listStyle(.sidebar)
        // 用 safeAreaInset 把用户卡固定在 Sidebar 顶部，下面的 List 内容仍可滚动
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarHeaderView()
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem,
                     displayOverride: String? = nil,
                     count: Int? = nil) -> some View {
        Label {
            HStack {
                Text(displayOverride ?? item.displayName)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text(count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
        }
        .tag(item)
    }
}
