//
//  MyInsightsView.swift
//  Starcat
//
//  “我的洞察”详情页。页面保持 macOS 原生高密度分组：KPI 是紧凑指标块，统计内容
//  使用扁平 section 与显式分布条行，不引入 Web Dashboard 式巨型卡片和嵌套卡片。
//
//  层级约定（仅本页）：window 灰底 → KPI 浅色 tint 块 → emphasized section 面板；
//  section 标题图标按主题着色。仓库洞察继续走 InsightsSectionContainer 默认 standard。
//
//  KPI 卡右下角可叠一层极淡示意柱/折线：由 metric id + value 稳定生成，只做视觉层次，
//  **不是**真实时间序列，禁止据此解读趋势。
//

import Charts
import SwiftUI

struct MyInsightsView: View {

    let topic: InsightsTopic
    @Binding var scope: InsightsScope
    let viewModel: MyInsightsViewModel
    let openProfileRepository: (RepositoryDeepLink) -> Void

    /// 刷新同一画像也要重新读取，但计数器不参与画像内容本身的身份。
    private struct ProfileLoad: Equatable {
        let request: InsightsProfileRequest
        let refresh: Int
    }

    @State private var profileLoader = InsightsProfileLoader()
    @State private var profileRefresh = 0
    @State private var profileDay = Date()
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings

    private var request: MyInsightsViewModel.Request {
        .init(
            scope: scope,
            accountID: dependencies.database.currentUserId,
            databaseRevision: dependencies.databaseScopeRevision,
            embeddingModel: settings.aiEmbeddingModel
        )
    }

    private var snapshot: MyInsightsSnapshot? {
        viewModel.snapshot(for: request)
    }

    private var statisticsState: MyInsightsLoadState {
        viewModel.state(for: request)
    }

    private var profileLoad: ProfileLoad? {
        guard topic == .knowledgeProfile, let profileRequest else { return nil }
        return ProfileLoad(request: profileRequest, refresh: profileRefresh)
    }

