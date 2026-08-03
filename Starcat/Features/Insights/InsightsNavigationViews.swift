//
//  InsightsNavigationViews.swift
//  Starcat
//
//  洞察中心中栏与详情入口。保留 Starcat 的 Sidebar / Content / Detail 三栏职责，
//  不把统计页面做成脱离主窗口的 Web Dashboard。
//

import SwiftUI

/// 中栏与详情栏顶栏尺寸契约：两边分割线必须落在同一水平线。
enum InsightsColumnChrome {
    /// 容纳「标题 + 最多两行副标题」与详情栏右侧分段控件；两侧共用同一高度对齐分割线。
    static let headerHeight: CGFloat = 84
    static let headerVerticalPadding: CGFloat = 12
}

/// 洞察中心中栏：当前主题的摘要和可下钻问题集合。
struct InsightsListView: View {

    @Binding var topic: InsightsTopic
    @Binding var selection: InsightsSelection
    let snapshot: MyInsightsSnapshot

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        // header + Divider 固定在动画区外，避免主题切换时分割线跟着内容漂移、
        // 与右侧「我的洞察」顶栏对不齐。
        VStack(spacing: 0) {
            header
            Divider()

            ZStack(alignment: .topLeading) {
                List(selection: $selection) {
                    Section("insights.list.section.analysis") {
                        ForEach(topic.contentSelections) { item in
                            row(item, count: nil)
                        }
                    }

                    if !attentionSelections.isEmpty {
                        Section("insights.list.section.attention") {
                            ForEach(attentionSelections) { item in
                                row(item, count: count(for: item))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(topic)
                .detailContentTransition()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: topic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(Text("insights.title"))
        .onChange(of: topic) { _, _ in
            restoreValidSelection()
        }
        .onChange(of: snapshot.scope) { _, _ in
            restoreValidSelection()
        }
        .onAppear {
            restoreValidSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.titleKey)
                    .font(interfaceScale.font(.panelTitle))
                    .lineLimit(1)
                Text(topic.subtitleKey)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    // 分类说明允许两行完整展示；顶栏高度与详情栏共用契约，避免分割线错位。
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentTransition(reduceMotion ? .identity : .opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: topic)

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, InsightsColumnChrome.headerVerticalPadding)
        .frame(height: InsightsColumnChrome.headerHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func row(_ item: InsightsSelection, count: Int?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .foregroundStyle(InsightsColor.resolve(item.tintName))
                .frame(width: 18)

            Text(item.titleKey)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let count {
                Text(count.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .tag(item)
    }

    private var attentionSelections: [InsightsSelection] {
        topic.attentionSelections(for: snapshot.scope)
    }

    private func count(for selection: InsightsSelection) -> Int? {
        guard selection != .allActions else { return nil }
        return snapshot.actionItems.first(where: { $0.id == selection })?.count
    }

    private func restoreValidSelection() {
        let allowed = Set(topic.selections(for: snapshot.scope))
        if !allowed.contains(selection) {
            selection = topic.primarySelection
        }
    }
}

/// 领域模型只保存语义色名称，SwiftUI 颜色解析集中在 UI 层，避免跨 actor 模型
/// 依赖不属于业务值的 `Color`。
enum InsightsColor {
    static func resolve(_ name: String) -> Color {
        switch name {
        case "blue":      return .blue
        case "cyan":      return .cyan
        case "green":     return .green
        case "orange":    return .orange
        case "pink":      return .pink
        case "purple":    return .purple
        case "red":       return .red
        case "yellow":    return .yellow
        default:          return .secondary
        }
    }
}
