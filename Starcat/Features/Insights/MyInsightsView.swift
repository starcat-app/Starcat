//
//  MyInsightsView.swift
//  Starcat
//
//  “我的洞察”详情页。页面保持 macOS 原生高密度分组：KPI 是紧凑指标块，统计内容
//  使用扁平 section 与 Charts，不引入 Web Dashboard 式巨型卡片和嵌套卡片。
//

import Charts
import SwiftUI

struct MyInsightsView: View {

    @Binding var scope: InsightsScope
    @Binding var selection: InsightsSelection
    let snapshot: MyInsightsSnapshot

    @State private var isRefreshing = false

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 14) {
                    metricGrid
                    organizationSection
                    languageSection
                    actionSection
                    coverageSection
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("insights.my.title")
                        .font(interfaceScale.font(.workspaceTitle))
                    MockDataBadge()
                }

                HStack(spacing: 5) {
                    Text(selection.titleKey)
                    Text("·")
                    Text(snapshot.generatedAt, format: .dateTime.month().day().hour().minute())
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Picker("insights.scope.label", selection: $scope) {
                Text("insights.scope.starred").tag(InsightsScope.starred)
                Text("insights.scope.knowledge").tag(InsightsScope.knowledge)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)

            // 前端阶段只重放同一份确定性 Mock；保留真实刷新控件和最短反馈时长，
            // 便于提前验收交互，但不伪装成数据库或网络刷新。
            SyncIconButton(
                isRefreshing: isRefreshing,
                disabled: isRefreshing,
                tooltip: String.l10n("insights.refresh")
            ) {
                refreshMockPreview()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10
        ) {
            ForEach(snapshot.metrics) { metric in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(LocalizedStringKey(metric.titleKey))
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Image(systemName: metric.systemImage)
                            .foregroundStyle(InsightsColor.resolve(metric.tintName))
                    }

                    Text(compact(metric.value))
                        .font(interfaceScale.font(size: 24, weight: .semibold))
                        .monospacedDigit()

                    Text(LocalizedStringKey(metric.detailKey))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                }
            }
        }
    }

    private var organizationSection: some View {
        InsightsSectionContainer(
            title: "insights.section.organization",
            subtitle: "insights.section.organization.subtitle",
            systemImage: "tray.full.fill"
        ) {
            VStack(spacing: 12) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(snapshot.statusItems) { item in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(InsightsColor.resolve(item.colorName))
                                .frame(width: max(proxy.size.width * item.fraction - 2, 2))
                        }
                    }
                }
                .frame(height: 10)
                .accessibilityLabel(Text("insights.section.organization"))

                HStack(spacing: 18) {
                    ForEach(snapshot.statusItems) { item in
                        distributionLegend(item)
                    }
                }
            }
        }
    }

    private var languageSection: some View {
        InsightsSectionContainer(
            title: "insights.section.languages",
            subtitle: "insights.section.languages.subtitle",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ) {
            Chart(snapshot.languageItems) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Language", item.title)
                )
                .foregroundStyle(InsightsColor.resolve(item.colorName))
                .cornerRadius(3)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(item.count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let language = value.as(String.self) {
                            Text(LocalizedStringKey(language))
                                .font(interfaceScale.font(.caption))
                        }
                    }
                }
            }
            .frame(height: 176)
        }
    }

    private var actionSection: some View {
        InsightsSectionContainer(
            title: "insights.section.actions",
            subtitle: scope == .knowledge
                ? "insights.section.actions.knowledgeSubtitle"
                : "insights.section.actions.starredSubtitle",
            systemImage: "checklist"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.actionItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    actionRow(item)
                }
            }
        }
    }

    private var coverageSection: some View {
        InsightsSectionContainer(
            title: "insights.section.coverage",
            subtitle: "insights.section.coverage.subtitle",
            systemImage: "heart.text.square.fill"
        ) {
            HStack(spacing: 24) {
                coverageItem(
                    title: "insights.coverage.health",
                    coverage: snapshot.healthCoverage,
                    tint: .green
                )
                coverageItem(
                    title: "insights.coverage.openssf",
                    coverage: snapshot.openSSFCoverage,
                    tint: .blue
                )
            }
        }
    }

    private func distributionLegend(_ item: InsightsDistributionItem) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(InsightsColor.resolve(item.colorName))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(item.title))
                    .font(interfaceScale.font(.caption))
                Text("\(item.count.formatted()) · \(percent(item.fraction))")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(_ item: InsightsActionItem) -> some View {
        Button {
            selection = item.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(InsightsColor.resolve(item.tintName))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(item.titleKey))
                        .font(interfaceScale.font(.bodyEmphasis))
                    Text(LocalizedStringKey(item.detailKey))
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(item.count.formatted())
                    .font(interfaceScale.font(.bodyEmphasis))
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .listRowSelectionTint(isSelected: selection == item.id)
    }

    private func coverageItem(
        title: LocalizedStringKey,
        coverage: InsightsCoverage,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(interfaceScale.font(.bodyEmphasis))
                Spacer()
                Text(percent(coverage.fraction))
                    .font(interfaceScale.font(.bodyEmphasis))
                    .monospacedDigit()
            }

            ProgressView(value: coverage.fraction)
                .tint(tint)

            Text(
                String(
                    format: String.l10n("insights.coverage.countFormat"),
                    coverage.completed,
                    coverage.total
                )
            )
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(locale))
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    private func refreshMockPreview() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            isRefreshing = false
        }
    }
}

/// 洞察页面的唯一分组表面：薄描边 + 系统 control background，避免区块各自发展成
/// 多层嵌套卡片。仓库洞察继续复用它以保持两种洞察的密度一致。
struct InsightsSectionContainer<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let content: Content

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(interfaceScale.font(.bodyEmphasis))
                    Text(subtitle)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

private extension View {
    /// 选中动作只给轻量 accent 底色，保持它仍是内容行而不是第二层卡片。
    func listRowSelectionTint(isSelected: Bool) -> some View {
        padding(.horizontal, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}
