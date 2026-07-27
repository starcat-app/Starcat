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

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List(selection: $selection) {
                Section {
                    row(.summary, count: nil)
                    ForEach(visibleActions) { item in
                        row(item.id, count: item.count)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(Text("insights.title"))
        .onChange(of: topic) { _, _ in
            let allowed = Set([InsightsSelection.summary] + visibleActions.map(\.id))
            if !allowed.contains(selection) {
                selection = .summary
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(topic.titleKey)
                    .font(interfaceScale.font(.panelTitle))
                Text("insights.list.subtitle")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            MockDataBadge()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func row(_ item: InsightsSelection, count: Int?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage(for: item))
                .foregroundStyle(tint(for: item))
                .frame(width: 18)

            Text(item.titleKey)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let count {
                Text(count.formatted())
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .tag(item)
    }

    private var visibleActions: [InsightsActionItem] {
        switch topic {
        case .overview:
            return snapshot.actionItems
        case .organization:
            return snapshot.actionItems.filter { $0.id == .untagged || $0.id == .unread }
        case .technology:
            return snapshot.actionItems.filter { $0.id == .indexIssues }
        case .health:
            return snapshot.actionItems.filter { $0.id == .healthPending }
        }
    }

    private func systemImage(for selection: InsightsSelection) -> String {
        if selection == .summary { return topic.systemImage }
        return snapshot.actionItems.first(where: { $0.id == selection })?.systemImage ?? "circle"
    }

    private func tint(for selection: InsightsSelection) -> Color {
        if selection == .summary { return .accentColor }
        return InsightsColor.resolve(
            snapshot.actionItems.first(where: { $0.id == selection })?.tintName ?? "secondary"
        )
    }
}

/// 演示数据必须在界面上可见，避免用户把原型数值误认为真实账户统计。
struct MockDataBadge: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Label("insights.mock.badge", systemImage: "testtube.2")
            .font(interfaceScale.font(.captionSmall, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

/// Mock 模型只保存语义色名称，SwiftUI 颜色解析集中在 UI 层，后续跨 actor 数据模型
/// 不需要依赖 `Color`（它不是 Sendable 的业务值）。
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
