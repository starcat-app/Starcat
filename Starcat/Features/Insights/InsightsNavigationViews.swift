//
//  InsightsNavigationViews.swift
//  Starcat
//
//  洞察中心中栏与详情入口。保留 Starcat 的 Sidebar / Content / Detail 三栏职责，
//  不把统计页面做成脱离主窗口的 Web Dashboard。
//

import SwiftUI

/// 洞察中心中栏：当前主题的摘要和可下钻问题集合。
struct InsightsListView: View {

    @Binding var topic: InsightsTopic
    @Binding var selection: InsightsSelection
    let snapshot: MyInsightsSnapshot

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

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
                Text(topic.subtitleKey)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