    /// 与洞察内容的指标卡、图表和行动行保持相同节奏；刷新快照仍沿用已显示的内容。
    private var insightsSkeleton: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(topic.dashboardSections(for: scope).prefix(3), id: \.self) { section in
                    if section == .metrics {
                        HStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 12) {
                                    SkeletonBlock(maxWidth: 64, height: 12, phase: phase, palette: palette)
                                    SkeletonBlock(maxWidth: 50, height: 26, phase: phase, palette: palette)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            SkeletonBlock(maxWidth: 144, height: 14, phase: phase, palette: palette)
                            switch section {
                            case .rhythm:
                                SkeletonBlock(height: 158, cornerRadius: 6, phase: phase, palette: palette)
                            case .healthCoverage:
                                HStack(spacing: 24) {
                                    SkeletonBlock(height: 44, phase: phase, palette: palette)
                                    SkeletonBlock(height: 44, phase: phase, palette: palette)
                                }
                            case .action:
                                HStack {
                                    SkeletonBlock(width: 62, height: 30, phase: phase, palette: palette)
                                    Spacer()
                                    SkeletonBlock(width: 92, height: 24, phase: phase, palette: palette)
                                }
                            default:
                                ForEach(0..<3, id: \.self) { _ in
                                    HStack(spacing: 12) {
                                        SkeletonBlock(width: 22, height: 22, phase: phase, palette: palette)
                                        SkeletonBlock(height: 14, phase: phase, palette: palette)
                                        SkeletonBlock(width: 40, height: 14, phase: phase, palette: palette)
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var body: some View {
        let statisticsRequest = topic == .knowledgeProfile ? nil : request
        let profileLoad = self.profileLoad

        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                Group {
                    if topic == .knowledgeProfile {
                        knowledgeProfile
                    } else {
                        statisticsPage
                            .id(request)
                    }
                }
                .frame(maxWidth: 1120, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, InsightsColumnChrome.contentTopPadding)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .nativeDetailTransition(value: topic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in profileDay = Date() }
        .onAppear { profileDay = Date() }
        // 只替换展示子树，加载任务挂在稳定宿主。四个统计页切换时沿用当前查询。
        .task(id: statisticsRequest) {
            guard let statisticsRequest else { return }
            await viewModel.load(statisticsRequest)
        }
        .task(id: profileLoad) {
            guard !Task.isCancelled, let profileLoad else { return }
            await profileLoader.load(profileLoad.request) { try await $0.load(database: dependencies.database) }
        }
    }

    private var statisticsPage: some View {
        Group {
            if let snapshot {
                LazyVStack(spacing: 16) {
                    if statisticsState == .stale {
                        Label("error.loadFailed", systemImage: "exclamationmark.triangle.fill")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    MyInsightsDashboard(
                        topic: topic,
                        snapshot: snapshot,
                        embeddingModel: request.embeddingModel
                    )
                }
                .transition(.opacity)
            } else if statisticsState == .failed {
                ContentUnavailableView {
                    Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("action.retry", action: refresh)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                insightsSkeleton.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: snapshot != nil)
    }

    /// 首次进入与范围切换/手动刷新共用右上角 SyncIconButton 转圈反馈。
    private var isLoadingFeedbackVisible: Bool {
        if topic == .knowledgeProfile {
            guard let profileRequest else { return false }
            return profileLoader.loading == profileRequest
                || (profileLoader.displayed(for: profileRequest) == nil && profileLoader.failed != profileRequest)
        }
        return statisticsState == .idle || statisticsState == .loading || statisticsState == .refreshing
    }

    private var profileRequest: InsightsProfileRequest? {
        dependencies.database.currentUserId.map {
            InsightsProfileRequest(accountID: $0, scope: scope, day: profileDay, timeZone: timeZone,
                                   databaseRevision: dependencies.databaseScopeRevision)
        }
    }

    /// 画像有独立的首次加载与失败状态，切号或换范围时先撤下旧数据及其明细窗口。
    @ViewBuilder
    private var knowledgeProfile: some View {
        if let request = profileRequest {
            VStack(alignment: .leading, spacing: 12) {
                if let profile = profileLoader.displayed(for: request) {
                    if profileLoader.failed == request {
                        Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    InsightsKnowledgeProfileView(profile: profile, openRepository: openProfileRepository)
                } else if profileLoader.failed == request {
                    ContentUnavailableView {
                        Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("action.retry", action: refresh)
                    }
                } else {
                    InsightsKnowledgeProfileSkeleton()
                }
            }
            .stableDetailTransition(value: profileLoader.displayed(for: request) != nil)
            .id(request)
        } else {
            ContentUnavailableView("menubar.status.notSignedIn", systemImage: "person.crop.circle")
        }
    }

    private var header: some View {
        InsightsColumnHeader {
            headerTitle
        } controls: {
            headerControls
        }
        // 页头覆盖中右栏的系统工具栏，空白处沿用每日热点的原生窗口拖动。
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(topic.titleKey)
                .font(interfaceScale.font(.panelTitle))
                .accessibilityAddTraits(.isHeader)

            Group {
                if let displayedAt {
                    Text(displayedAt, format: .dateTime.month().day().hour().minute())
                } else {
                    Text(topic.subtitleKey)
                        .lineLimit(2)
                }
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .contentTransition(reduceMotion ? .identity : .opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: topic)
        }
    }

    private var displayedAt: Date? {
        if topic == .knowledgeProfile { return profileLoader.displayed(for: profileRequest)?.facts.classifiedAt }
        return snapshot?.generatedAt
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
                disabled: isLoadingFeedbackVisible || (topic == .knowledgeProfile && profileRequest == nil),
                tooltip: String.l10n("insights.refresh")
            ) {
                refresh()
            }

            if topic == .technology, let snapshot {
                GrowthShareCopyButton {
                    technologyShareText(
                        Array(snapshot.languageItems.prefix(3))
                        + Array(snapshot.topicItems.prefix(3))
                        + Array(snapshot.licenseItems.prefix(3))
                    )
                }
            }
        }
        // 分段控件比 panelTitle 略高，轻微下移与标题文字视觉对齐。
        .padding(.top, 1)
    }

    private func refresh() {
        if topic == .knowledgeProfile {
            profileDay = Date()
            profileRefresh += 1
        } else {
            let refreshRequest = request
            Task { await viewModel.refresh(refreshRequest) }
        }
    }
}

/// 按左栏入口组合统计区块。展示和下钻共用已校验身份的快照及模型。
private struct MyInsightsDashboard: View {
    let topic: InsightsTopic
    let snapshot: MyInsightsSnapshot
    let embeddingModel: String

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppDependencies.self) private var dependencies

    private var scope: InsightsScope { snapshot.scope }

    var body: some View {
        ForEach(topic.dashboardSections(for: scope), id: \.self) { section in
            sectionContent(section)
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: InsightsDashboardSection) -> some View {
        switch section {
        case .metrics:
            metricGrid
        case .rhythm:
            rhythmSection
        case .organizationProgress:
            organizationSection
        case .knowledgeCoverage:
            knowledgeCoverageSection
        case .priorityRepositories:
            priorityRepositoriesSection
        case .assetCleanup:
            assetCleanupSection
        case .languages:
            languageSection
        case .topics:
            topicSection
        case .licenses:
            licenseSection
        case .allActions:
            allActionsSection
        case .healthCoverage:
            coverageSection
        case .action(let id):
            if let item = snapshot.actionItems.first(where: { $0.id == id }) {
                actionDetailSection(item)
            }
        }
    }

    private var metricGrid: some View {
        // 固定 4 项 KPI：等分铺满整行。adaptive 网格在宽屏会多开空列，卡片挤左侧且 detail 易折行。
        HStack(alignment: .top, spacing: 10) {
            ForEach(snapshot.metrics) { metric in
                let tint = InsightsColor.resolve(metric.tintName)
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(LocalizedStringKey(metric.titleKey))
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 6)
                        Image(systemName: metric.systemImage)
                            .foregroundStyle(tint)
                    }

                    Text(compact(metric.value))
                        .font(interfaceScale.font(size: 24, weight: .semibold))
                        .monospacedDigit()

                    Text(LocalizedStringKey(metric.detailKey))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                .background {
                    ZStack(alignment: .bottomTrailing) {
                        shape.fill(tint.opacity(0.08))
                        // 示意装饰图固定落在右下角「口袋」；非真实历史数据。
                        InsightsMetricMotifCorner(
                            metricID: metric.id,
                            value: metric.value,
                            tint: tint
                        )
                    }
                    .clipShape(shape)
                }
                .overlay {
                    shape.stroke(tint.opacity(0.22), lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringKey(metric.titleKey)))
                .accessibilityValue(Text(verbatim: metricAccessibilityValue(metric)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var organizationSection: some View {
        InsightsSectionContainer(
            title: "insights.section.organization",
            subtitle: "insights.section.organization.subtitle",
            systemImage: "tray.full.fill",
            iconColor: .orange,
            chrome: .emphasized
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
            systemImage: "chart.bar.fill",
            iconColor: .blue,
            chrome: .emphasized
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
            iconSource: .business(.languages),
            iconColor: .purple,
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
            systemImage: "books.vertical.fill",
            iconColor: .indigo,
            chrome: .emphasized
        ) {
            // 固定 3 项：用等分 HStack 铺满卡片宽度。
            // adaptive 网格在宽屏会多开空列，导致「Saved to Knowledge Base」等长文案折行，右侧却留白。
            // HStack 自身也要 maxWidth infinity：容器是 leading 对齐，否则只会 hug 内容挤在左侧。
            HStack(alignment: .top, spacing: 24) {
                ForEach(snapshot.knowledgeCoverageItems) { item in
                    coverageItem(
                        title: LocalizedStringKey(item.title),
                        coverage: InsightsCoverage(
                            completed: item.count,
                            total: insightsProjectCount
                        ),
                        tint: InsightsColor.resolve(item.colorName)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                systemImage: "sparkles",
                iconColor: .yellow,
                chrome: .emphasized
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.priorityRepositories.enumerated()), id: \.element.id) {
                        index,
                        repository in
                        if index > 0 {
                            Divider().padding(.leading, 30)
                        }
                        priorityRepositoryRow(repository)
                            .listRowSurface(index: index)
                    }
                }
            }
        }
    }

    private var assetCleanupSection: some View {
        InsightsSectionContainer(
            title: "insights.section.assetCleanup",
            subtitle: "insights.section.assetCleanup.subtitle",
            systemImage: "archivebox.fill",
            iconColor: .cyan,
            chrome: .emphasized
        ) {
            // 固定三项等分铺满，与顶部 KPI 同款卡片语汇；不用 adaptive，避免宽屏挤左、窄列折坏说明。
            HStack(alignment: .top, spacing: 10) {
                assetCleanupItem(
                    title: "insights.asset.dormant",
                    detail: "insights.asset.dormant.detail",
                    count: snapshot.assetSummary.dormantCount,
                    systemImage: "clock.badge.exclamationmark",
                    tint: .orange,
                    motifID: "dormant"
                )
                assetCleanupItem(
                    title: "insights.asset.archived",
                    detail: "insights.asset.archived.detail",
                    count: snapshot.assetSummary.archivedCount,
                    systemImage: "archivebox.fill",
                    tint: .purple,
                    motifID: "archived"
                )
                assetCleanupItem(
                    title: "insights.asset.unavailable",
                    detail: "insights.asset.unavailable.detail",
                    count: snapshot.assetSummary.unavailableCount,
                    systemImage: "exclamationmark.icloud.fill",
                    tint: .red,
                    motifID: "unavailable"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        tint: Color,
        motifID: String
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(title)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }

            Text(count.formatted(.number.locale(locale)))
                .font(interfaceScale.font(size: 24, weight: .semibold))
                .monospacedDigit()

            Text(detail)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background {
            ZStack(alignment: .bottomTrailing) {
                shape.fill(tint.opacity(0.08))
                InsightsMetricMotifCorner(
                    metricID: motifID,
                    value: count,
                    tint: tint
                )
            }
            .clipShape(shape)
        }
        .overlay {
            shape.stroke(tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var topicSection: some View {
        distributionSection(
            title: "insights.section.topics",
            subtitle: "insights.section.topics.subtitle",
            iconSource: .system("square.grid.2x2.fill"),
            iconColor: .purple,
            items: snapshot.topicItems
        )
    }

    private var licenseSection: some View {
        distributionSection(
            title: "insights.section.licenses",
            subtitle: "insights.section.licenses.subtitle",
            iconSource: .business(.license),
            iconColor: .yellow,
            items: snapshot.licenseItems
        )
    }

    private func distributionSection(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        iconSource: BusinessIcon.Source,
        iconColor: Color,
        items: [InsightsDistributionItem],
        onDrillDown: ((InsightsDistributionItem) -> Void)? = nil
    ) -> some View {
        // 不用 Swift Charts：分类轴 + AxisLabel offset 在 LazyVStack 里会把行高压扁，
        // 标签与柱体重叠。这里用显式 VStack 行高，宽度按本组最大值归一化。
        let maxCount = max(items.map(\.count).max() ?? 1, 1)

        return InsightsSectionContainer(
            title: title,
            subtitle: subtitle,
            iconSource: iconSource,
            iconColor: iconColor,
            chrome: .emphasized,
            headerTrailing: {
                if !items.isEmpty {
                    GrowthShareCopyButton {
                        technologyShareText(items)
                    }
                }
            }
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(title))
        }
    }

    /// 单行分布条使用独立行高避免标签和柱体重叠；色条每次出现时从 0 长到目标宽度。
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
        .listRowSurface(index: rowIndex)

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

    private var allActionsSection: some View {
        InsightsSectionContainer(
            title: "insights.selection.allActions",
            subtitle: scope == .knowledge
                ? "insights.section.actions.knowledgeSubtitle"
                : "insights.section.actions.starredSubtitle",
            systemImage: "checklist",
            iconColor: .purple,
            chrome: .emphasized
        ) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.actionItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    actionRow(item)
                        .listRowSurface(index: index)
                }
            }
        }
    }

    /// 原中栏的待办详情移到同一滚动页，保留统计数字和查看对应仓库的入口。
    private func actionDetailSection(_ item: InsightsActionItem) -> some View {
        let tint = InsightsColor.resolve(item.tintName)
        let title = LocalizedStringKey(item.titleKey)
        return InsightsSectionContainer(
            title: title,
            subtitle: LocalizedStringKey(item.detailKey),
            iconSource: item.id.iconSource,
            iconColor: tint,
            chrome: .emphasized
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.count.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(size: 32, weight: .semibold))
                    .monospacedDigit()

                Text("insights.action.repositoryCount")
                    .font(interfaceScale.font(.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button {
                    openDrillDown(.action(item.id))
                } label: {
                    Label("insights.drilldown.viewAll", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(tint)
                .accessibilityHint(Text(title))
            }
        }
    }

    private var coverageSection: some View {
        InsightsSectionContainer(
            title: topic == .health ? "insights.selection.healthSummary" : "insights.section.coverage",
            subtitle: "insights.section.coverage.subtitle",
            iconSource: .business(.repositoryHealth),
            iconColor: .pink,
            chrome: .emphasized
        ) {
            // 与知识覆盖一致：固定两项等分铺满，避免 adaptive 宽屏留白、窄列折行。
            // HStack 自身也要 maxWidth infinity：容器是 leading 对齐，否则只会 hug 内容挤在左侧。
            HStack(alignment: .top, spacing: 24) {
                coverageItem(
                    title: "insights.coverage.health",
                    coverage: snapshot.healthCoverage,
                    tint: .green
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                coverageItem(
                    title: "insights.coverage.openssf",
                    coverage: snapshot.openSSFCoverage,
                    tint: .blue
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            openDrillDown(.action(item.id))
        } label: {
            // 行图标与数量贴标题行，避免相对标题+说明整体居中。
            HStack(alignment: .top, spacing: 10) {
                BusinessIcon(source: item.id.iconSource, pointSize: interfaceScale.scaled(14))
                    .foregroundStyle(InsightsColor.resolve(item.tintName))
                    .frame(width: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(item.titleKey))
                        .font(interfaceScale.font(.bodyEmphasis))
                    Text(LocalizedStringKey(item.detailKey))
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(item.count.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(.bodyEmphasis))
                    .monospacedDigit()

                Image(systemName: "arrow.up.right")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityHint(Text("insights.action.detailHint"))
    }

    private func status(for id: String) -> RepoStatus? {
        switch id {
        case "unread": return .unread
        case "read": return .read
        case "using": return .using
        default: return nil
        }
    }

    /// 只发布类型化路由；Manage 负责安装临时筛选并展示返回洞察上下文。
    private func openDrillDown(_ target: InsightsDrillDownTarget) {
        guard let route = InsightsDrillDownRouter.route(
            scope: scope,
            target: target,
            embeddingModel: embeddingModel
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
        openRepository(link)
    }

    private func openRepository(_ link: RepositoryDeepLink) {
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
            // 标题优先占满剩余宽度并尽量单行；百分比 fixedSize，避免把长文案挤成换行。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(interfaceScale.font(.bodyEmphasis))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(percent(coverage.fraction))
                    .font(interfaceScale.font(.bodyEmphasis))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
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
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

}

/// 只复制可显示的技术统计与 Starcat 链接，分项和汇总入口使用同一格式。
private func technologyShareText(_ items: [InsightsDistributionItem]) -> String {
    GrowthAttribution.aggregateShareText(
        title: "My technology stack in Starcat",
        details: items.prefix(9).map { "\($0.title): \($0.count)" }
    )
}

/// 两类洞察共享语义色，快照只保存可跨 actor 的颜色名称。
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

/// Section 表面强度。默认 `standard` 给仓库洞察；`emphasized` 只给「我的洞察」，
/// 用更清晰的面板底 + 稍重描边，避免浅色下 window / control 背景糊成一片。
enum InsightsSectionChrome: Sendable {
    case standard
    case emphasized

    var cornerRadius: CGFloat {
        switch self {
        case .standard: return 9
        case .emphasized: return 10
        }
    }

    var fill: Color {
        switch self {
        case .standard:
            return Color(nsColor: .controlBackgroundColor)
        case .emphasized:
            // textBackground 在浅色窗口灰底上更接近「白面板」，深色仍是可读表面。
            return Color(nsColor: .textBackgroundColor)
        }
    }

    var strokeOpacity: Double {
        switch self {
        case .standard: return 0.14
        case .emphasized: return 0.22
        }
    }
}

/// 洞察页面的唯一分组表面：薄描边 + 系统背景，避免区块各自发展成多层嵌套卡片。
/// 仓库洞察继续走默认 `standard`；我的洞察传 `emphasized` + 彩色图标提升扫描层级。
struct InsightsSectionContainer<Content: View, HeaderTrailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let iconSource: BusinessIcon.Source
    let iconColor: Color
    let chrome: InsightsSectionChrome
    let headerTrailing: HeaderTrailing
    let content: Content

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        iconColor: Color = .secondary,
        chrome: InsightsSectionChrome = .standard,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            iconSource: .system(systemImage),
            iconColor: iconColor,
            chrome: chrome,
            headerTrailing: headerTrailing,
            content: content
        )
    }

    /// 原生系统图与补充素材共用原来的图标 chip，不能因许可证改用资源而另起一套布局。
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        iconSource: BusinessIcon.Source,
        iconColor: Color = .secondary,
        chrome: InsightsSectionChrome = .standard,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.iconSource = iconSource
        self.iconColor = iconColor
        self.chrome = chrome
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 图标 chip 与标题同行居中对齐；副标题缩进到标题文字下方，避免相对「标题+副标题」整块居中。
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 8) {
                    InsightsSectionIconChip(iconSource: iconSource, tint: iconColor)
                    Text(title)
                        .font(interfaceScale.font(.bodyEmphasis))
                    Spacer(minLength: 8)
                    headerTrailing
                }
                Text(subtitle)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            chrome.fill,
            in: RoundedRectangle(cornerRadius: chrome.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: chrome.cornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(chrome.strokeOpacity), lineWidth: 1)
        }
    }
}

/// 区块标题行左侧的彩色图标 chip（原型样式：圆角方块底 + 语义色图标）。
private struct InsightsSectionIconChip: View {
    let iconSource: BusinessIcon.Source
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.15))
            BusinessIcon(source: iconSource, pointSize: iconSource.isAsset ? 15 : 12, weight: .semibold)
                .foregroundStyle(tint)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

extension InsightsSectionContainer where HeaderTrailing == EmptyView {
    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        iconSource: BusinessIcon.Source,
        iconColor: Color = .secondary,
        chrome: InsightsSectionChrome = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            iconSource: iconSource,
            iconColor: iconColor,
            chrome: chrome,
            headerTrailing: { EmptyView() },
            content: content
        )
    }

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        iconColor: Color = .secondary,
        chrome: InsightsSectionChrome = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            iconColor: iconColor,
            chrome: chrome,
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
