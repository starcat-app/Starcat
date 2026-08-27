//
//  GitHubStarListAIGroupingPreflightView.swift
//  Starcat
//
//  AI 仓库分组开始前的只读概览。
//
//  页面展示全部仓库、去重后的已分组/未分组数量，以及每个现有分组的规则和少量仓库样例。
//  所有统计都由 PresentationSnapshot 一次性生成，SwiftUI body 不扫描完整仓库集合。
//  自动分组开关和置信度只作为本次任务的只读事实，不在这里改设置。
//

import SwiftUI

struct GitHubStarListAIGroupingPreflightView: View {
    let snapshot: GitHubStarListAIGroupingPresentationSnapshot
    let autoGroupingSettings: GitHubStarListAutoGroupingSettings

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCards

            Label("githubStarLists.aiGrouping.preflight.overlapNote", systemImage: "info.circle")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 14) {
                currentGroupsPanel
                sessionPanel
                    .frame(width: 280)
            }
            // 现有分组是该页的主要工作区，应消费剩余高度；右侧任务卡保持顶部对齐。
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("githubStarLists.aiGrouping.preflight.existingGroups")
                    .font(interfaceScale.font(.panelTitle))
                Spacer(minLength: 0)
                TextField("githubStarLists.aiGrouping.search.groups", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(interfaceScale.font(.caption))
                    .frame(width: 168)
            }

            ZStack {
                if filteredGroups.isEmpty {
                    ContentUnavailableView(
                        "githubStarLists.aiGrouping.noAvailableGroups",
                        systemImage: "tray",
                        description: Text("githubStarLists.aiGrouping.results.empty.help")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(filteredGroups) { group in
                                groupCard(group)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 205, maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(GitHubStarListAIGroupingPanelChrome(colorScheme: colorScheme))
    }

    private func groupCard(_ group: GitHubStarListAIPreflightGroupDisplay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: group.list.colorHex) ?? .accentColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(verbatim: group.list.name)
                    .font(interfaceScale.font(.rowTitle))
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
                    in: Capsule()
                )
            }

            Text(verbatim: group.hasAIRule
                ? group.list.instruction
                : String.l10n("githubStarLists.aiGrouping.error.noRules"))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    statusPill(
                        group.hasAIRule
                            ? LocalizedStringKey("githubStarLists.aiGrouping.preflight.ruleConfigured")
                            : LocalizedStringKey("githubStarLists.aiGrouping.preflight.ruleMissing"),
                        systemImage: group.hasAIRule ? "checkmark.circle.fill" : "exclamationmark.circle",
                        tint: group.hasAIRule ? Color.green : Color.secondary
                    )
                    statusPill(
                        group.autoApplyEnabled
                            ? LocalizedStringKey("githubStarLists.aiGrouping.preflight.autoEnabled")
                            : LocalizedStringKey("githubStarLists.aiGrouping.preflight.autoDisabled"),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: group.autoApplyEnabled ? Color.accentColor : Color.secondary
                    )
                }
                statusPill(
                    String(
                        format: String.l10n("githubStarLists.aiGrouping.preflight.thresholdFormat"),
                        locale: locale,
                        autoGroupingSettings.confidenceThreshold.formatted(
                            .percent.precision(.fractionLength(0)).locale(locale)
                        )
                    ),
                    systemImage: "checkmark.shield",
                    tint: .secondary
                )
            }

            if !group.sampleRepositoryNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("githubStarLists.aiGrouping.preflight.currentRepos")
                        .font(interfaceScale.font(.captionStrong))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(group.sampleRepositoryNames, id: \.self) { name in
                            repoChip(name)
                        }
                        let overflow = group.repositoryCount - group.sampleRepositoryNames.count
                        if overflow > 0 {
                            Text(verbatim: "+\(overflow)")
                                .font(interfaceScale.font(.caption))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    GitHubStarListAIGroupingSurface.chipFill(colorScheme),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GitHubStarListAIGroupingSurface.nestedFill(colorScheme),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func statusPill(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private func statusPill(
        _ title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private func repoChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(interfaceScale.font(.captionSmall))
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(interfaceScale.font(.caption))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            GitHubStarListAIGroupingSurface.chipFill(colorScheme),
            in: Capsule()
        )
        .help(name)
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Label("githubStarLists.aiGrouping.preflight.writeAfterReview", systemImage: "checkmark.shield")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                autoGroupingSettings.enabled
                    ? "githubStarLists.aiGrouping.preflight.autoGroupingOn"
                    : "githubStarLists.aiGrouping.preflight.autoGroupingOff",
                systemImage: autoGroupingSettings.enabled ? "checkmark.circle" : "pause.circle"
            )
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)

            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.preflight.thresholdFormat"),
                locale: locale,
                autoGroupingSettings.confidenceThreshold.formatted(
                    .percent.precision(.fractionLength(0)).locale(locale)
                )
            ))
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)

            Label("githubStarLists.aiGrouping.preflight.closedSetHelp", systemImage: "info.circle")
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
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(GitHubStarListAIGroupingPanelChrome(colorScheme: colorScheme))
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

    private var filteredGroups: [GitHubStarListAIPreflightGroupDisplay] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.preflightGroups }
        return snapshot.preflightGroups.filter {
            $0.list.name.localizedStandardContains(query)
                || $0.list.instruction.localizedStandardContains(query)
                || $0.sampleRepositoryNames.contains { $0.localizedStandardContains(query) }
        }
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
