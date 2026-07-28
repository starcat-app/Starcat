//
//  MyInsightsView.swift
//  Starcat
//
//  “我的洞察”详情页。页面保持 macOS 原生高密度分组：KPI 是紧凑指标块，统计内容
//  使用扁平 section 与显式分布条行，不引入 Web Dashboard 式巨型卡片和嵌套卡片。
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
    @Environment(\.starcatReduceMotion) private var reduceMotion
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
                    // 首次加载保留内容区高度；反馈交给右上角 SyncIconButton，
                    // 避免居中转圈或顶栏进度条抢戏。
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .accessibilityHidden(true)
                } else {
                    // 与 RepoDetail / Activity 同款：ZStack + .id + detailContentTransition，
                    // 中栏切换「健康概览 / 安全风险」等时详情轻轻落下，避免瞬切。
                    ZStack(alignment: .topLeading) {
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
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        // 刷新中略降透明度，新快照落地时不那么「硬切」。
                        .opacity(viewModel.isRefreshing ? 0.72 : 1)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.isRefreshing)
                        .id(selection)
                        .detailContentTransition()
                    }
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.4),
                        value: selection
                    )
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

    /// 首次进入与范围切换/手动刷新共用右上角 SyncIconButton 转圈反馈。
    private var isLoadingFeedbackVisible: Bool {
        viewModel.isInitialLoading || viewModel.isRefreshing
    }

    /// 中栏选择和 Detail 内容保持一一对应。原型阶段曾让所有选择都显示同一张总览，
    /// 用户无法判断分类是否真实生效；最终 UI 在这里按业务语义拆开内容。
    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .overviewSummary:
            metricGrid
            rhythmSection
            organizationSection
            knowledgeCoverageSection
            priorityRepositoriesSection
            assetCleanupSection
            languageSection
            actionSection(snapshot.actionItems)
            coverageSection

        case .allActions:
            actionSection(snapshot.actionItems)

        case .organizationSummary:
            organizationSection
            rhythmSection
            knowledgeCoverageSection
            priorityRepositoriesSection
            assetCleanupSection
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
        ViewThatFits(in: .horizontal) {
            // 右侧控件贴标题行顶对齐；默认 center 会相对「标题+副标题」居中，头上留一大块空。
            HStack(alignment: .top, spacing: 12) {
                headerTitle
                Spacer(minLength: 16)
                headerControls
            }
            VStack(alignment: .leading, spacing: 10) {
                headerTitle
                headerControls
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, InsightsColumnChrome.headerVerticalPadding)
        // 与中栏共用固定高度；内容顶对齐，空白留在分割线上方而不是控件头顶。
        .frame(height: InsightsColumnChrome.headerHeight, alignment: .topLeading)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("insights.my.title")
                // 与中栏主题标题同级，避免 workspaceTitle(20) vs panelTitle(17) 把分割线顶歪。
                .font(interfaceScale.font(.panelTitle))
                .lineLimit(1)

            HStack(spacing: 5) {
                Text(selection.titleKey)
                if viewModel.hasContent {
                    Text("·")
                    Text(snapshot.generatedAt, format: .dateTime.month().day().hour().minute())
                }
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(reduceMotion ? .identity : .opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: selection)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 12) {
            // 与 README / 洞察模式切换同款胶囊控件，避免系统 segmented 灰底蓝块。
            PillSegmentedControl(
                items: Array(InsightsScope.allCases),
                selection: $scope,
                title: \.titleKey,
                size: .compact
            )
            .accessibilityLabel(Text("insights.scope.label"))

            SyncIconButton(
                isRefreshing: isLoadingFeedbackVisible,
                disabled: isLoadingFeedbackVisible,
                tooltip: String.l10n("insights.refresh")
            ) {
                refresh()
            }
        }
        // 分段控件比 panelTitle 略高，轻微下移与标题文字视觉对齐。
        .padding(.top, 1)
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringKey(metric.titleKey)))
                .accessibilityValue(Text(verbatim: metricAccessibilityValue(metric)))
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("insights.section.organization"))
                .accessibilityValue(Text(verbatim: distributionAccessibilityValue(snapshot.statusItems)))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 12)],
                    spacing: 8
                ) {
                    ForEach(snapshot.statusItems) { item in
                        Button {
                            guard let status = status(for: item.id) else { return }
                            openDrillDown(.status(status))
                        } label: {
                            distributionLegend(item)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
            }
        }
    }

    private var rhythmSection: some View {
        InsightsSectionContainer(
            title: scope == .starred
                ? "insights.section.starredRhythm"
                : "insights.section.knowledgeRhythm",
            subtitle: "insights.section.rhythm.subtitle",
            systemImage: "chart.bar.fill"
        ) {
            Chart {
                ForEach(Array(snapshot.rhythmPoints.enumerated()), id: \.element.id) { index, point in
                    BarMark(
                        x: .value("Week", rhythmCategory(index)),
                        y: .value("Count", point.count),
                        width: .ratio(0.64)
                    )
                    .foregroundStyle(Color.blue)
                    .cornerRadius(4)
                }
            }
            .chartXAxis {
                AxisMarks(values: rhythmAxisCategories) { value in
                    AxisValueLabel(centered: true) {
                        if let category = value.as(String.self),
                           let index = rhythmIndex(from: category),
                           snapshot.rhythmPoints.indices.contains(index) {
                            Text(
                                snapshot.rhythmPoints[index].weekStart,
                                format: Date.FormatStyle()
                                    .month(.abbreviated)
                                    .day()
                                    .locale(locale)
                            )
                            .font(interfaceScale.font(.captionSmall))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisValueLabel()
                        .font(interfaceScale.font(.captionSmall))
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.12))
                }
            }
            .chartXScale(domain: snapshot.rhythmPoints.indices.map(rhythmCategory))
            .chartYScale(domain: 0...rhythmYAxisUpperBound)
            .frame(height: 164)
            // 与仓库洞察的范围切换一致：数据更新只做短淡入与柱值插值，不推动布局。
            .transition(.opacity)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.35),
                value: snapshot.rhythmPoints
            )
            .accessibilityLabel(
                Text(
                    scope == .starred
                        ? "insights.section.starredRhythm"
                        : "insights.section.knowledgeRhythm"
                )
            )
        }
    }

    private var rhythmAxisCategories: [String] {
        guard !snapshot.rhythmPoints.isEmpty else { return [] }
        let last = snapshot.rhythmPoints.index(before: snapshot.rhythmPoints.endIndex)
        return Array(Set([0, 3, 6, 9, last]))
            .filter(snapshot.rhythmPoints.indices.contains)
            .sorted()
            .map(rhythmCategory)
    }

    private var rhythmYAxisUpperBound: Double {
        let maximum = max(snapshot.rhythmPoints.map(\.count).max() ?? 0, 1)
        return max(1, ceil(Double(maximum) * 1.15))
    }

    private func rhythmCategory(_ index: Int) -> String {
        "week-\(index)"
    }

    private func rhythmIndex(from category: String) -> Int? {
        Int(category.replacingOccurrences(of: "week-", with: ""))
    }

    private var languageSection: some View {
        distributionSection(
            title: "insights.section.languages",
            subtitle: "insights.section.languages.subtitle",
            systemImage: "chevron.left.forwardslash.chevron.right",
            items: snapshot.languageItems,
            onDrillDown: { item in
                guard item.id != "other" else { return }
                openDrillDown(.language(item.id == "__unknown__" ? nil : item.title))
            }
        )
    }

    private var knowledgeCoverageSection: some View {
        InsightsSectionContainer(
            title: scope == .starred
                ? "insights.section.knowledgeDepositCoverage"
                : "insights.section.knowledgeIndexCoverage",
            subtitle: scope == .starred
                ? "insights.section.knowledgeDepositCoverage.subtitle"
                : "insights.section.knowledgeIndexCoverage.subtitle",
            systemImage: "books.vertical.fill"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 24)],
                spacing: 14
            ) {
                ForEach(snapshot.knowledgeCoverageItems) { item in
                    coverageItem(
                        title: LocalizedStringKey(item.title),
                        coverage: InsightsCoverage(
                            completed: item.count,
                            total: insightsProjectCount
                        ),
                        tint: InsightsColor.resolve(item.colorName)
                    )
                }
            }
        }
    }

    private var insightsProjectCount: Int {
        snapshot.metrics.first(where: { $0.id == "projects" })?.value ?? 0
    }

    /// 高 Star 且仍未读或未打标签的仓库优先展示，帮助用户从大批收藏里先处理高价值资产。
    @ViewBuilder
    private var priorityRepositoriesSection: some View {
        if !snapshot.priorityRepositories.isEmpty {
            InsightsSectionContainer(
                title: "insights.section.priorityRepositories",
                subtitle: "insights.section.priorityRepositories.subtitle",
                systemImage: "sparkles"
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.priorityRepositories.enumerated()), id: \.element.id) {
                        index,
                        repository in
                        if index > 0 {
                            Divider().padding(.leading, 30)
                        }
                        priorityRepositoryRow(repository)
                    }
                }
            }
        }
    }

    private var assetCleanupSection: some View {
        InsightsSectionContainer(
            title: "insights.section.assetCleanup",
            subtitle: "insights.section.assetCleanup.subtitle",
            systemImage: "archivebox.fill"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 156), spacing: 16)],
                spacing: 12
            ) {
                assetCleanupItem(
                    title: "insights.asset.dormant",
                    detail: "insights.asset.dormant.detail",
                    count: snapshot.assetSummary.dormantCount,
                    systemImage: "clock.badge.exclamationmark",
                    tint: .orange
                )
                assetCleanupItem(
                    title: "insights.asset.archived",
                    detail: "insights.asset.archived.detail",
                    count: snapshot.assetSummary.archivedCount,
                    systemImage: "archivebox.fill",
                    tint: .purple
                )
                assetCleanupItem(
                    title: "insights.asset.unavailable",
                    detail: "insights.asset.unavailable.detail",
                    count: snapshot.assetSummary.unavailableCount,
                    systemImage: "exclamationmark.icloud.fill",
                    tint: .red
                )
            }
        }
    }

    private func priorityRepositoryRow(_ repository: InsightsRepositoryHighlight) -> some View {
        Button {
            openRepository(repository)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(repository.fullName)
                        .font(interfaceScale.font(.bodyEmphasis))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if repository.isUnread {
                            repositoryStatePill("insights.action.unread", tint: .blue)
                        }
                        if repository.isUntagged {
                            repositoryStatePill("insights.action.untagged", tint: .orange)
                        }
                    }
                }

                Spacer(minLength: 12)

                Label(
                    repository.starsCount.formatted(.number.notation(.compactName).locale(locale)),
                    systemImage: "star.fill"
                )
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
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
    }

    private func repositoryStatePill(_ title: LocalizedStringKey, tint: Color) -> some View {
        Text(title)
            .font(interfaceScale.font(.captionSmall, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func assetCleanupItem(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        count: Int,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(interfaceScale.font(.caption))
                    Spacer(minLength: 6)
                    Text(count.formatted(.number.locale(locale)))
                        .font(interfaceScale.font(.bodyEmphasis))
                        .monospacedDigit()
                }
                Text(detail)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
        items: [InsightsDistributionItem],
        onDrillDown: ((InsightsDistributionItem) -> Void)? = nil
    ) -> some View {
        // 不用 Swift Charts：分类轴 + AxisLabel offset 在 LazyVStack 里会把行高压扁，
        // 标签与柱体重叠。这里用显式 VStack 行高，宽度按本组最大值归一化。
        let maxCount = max(items.map(\.count).max() ?? 1, 1)

        return InsightsSectionContainer(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    distributionBarRow(
                        item,
                        maxCount: maxCount,
                        rowIndex: index,
                        showsDrillDownChevron: onDrillDown != nil && item.id != "other",
                        action: onDrillDown.map { callback in
                            { callback(item) }
                        }
                    )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: distributionAccessibilityValue(items)))
        }
    }

    /// 单行分布条：标签与数值在上、色条在下；色条每次出现从 0 长到目标宽度。
    @ViewBuilder
    private func distributionBarRow(
        _ item: InsightsDistributionItem,
        maxCount: Int,
        rowIndex: Int,
        showsDrillDownChevron: Bool,
        action: (() -> Void)?
    ) -> some View {
        let row = VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(InsightsColor.resolve(item.colorName))
                    .frame(width: 7, height: 7)

                Text(LocalizedStringKey(item.title))
                    .font(interfaceScale.font(.caption))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(item.count.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if showsDrillDownChevron {
                    Image(systemName: "arrow.up.right")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
            }

            InsightsDistributionBarFill(
                fraction: CGFloat(item.count) / CGFloat(maxCount),
                color: InsightsColor.resolve(item.colorName),
                animationDelay: Double(rowIndex) * 0.045
            )
        }
        .contentShape(Rectangle())

        if let action, item.id != "other" {
            Button(action: action) {
                row
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        } else {
            row
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
                        Text(item.count.formatted(.number.locale(locale)))
                            .font(interfaceScale.font(size: 32, weight: .semibold))
                            .monospacedDigit()

                        Text("insights.action.repositoryCount")
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 12)

                        if canDrillDown(.action(item.id)) {
                            Button {
                                openDrillDown(.action(item.id))
                            } label: {
                                Label("insights.drilldown.viewAll", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(InsightsColor.resolve(item.tintName))
                        }
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 24)],
                spacing: 14
            ) {
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
        // 色点贴标题行；默认 center 会落在标题与占比两行中间。
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(InsightsColor.resolve(item.colorName))
                .frame(width: 8, height: 8)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(item.title))
                    .font(interfaceScale.font(.caption))
                Text("\(item.count.formatted(.number.locale(locale))) · \(percent(item.fraction))")
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
            // 行图标与数量贴标题行，避免相对标题+说明整体居中。
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(InsightsColor.resolve(item.tintName))
                    .frame(width: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(item.titleKey))
                        .font(interfaceScale.font(.bodyEmphasis))
                    Text(LocalizedStringKey(item.detailKey))
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(item.count.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(.bodyEmphasis))
                    .monospacedDigit()

                Image(systemName: "chevron.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
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

    private func status(for id: String) -> RepoStatus? {
        switch id {
        case "unread": return .unread
        case "read": return .read
        case "using": return .using
        default: return nil
        }
    }

    private func canDrillDown(_ target: InsightsDrillDownTarget) -> Bool {
        InsightsDrillDownRouter.route(
            scope: scope,
            target: target,
            embeddingModel: settings.aiEmbeddingModel
        ) != nil
    }

    /// 只发布类型化路由；Manage 负责安装临时筛选并展示返回洞察上下文。
    private func openDrillDown(_ target: InsightsDrillDownTarget) {
        guard let route = InsightsDrillDownRouter.route(
            scope: scope,
            target: target,
            embeddingModel: settings.aiEmbeddingModel
        ) else { return }
        dependencies.mainWindowNavigationDispatcher.navigate(
            to: .manage(route.selection),
            temporaryFilters: route.filters,
            returnPage: .insights
        )
    }

    private func openRepository(_ repository: InsightsRepositoryHighlight) {
        guard let link = RepositoryDeepLink(
            fullName: repository.fullName,
            repositoryID: repository.id
        ) else { return }
        dependencies.mainWindowNavigationDispatcher.navigate(
            to: .repository(link),
            returnPage: .insights
        )
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
                    locale: locale,
                    coverage.completed,
                    coverage.total
                )
            )
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(
            Text(
                String(
                    format: String.l10n("insights.coverage.countFormat"),
                    locale: locale,
                    coverage.completed,
                    coverage.total
                )
            )
        )
    }

    private func metricAccessibilityValue(_ metric: InsightsMetric) -> String {
        "\(compact(metric.value)), \(String.l10n(metric.detailKey))"
    }

    private func distributionAccessibilityValue(_ items: [InsightsDistributionItem]) -> String {
        items.map { item in
            "\(String.l10n(item.title)) \(item.count.formatted(.number.locale(locale)))"
        }
        .joined(separator: ", ")
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
struct InsightsSectionContainer<Content: View, HeaderTrailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let headerTrailing: HeaderTrailing
    let content: Content

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 图标只与标题同行居中对齐；副标题缩进到标题文字下方，避免相对「标题+副标题」整块居中。
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)
                    Text(title)
                        .font(interfaceScale.font(.bodyEmphasis))
                    Spacer(minLength: 8)
                    headerTrailing
                }
                Text(subtitle)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
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

extension InsightsSectionContainer where HeaderTrailing == EmptyView {
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}

/// 分布色条从 0 增长到目标占比；分类切换 / 数据更新时重新播放，像进度条填满。
private struct InsightsDistributionBarFill: View {
    let fraction: CGFloat
    let color: Color
    var animationDelay: Double = 0

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(
                proxy.size.width * min(max(progress, 0), 1),
                progress > 0 ? 4 : 0
            )
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: width, height: 6, alignment: .leading)
        }
        .frame(height: 6)
        .onAppear {
            playFillAnimation()
        }
        .onChange(of: fraction) { _, _ in
            playFillAnimation()
        }
    }

    private func playFillAnimation() {
        let target = min(max(fraction, 0), 1)
        if reduceMotion {
            progress = target
            return
        }
        // 先无动画归零，下一帧再播放填充，避免与归零写在同一帧里被合成掉。
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            progress = 0
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.55).delay(animationDelay)) {
                progress = target
            }
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
