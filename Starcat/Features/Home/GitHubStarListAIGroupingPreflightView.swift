//
//  GitHubStarListAIGroupingPreflightView.swift
//  Starcat
//
//  AI 仓库分组开始前的只读概览。
//
//  页面展示全部仓库、去重后的已分组/未分组数量，以及每个现有分组的规则和少量仓库样例。
//  所有统计都由 PresentationSnapshot 一次性生成，SwiftUI body 不扫描完整仓库集合。
//

import SwiftUI

struct GitHubStarListAIGroupingPreflightView: View {
    let snapshot: GitHubStarListAIGroupingPresentationSnapshot
    let autoGroupingSettings: GitHubStarListAutoGroupingSettings

    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryCards

            Label("githubStarLists.aiGrouping.explanation", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 14) {
                currentGroupsPanel
                sessionPanel
                    .frame(width: 250)
            }
            // “当前分组”是该页的主要工作区，应消费剩余高度；右侧说明卡保持顶部对齐。
            .frame(maxHeight: .infinity, alignment: .top)

            GroupBox {
                Label("githubStarLists.aiGrouping.privacy", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                title: "general.all",
                subtitle: "githubStarLists.aiGrouping.preflight.repositories",
                value: snapshot.preparedRepositoryCount,
                icon: "folder"
            )
            summaryCard(
                title: "githubStarLists.aiGrouping.inspector.currentGroups",
                value: snapshot.groupedRepositoryCount,
                icon: "person.2"
            )
            summaryCard(
                title: "sidebar.githubStarLists.ungrouped",
                value: snapshot.ungroupedRepositoryCount,
                icon: "tray"
            )
            summaryCard(
                title: "githubStarLists.aiGrouping.preflight.groups",
                value: snapshot.candidateListCount,
                icon: "square.stack.3d.up"
            )
        }
    }

    private func summaryCard(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        value: Int,
        icon: String
    ) -> some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Text(title)
                        if let subtitle {
                            Text(subtitle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Text(value, format: .number)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var currentGroupsPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("githubStarLists.aiGrouping.inspector.currentGroups")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    TextField("githubStarLists.aiGrouping.search.placeholder", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 180)
                }

                Divider()

                ZStack {
                    if filteredGroups.isEmpty {
                        ContentUnavailableView(
                            "githubStarLists.aiGrouping.noAvailableGroups",
                            systemImage: "tray",
                            description: Text("githubStarLists.aiGrouping.results.empty.help")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredGroups) { group in
                                    groupRow(group)
                                    if group.id != filteredGroups.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 205, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupRow(_ group: GitHubStarListAIPreflightGroupDisplay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: group.list.colorHex) ?? .accentColor)
                    .frame(width: 9, height: 9)
                Text(verbatim: group.list.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(group.repositoryCount, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(verbatim: group.hasAIRule
                ? group.list.instruction
                : String.l10n("githubStarLists.aiGrouping.error.noRules"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(
                    "githubStarLists.editor.aiRule.title",
                    systemImage: group.hasAIRule ? "checkmark.circle" : "exclamationmark.circle"
                )
                if group.autoApplyEnabled {
                    Label("githubStarLists.editor.aiRule.autoApply", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if !group.sampleRepositoryNames.isEmpty {
                Text(verbatim: group.sampleRepositoryNames.joined(separator: "  ·  "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }

    private var sessionPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("githubStarLists.aiGrouping.closedSet", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))

                LabeledContent("githubStarLists.aiGrouping.preflight.repositories") {
                    Text(snapshot.preparedRepositoryCount, format: .number)
                        .monospacedDigit()
                }
                LabeledContent("githubStarLists.aiGrouping.preflight.groups") {
                    Text(snapshot.candidateListCount, format: .number)
                        .monospacedDigit()
                }

                Divider()

                Label(
                    "settings.githubListGrouping.enabled.title",
                    systemImage: autoGroupingSettings.enabled ? "checkmark.circle" : "pause.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("settings.githubListGrouping.threshold.label") {
                    Text(autoGroupingSettings.confidenceThreshold, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                .font(.caption)

                Divider()

                Label("githubStarLists.aiGrouping.subtitle", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 225, alignment: .topLeading)
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
