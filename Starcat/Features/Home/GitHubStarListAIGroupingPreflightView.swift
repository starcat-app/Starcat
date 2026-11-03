//
//  GitHubStarListAIGroupingPreflightView.swift
//  Starcat
//
//  AI 仓库分组开始前的概览。
//
//  页面展示全部仓库、去重后的已分组/未分组数量，以及每个现有分组的规则。
//  所有统计都由 PresentationSnapshot 一次性生成，SwiftUI body 不扫描完整仓库集合。
//  本次自动确认开关只属于当前窗口，置信度仍写入 GitHubStarListAutoGroupingSettings。
//  分组 AI 规则在卡片内折叠填写，空规则不能打开自动整理。
//  开始页把“新增分组”的展示状态交给外层审核窗口持有。
//

import SwiftUI

/// 固定窗口内的开始页几何规格。
///
/// 从共用 840 × 560 画布扣除 header/footer/padding；大列表与长翻译各自在所属栏内滚动。
private enum GitHubStarListAIGroupingPreflightMetrics {
    static let contentSize = CGSize(width: AIOrganizationLayout.windowSize.width, height: AIOrganizationLayout.contentHeight)
    static let innerWidth = AIOrganizationLayout.innerWidth
    static let summaryHeight = AIOrganizationLayout.summaryHeight
    static let groupsPanelWidth = AIOrganizationLayout.leadingPanelWidth
    static let sessionPanelWidth = AIOrganizationLayout.sessionPanelWidth
    static let workspaceHeight = AIOrganizationLayout.panelHeight
    static let groupsContentWidth = groupsPanelWidth - 20
}

struct GitHubStarListAIGroupingPreflightView: View {
    let snapshot: GitHubStarListAIGroupingPresentationSnapshot
    let session: GitHubStarListAIGroupingSession

    @Environment(AppSettings.self) private var settings
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var openingConfidenceThreshold: Double?
    @State private var openingAutoConfirmEnabled: Bool?
    @Binding var autoConfirmEnabled: Bool
    @Binding var showCreateGroupSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards

