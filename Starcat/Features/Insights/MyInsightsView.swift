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

    @Binding var topic: InsightsTopic
    @Binding var scope: InsightsScope
    @Binding var selection: InsightsSelection
    let viewModel: MyInsightsViewModel

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings

    private var snapshot: MyInsightsSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                if viewModel.hasInitialError {
                    ContentUnavailableView {
                        Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("action.retry") {
                            refresh()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if viewModel.isInitialLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(spacing: 14) {
                        if viewModel.showsStaleWarning {
                            Label("error.loadFailed", systemImage: "exclamationmark.triangle.fill")
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        selectedContent
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: loadIdentity) {
            await viewModel.load(
                scope: scope,
                embeddingModel: settings.aiEmbeddingModel
            )
        }
    }

    /// 中栏选择和 Detail 内容保持一一对应。原型阶段曾让所有选择都显示同一张总览，
    /// 用户无法判断分类是否真实生效；最终 UI 在这里按业务语义拆开内容。
    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .overviewSummary:
            metricGrid
            organizationSection
            languageSection
            actionSection(snapshot.actionItems)
            coverageSection

        case .allActions:
            actionSection(snapshot.actionItems)

        case .organizationSummary:
            organizationSection
            actionSection(organizationActions)

        case .untagged,
             .unread,
             .missingReadme,
             .missingIndexableContent,
             .indexIssues:
            actionFocusSection
            organizationSection

        case .technologySummary:
            languageSection
            topicSection
            licenseSection

        case .languages:
            languageSection

        case .topics:
            topicSection

        case .licenses:
            licenseSection

        case .healthSummary:
            coverageSection
            actionSection(healthActions)

        case .healthPending,
             .openSSFPending,
             .maintenanceRisk,
             .securityRisk:
            actionFocusSection
            coverageSection
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("insights.my.title")
                    .font(interfaceScale.font(.workspaceTitle))

                HStack(spacing: 5) {
                    Text(selection.titleKey)
                    if viewModel.hasContent {
                        Text("·")
                        Text(snapshot.generatedAt, format: .dateTime.month().day().hour().minute())
                    }
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

            SyncIconButton(
                isRefreshing: viewModel.isRefreshing,
                disabled: viewModel.isInitialLoading || viewModel.isRefreshing,
                tooltip: String.l10n("insights.refresh")
            ) {
                refresh()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var metricGrid: some View {
        LazyVGrid(
            // Detail 变窄时自动从四列回退到两列或单列，不反向抬高主窗口最小宽度。
            columns: [GridItem(.adaptive(minimum: 158), spacing: 10)],
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
        distributionSection(
            title: "insights.section.languages",
            subtitle: "insights.section.languages.subtitle",
            systemImage: "chevron.left.forwardslash.chevron.right",
            items: snapshot.languageItems
        )
    }

    private var topicSection: some View {
        distributionSection(
            title: "insights.section.topics",
            subtitle: "insights.section.topics.subtitle",
            systemImage: "square.grid.2x2.fill",
            items: snapshot.topicItems
        )
    }

    private var licenseSection: some View {
        distributionSection(
            title: "insights.section.licenses",
            subtitle: "insights.section.licenses.subtitle",
            systemImage: "checkmark.seal.fill",
            items: snapshot.licenseItems
        )
    }

    private func distributionSection(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        items: [InsightsDistributionItem]
    ) -> some View {
        InsightsSectionContainer(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        ) {
            Chart(items) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Category", String.l10n(item.title))
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

    private func actionSection(_ items: [InsightsActionItem]) -> some View {
        InsightsSectionContainer(
            title: "insights.section.actions",
            subtitle: scope == .knowledge
                ? "insights.section.actions.knowledgeSubtitle"
                : "insights.section.actions.starredSubtitle",
            systemImage: "checklist"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    actionRow(item)
                }
            }
        }
    }

    private var actionFocusSection: some View {
        Group {
            if let item = selectedAction {
                InsightsSectionContainer(
                    title: LocalizedStringKey(item.titleKey),
                    subtitle: LocalizedStringKey(item.detailKey),
                    systemImage: item.systemImage
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.count.formatted())
                            .font(interfaceScale.font(size: 32, weight: .semibold))
                            .monospacedDigit()

                        Text("insights.action.repositoryCount")
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 12)

                        Label("insights.action.priority", systemImage: "arrow.up.right")
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(InsightsColor.resolve(item.tintName))
                    }

                    Divider()

                    Text("insights.action.detailHint")
                        .font(interfaceScale.font(.body))
                        .foregroundStyle(.secondary)
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
            topic = item.id.topic
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

    private var organizationActions: [InsightsActionItem] {
        let allowed = Set(InsightsTopic.organization.attentionSelections(for: scope))
        return snapshot.actionItems.filter { allowed.contains($0.id) }
    }

    private var healthActions: [InsightsActionItem] {
        let allowed = Set(InsightsTopic.health.attentionSelections(for: scope))
        return snapshot.actionItems.filter { allowed.contains($0.id) }
    }

    private var selectedAction: InsightsActionItem? {
        snapshot.actionItems.first(where: { $0.id == selection })
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

    private var loadIdentity: String {
        [
            scope.rawValue,
            String(dependencies.databaseScopeRevision),
            settings.aiEmbeddingModel
        ].joined(separator: ":")
    }

    private func refresh() {
        Task { @MainActor in
            await viewModel.refresh(
                scope: scope,
                embeddingModel: settings.aiEmbeddingModel
            )
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
