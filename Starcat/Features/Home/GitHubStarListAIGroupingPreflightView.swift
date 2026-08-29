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
/// 所有宽高都从 960 × 640 的窗口扣除 header/footer/padding 得出，避免内部双栏继续用
/// `.infinity` 参与窗口 fitting-size 推导。仅分组列表保留真正需要的滚动区域。
private enum GitHubStarListAIGroupingPreflightMetrics {
    static let contentSize = CGSize(width: 960, height: 516)
    static let innerWidth: CGFloat = 932
    static let summaryCardWidth: CGFloat = 225.5
    static let summaryHeight: CGFloat = 54
    static let groupsPanelWidth: CGFloat = 640
    static let sessionPanelWidth: CGFloat = 280
    static let workspaceHeight: CGFloat = 424
    static let groupsContentWidth: CGFloat = 616
    static let groupsContentHeight: CGFloat = 366
}

struct GitHubStarListAIGroupingPreflightView: View {
    let snapshot: GitHubStarListAIGroupingPresentationSnapshot
    let session: GitHubStarListAIGroupingSession

    @Environment(AppSettings.self) private var settings
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @Binding var autoConfirmEnabled: Bool
    @Binding var showCreateGroupSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards

            HStack(alignment: .top, spacing: 12) {
                currentGroupsPanel
                sessionPanel
            }
            .frame(
                width: GitHubStarListAIGroupingPreflightMetrics.innerWidth,
                height: GitHubStarListAIGroupingPreflightMetrics.workspaceHeight,
                alignment: .top
            )
        }
        .padding(14)
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.contentSize.width,
            height: GitHubStarListAIGroupingPreflightMetrics.contentSize.height,
            alignment: .topLeading
        )
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
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
                tint: .green
            )
            summaryCard(
                title: "sidebar.githubStarLists.ungrouped",
                value: snapshot.ungroupedRepositoryCount,
                icon: "tray",
                tint: .orange
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
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        value: Int,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(interfaceScale.font(.iconMedium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                    }
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(value, format: .number.locale(locale))
                    .font(interfaceScale.font(.panelTitle))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.summaryCardWidth,
            height: GitHubStarListAIGroupingPreflightMetrics.summaryHeight,
            alignment: .leading
        )
        .background(
            tint.opacity(colorScheme == .dark ? 0.22 : 0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(colorScheme == .dark ? 0.45 : 0.28))
        )
    }

    private var currentGroupsPanel: some View {
        let groups = filteredGroups
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("githubStarLists.aiGrouping.preflight.existingGroups")
                    .font(interfaceScale.font(.panelTitle))
                Spacer(minLength: 0)
                Button {
                    PerformanceTracer.shared.mark(.gitHubStarListCreateRequested)
                    showCreateGroupSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(interfaceScale.font(.iconMedium, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("sidebar.githubStarLists.add"))
                TextField("githubStarLists.aiGrouping.search.groups", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(interfaceScale.font(.caption))
                    .frame(width: 168)
            }

            Group {
                if snapshot.preflightGroups.isEmpty || groups.isEmpty {
                    emptyGroupsView
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(groups) { group in
                                GitHubStarListAIGroupingRuleCard(group: group, session: session)
                            }
                        }
                    }
                }
            }
            .frame(
                width: GitHubStarListAIGroupingPreflightMetrics.groupsContentWidth,
                height: GitHubStarListAIGroupingPreflightMetrics.groupsContentHeight,
                alignment: .top
            )
        }
        .padding(12)
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
                .font(interfaceScale.font(.workspaceTitle))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("githubStarLists.aiGrouping.noAvailableGroups")
                .font(interfaceScale.font(.panelTitle))
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
            height: GitHubStarListAIGroupingPreflightMetrics.groupsContentHeight,
            alignment: .center
        )
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("githubStarLists.aiGrouping.preflight.session")
                .font(interfaceScale.font(.panelTitle))

            sessionFactRow(
                title: "githubStarLists.aiGrouping.preflight.toAnalyze",
                value: snapshot.preparedRepositoryCount,
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
                title: "githubStarLists.aiGrouping.preflight.autoOrganizeGroups",
                value: autoOrganizeGroupCount,
                icon: "bolt.horizontal"
            )

            Divider()

            Toggle("githubStarLists.aiGrouping.preflight.autoConfirm", isOn: $autoConfirmEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(interfaceScale.font(.caption))

            Text(verbatim: autoConfirmDescription)
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if autoConfirmEnabled {
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

                    Text(String(
                        format: String.l10n("settings.githubListGrouping.threshold.hintFormat"),
                        locale: locale,
                        confidenceThresholdPercentString
                    ))
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sessionNote("githubStarLists.aiGrouping.preflight.overlapNote")
                sessionNote("githubStarLists.aiGrouping.preflight.closedSetHelp")
            }
        }
        .padding(12)
        .frame(
            width: GitHubStarListAIGroupingPreflightMetrics.sessionPanelWidth,
            height: GitHubStarListAIGroupingPreflightMetrics.workspaceHeight,
            alignment: .topLeading
        )
        .clipped()
        .modifier(GitHubStarListAIGroupingPanelChrome(colorScheme: colorScheme))
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
            Spacer(minLength: 8)
            Text(value, format: .number.locale(locale))
                .font(interfaceScale.font(.bodyEmphasis))
                .monospacedDigit()
        }
    }

    private var groupsWithoutRulesCount: Int {
        snapshot.preflightGroups.filter { !$0.hasAIRule }.count
    }

    private var autoOrganizeGroupCount: Int {
        snapshot.preflightGroups.filter(\.autoApplyEnabled).count
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

    private var autoConfirmDescription: String {
        if autoConfirmEnabled {
            String(
                format: String.l10n("githubStarLists.aiGrouping.preflight.autoConfirm.enabledFormat"),
                locale: locale,
                confidenceThresholdPercentString
            )
        } else {
            String.l10n("githubStarLists.aiGrouping.preflight.autoConfirm.disabled")
        }
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
    @State private var autoApplyEnabled: Bool
    @State private var saveTask: Task<Void, Never>?

    init(group: GitHubStarListAIPreflightGroupDisplay, session: GitHubStarListAIGroupingSession) {
        self.group = group
        self.session = session
        _isExpanded = State(initialValue: !group.hasAIRule)
        _instruction = State(initialValue: group.list.instruction)
        _autoApplyEnabled = State(initialValue: group.autoApplyEnabled)
    }

    private var hasRuleDraft: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    Circle()
                        .fill(Color(hex: group.list.colorHex) ?? .accentColor)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(verbatim: group.list.name)
                        .font(interfaceScale.font(.rowTitle))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(String(
                        format: String.l10n("githubStarLists.aiGrouping.preflight.repoCountFormat"),
                        locale: locale,
                        group.repositoryCount
                    ))
                    .font(interfaceScale.font(.captionStrong))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        GitHubStarListAIGroupingSurface.chipFill(colorScheme),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
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

                Text("githubStarLists.editor.aiRule.help")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $autoApplyEnabled) {
                    Text("githubStarLists.aiGrouping.preflight.autoOrganize")
                        .font(interfaceScale.font(.caption))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!hasRuleDraft)
                .help(hasRuleDraft
                      ? LocalizedStringKey("githubStarLists.editor.aiRule.autoApply")
                      : LocalizedStringKey("githubStarLists.editor.aiRule.autoApply.disabledHelp"))
            } else {
                Text(verbatim: hasRuleDraft
                     ? instruction
                     : String.l10n("githubStarLists.aiGrouping.error.noRules"))
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GitHubStarListAIGroupingSurface.nestedFill(colorScheme),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .onChange(of: instruction) { _, _ in
            if !hasRuleDraft {
                autoApplyEnabled = false
            }
            scheduleSave()
        }
        .onChange(of: autoApplyEnabled) { _, _ in
            saveNow()
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

    private func saveNow() {
        saveTask?.cancel()
        Task { await persistIfNeeded() }
    }

    private func persistIfNeeded() async {
        let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = !normalized.isEmpty && autoApplyEnabled
        guard normalized != group.list.instruction || enabled != group.autoApplyEnabled else { return }
        await session.saveRule(
            listID: group.list.id,
            instruction: instruction,
            autoApplyEnabled: autoApplyEnabled
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