            HStack(alignment: .top, spacing: AIOrganizationLayout.gap) {
                currentGroupsPanel
                sessionPanel
            }
            .frame(
                width: GitHubStarListAIGroupingPreflightMetrics.innerWidth,
                height: GitHubStarListAIGroupingPreflightMetrics.workspaceHeight,
                alignment: .top
            )
        }
        .padding(AIOrganizationLayout.padding)
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.contentSize.width,
            height: GitHubStarListAIGroupingPreflightMetrics.contentSize.height,
            alignment: .topLeading
        )
        .onAppear {
            // 与标签整理一致，“重置”只回到本窗口打开时的选项，不修改规则或仓库成员关系。
            if openingConfidenceThreshold == nil {
                openingConfidenceThreshold = settings.githubStarListAutoGroupingSettings.confidenceThreshold
                openingAutoConfirmEnabled = autoConfirmEnabled
            }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 8) {
            summaryCard(
                title: "general.all",
                subtitle: "githubStarLists.aiGrouping.preflight.repositories",
                value: snapshot.preparedRepositoryCount,
                icon: "folder",
                tint: .purple
            )
            summaryCard(
                title: "githubStarLists.aiGrouping.preflight.grouped",
                value: snapshot.groupedRepositoryCount,
                icon: "person.2",
                tint: .green,
                proportion: proportion(snapshot.groupedRepositoryCount)
            )
            summaryCard(
                title: "sidebar.githubStarLists.ungrouped",
                value: snapshot.ungroupedRepositoryCount,
                icon: "tray",
                tint: .orange,
                proportion: proportion(snapshot.ungroupedRepositoryCount)
            )
            summaryCard(
                title: "githubStarLists.aiGrouping.preflight.groups",
                value: snapshot.candidateListCount,
                icon: "square.stack.3d.up",
                tint: .blue
            )
        }
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.innerWidth,
            height: GitHubStarListAIGroupingPreflightMetrics.summaryHeight
        )
    }

    private func summaryCard(
        title: String,
        subtitle: String? = nil,
        value: Int,
        icon: String,
        tint: Color,
        proportion: String? = nil
    ) -> some View {
        AIOrganizationSummaryCard(
            title: [title, subtitle].compactMap { $0 }.map { String.l10n($0) }.joined(separator: " "),
            value: value.formatted(.number.locale(locale)),
            symbol: icon,
            tint: tint,
            proportion: proportion
        )
    }

    /// 使用去重后的仓库总数计算覆盖比例，多分组成员数不能作为分母。
    private func proportion(_ count: Int) -> String {
        let value = snapshot.preparedRepositoryCount > 0
            ? Double(count) / Double(snapshot.preparedRepositoryCount)
            : 0
        return value.formatted(.percent.precision(.fractionLength(1)).locale(locale))
    }

    private var currentGroupsPanel: some View {
        let groups = filteredGroups
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("githubStarLists.aiGrouping.preflight.existingGroups")
                    .font(interfaceScale.font(.body, weight: .semibold))
                    .lineLimit(1)
                    .help("githubStarLists.aiGrouping.preflight.existingGroups")
                Text(snapshot.preflightGroups.count, format: .number.locale(locale))
                    .font(interfaceScale.font(.captionStrong))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(GitHubStarListAIGroupingSurface.chipFill(colorScheme), in: Capsule())
                Spacer(minLength: 0)
                TextField("githubStarLists.aiGrouping.search.groups", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(interfaceScale.font(.caption))
                    .frame(width: 136)
                Button {
                    PerformanceTracer.shared.mark(.gitHubStarListCreateRequested)
                    showCreateGroupSheet = true
                } label: {
                    Label("sidebar.githubStarLists.add", systemImage: "plus")
                        .font(interfaceScale.font(.caption))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(Text("sidebar.githubStarLists.add"))
            }

            // 隐私说明属于整批规则的共同约束，只展示一次，避免每张分组卡重复占用空间。
            Text("githubStarLists.aiGrouping.preflight.rulesPrivacyNote")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if snapshot.preflightGroups.isEmpty || groups.isEmpty {
                    emptyGroupsView
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(groups) { group in
                                GitHubStarListAIGroupingRuleCard(group: group, session: session)
                            }
                        }
                    }
                }
            }
            .frame(
                width: GitHubStarListAIGroupingPreflightMetrics.groupsContentWidth,
                alignment: .top
            )
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(10)
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.groupsPanelWidth,
            height: GitHubStarListAIGroupingPreflightMetrics.workspaceHeight,
            alignment: .top
        )
        .clipped()
        .modifier(GitHubStarListAIGroupingPanelChrome(colorScheme: colorScheme))
    }

    /// 空状态只绘制固定尺寸的三行内容，不再使用会读取容器 ideal size 的
    /// `ContentUnavailableView + ZStack` 组合。
    private var emptyGroupsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(interfaceScale.font(.iconLarge))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("githubStarLists.aiGrouping.noAvailableGroups")
                .font(interfaceScale.font(.body, weight: .semibold))
            Text("githubStarLists.aiGrouping.results.empty.help")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button("sidebar.githubStarLists.add") {
                PerformanceTracer.shared.mark(.gitHubStarListCreateRequested)
                showCreateGroupSheet = true
            }
        }
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.groupsContentWidth,
            alignment: .center
        )
        .frame(maxHeight: .infinity)
    }

    private var sessionPanel: some View {
        ScrollView {
            sessionContents
        }
        .padding(10)
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.sessionPanelWidth,
            height: GitHubStarListAIGroupingPreflightMetrics.workspaceHeight,
            alignment: .topLeading
        )
        .modifier(GitHubStarListAIGroupingPanelChrome(colorScheme: colorScheme))
    }

    private var sessionContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("githubStarLists.aiGrouping.preflight.session")
                    .font(interfaceScale.font(.body, weight: .semibold))
                Spacer(minLength: 4)
                ResetIconButton(help: Text("settings.general.reset"), font: interfaceScale.font(.iconMedium)) {
                    if let openingAutoConfirmEnabled { autoConfirmEnabled = openingAutoConfirmEnabled }
                    if let openingConfidenceThreshold { confidenceThresholdBinding.wrappedValue = openingConfidenceThreshold }
                }
            }

            sessionFactRow(
                title: "githubStarLists.aiGrouping.preflight.toAnalyze",
                value: snapshot.analysisTotalCount,
                icon: "magnifyingglass"
            )
            sessionFactRow(
                title: "githubStarLists.aiGrouping.preflight.eligibleGroups",
                value: snapshot.candidateListCount,
                icon: "rectangle.stack"
            )
            sessionFactRow(
                title: "githubStarLists.aiGrouping.preflight.groupsWithoutRules",
                value: groupsWithoutRulesCount,
                icon: "square.dashed"
            )
            sessionFactRow(
                title: "githubStarLists.aiGrouping.filter.automaticallyIgnored",
                value: snapshot.preparedAutomaticallyIgnoredRepoCount,
                icon: "exclamationmark.circle"
            )

            Divider()

            CompactSettingsToggleRow(
                title: "githubStarLists.aiGrouping.preflight.autoConfirm",
                isOn: $autoConfirmEnabled
            )

            // 阈值始终展开；关闭自动确认时只禁用 Slider，保留当前数值和说明。
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.githubListGrouping.threshold.label")
                    Spacer(minLength: 8)
                    Text(verbatim: confidenceThresholdPercentString)
                        .font(interfaceScale.font(.captionStrong))
                        .foregroundStyle(.tint)
                        .monospacedDigit()
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)

                Slider(value: confidenceThresholdBinding, in: 0.5...1.0, step: 0.05)
                    .controlSize(.mini)
                    .disabled(!autoConfirmEnabled)

                Text(String(
                    format: String.l10n("settings.githubListGrouping.threshold.hintFormat"),
                    locale: locale,
                    confidenceThresholdPercentString
                ))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                if snapshot.preparedAutomaticallyIgnoredRepoCount > 0 {
                    sessionNote("githubStarLists.aiGrouping.preflight.automaticallyIgnoredCompactReason")
                }
                sessionNote("githubStarLists.aiGrouping.preflight.multipleGroupsCompactNote")
                sessionNote("githubStarLists.aiGrouping.preflight.configuredGroupsCompactNote")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionNote(_ title: LocalizedStringKey) -> some View {
        Label(title, systemImage: "info.circle")
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GitHubStarListAIGroupingSurface.nestedFill(colorScheme),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sessionFactRow(
        title: LocalizedStringKey,
        value: Int,
        icon: String
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Text(title))
            Spacer(minLength: 8)
            Text(value, format: .number.locale(locale))
                .font(interfaceScale.font(.bodyEmphasis))
                .monospacedDigit()
        }
    }

    private var groupsWithoutRulesCount: Int {
        snapshot.preflightGroups.filter { !$0.hasAIRule }.count
    }

    private var filteredGroups: [GitHubStarListAIPreflightGroupDisplay] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.preflightGroups }
        return snapshot.preflightGroups.filter {
            $0.list.name.localizedStandardContains(query)
                || $0.list.instruction.localizedStandardContains(query)
        }
    }

    private var confidenceThresholdPercentString: String {
        "\(Int((settings.githubStarListAutoGroupingSettings.confidenceThreshold * 100).rounded()))%"
    }

    private var confidenceThresholdBinding: Binding<Double> {
        Binding(
            get: { settings.githubStarListAutoGroupingSettings.confidenceThreshold },
            set: { newValue in
                var grouping = settings.githubStarListAutoGroupingSettings
                grouping.confidenceThreshold = GitHubStarListAutoGroupingSettings.clamp(newValue)
                settings.githubStarListAutoGroupingSettings = grouping
            }
        )
    }
}

/// 现有分组卡：整行展开后就地填写 AI 规则。输入防抖写入本地规则，避免每个按键打数据库。
private struct GitHubStarListAIGroupingRuleCard: View {
    let group: GitHubStarListAIPreflightGroupDisplay
    let session: GitHubStarListAIGroupingSession

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded: Bool
    @State private var instruction: String
    @State private var saveTask: Task<Void, Never>?

    init(group: GitHubStarListAIPreflightGroupDisplay, session: GitHubStarListAIGroupingSession) {
        self.group = group
        self.session = session
        _isExpanded = State(initialValue: !group.hasAIRule)
        _instruction = State(initialValue: group.list.instruction)
    }

    private var hasRuleDraft: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    AIOrganizationIconBadge(
                        symbol: "folder.fill", tint: Color(hex: group.list.colorHex) ?? .accentColor
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: group.list.colorHex) ?? .accentColor)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(verbatim: group.list.name)
                                .font(interfaceScale.font(.bodyEmphasis))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .help(Text(verbatim: group.list.name))
                            Spacer(minLength: 4)
                            Text(String(
                                format: String.l10n("githubStarLists.aiGrouping.preflight.repoCountFormat"),
                                locale: locale,
                                group.repositoryCount
                            ))
                            .font(interfaceScale.font(.captionStrong))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                GitHubStarListAIGroupingSurface.chipFill(colorScheme),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        if !isExpanded {
                            Text(verbatim: hasRuleDraft
                                 ? instruction
                                 : String.l10n("githubStarLists.aiGrouping.error.noRules"))
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(Text(verbatim: instruction))
                        }
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                TextField(
                    "githubStarLists.editor.aiRule.placeholder",
                    text: $instruction,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .font(interfaceScale.font(.caption))
                .lineLimit(2...4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GitHubStarListAIGroupingSurface.nestedFill(colorScheme),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onChange(of: instruction) { _, _ in
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            Task { await persistIfNeeded() }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await persistIfNeeded()
        }
    }

    private func persistIfNeeded() async {
        let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRule = session.rulesByListID[group.list.id]
        guard normalized != currentRule?.instruction else { return }
        await session.saveRule(
            listID: group.list.id,
            instruction: instruction,
            // 手动整理页只编辑 AI 判断规则；后台写入授权仍由分组编辑器单独控制。
            autoApplyEnabled: currentRule?.autoApplyEnabled ?? group.autoApplyEnabled
        )
    }
}

/// 开始页表面层级对齐 DESIGN.md：窗口底 `surface-*`，卡片 `panel-*`，内层再抬一档。
///
/// 深色下不能再用 `controlBackgroundColor` 铺卡片——它几乎等于窗口底，嵌套表面会糊掉。
private enum GitHubStarListAIGroupingSurface {
    static func panelFill(_ colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255) // panel-dark #2C2C2E
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    static func nestedFill(_ colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255) // separator-dark #3A3A3C
        } else {
            Color.primary.opacity(0.04)
        }
    }

    static func chipFill(_ colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            Color.white.opacity(0.10)
        } else {
            Color.primary.opacity(0.06)
        }
    }

    static func panelStroke(_ colorScheme: ColorScheme) -> Color {
        Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.85 : 0.45)
    }
}

/// 开始页面板共用的抬升底 + 描边。
private struct GitHubStarListAIGroupingPanelChrome: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .background(
                GitHubStarListAIGroupingSurface.panelFill(colorScheme),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GitHubStarListAIGroupingSurface.panelStroke(colorScheme))
            )
    }
}
