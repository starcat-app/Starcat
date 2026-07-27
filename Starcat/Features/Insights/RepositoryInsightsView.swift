//
//  RepositoryInsightsView.swift
//  Starcat
//
//  仓库详情内的洞察页面。首阶段使用稳定 Mock 快照验证信息架构与图表密度；
//  View 只消费 RepositoryInsightsSnapshot，后续接入真实 Provider 时不改页面结构。
//

import Charts
import SwiftUI

struct RepositoryInsightsView: View {
    let repo: Repo
    let onScrollReport: (RepoDetailScrollReport) -> Void

    private let snapshot: RepositoryInsightsSnapshot

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    init(repo: Repo, onScrollReport: @escaping (RepoDetailScrollReport) -> Void) {
        self.repo = repo
        self.onScrollReport = onScrollReport
        snapshot = InsightsMockData.repositoryInsights(for: repo)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                activitySection
                commitSection
                contributorSection
                healthSection
                signalsSection
                timelineSection
            }
            .padding(18)
        }
        .detailScrollViewStyle()
        .onScrollGeometryChange(for: RepoDetailScrollReport.self) { geometry in
            RepoDetailScrollReport(
                offsetY: max(0, geometry.contentOffset.y),
                scrollOverflow: max(0, geometry.contentSize.height - geometry.containerSize.height)
            )
        } action: { _, report in
            onScrollReport(report)
        }
        .accessibilityLabel(Text("insights.repo.mode.insights"))
    }

    private var activitySection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.activity",
            subtitle: "insights.repo.section.activity.subtitle",
            systemImage: "waveform.path.ecg"
        ) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                ForEach(snapshot.activityMetrics) { metric in
                    activityMetric(metric)
                }
            }
        }
    }

    private func activityMetric(_ metric: RepositoryActivityMetric) -> some View {
        let tint = InsightsColor.resolve(metric.tintName)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: metric.systemImage)
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(metric.titleKey))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .font(interfaceScale.font(.caption))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.value.formatted())
                    .font(interfaceScale.font(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text(verbatim: metric.delta >= 0 ? "+\(metric.delta)%" : "\(metric.delta)%")
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(metric.delta >= 0 ? .green : .red)
                    .monospacedDigit()
            }

            Text("insights.repo.period.thirtyDays")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }

    private var commitSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.commits",
            subtitle: "insights.repo.section.commits.subtitle",
            systemImage: "chart.bar.fill"
        ) {
            Chart(snapshot.commitPoints) { point in
                BarMark(
                    x: .value("Week", point.weekLabel),
                    y: .value("Commits", point.commits)
                )
                .foregroundStyle(Color.green)
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 2)) {
                    AxisValueLabel()
                        .font(interfaceScale.font(.captionSmall))
                    AxisTick()
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisValueLabel()
                        .font(interfaceScale.font(.captionSmall))
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                }
            }
            .frame(height: 176)
        }
    }

    private var contributorSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.contributors",
            subtitle: "insights.repo.section.contributors.subtitle",
            systemImage: "person.3.fill"
        ) {
            HStack(spacing: 0) {
                ForEach(Array(snapshot.contributors.enumerated()), id: \.element.id) { index, contributor in
                    if index > 0 {
                        Divider()
                            .frame(height: 42)
                            .padding(.horizontal, 12)
                    }
                    contributorItem(contributor)
                }
            }
        }
    }

    private func contributorItem(_ contributor: RepositoryContributor) -> some View {
        HStack(spacing: 8) {
            Text(String(contributor.login.prefix(1)).uppercased())
                .font(interfaceScale.font(.caption, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(InsightsColor.resolve(contributor.colorName), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: contributor.login)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .lineLimit(1)
                Text(
                    String(
                        format: String.l10n("insights.repo.contributor.commitsFormat"),
                        contributor.commits
                    )
                )
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var healthSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.health",
            subtitle: "insights.repo.section.health.subtitle",
            systemImage: "heart.text.square.fill"
        ) {
            HStack(spacing: 18) {
                ForEach(snapshot.healthDimensions) { dimension in
                    healthItem(dimension)
                }
            }
        }
    }

    private func healthItem(_ dimension: RepositoryHealthDimensionItem) -> some View {
        let tint = InsightsColor.resolve(dimension.tintName)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label {
                    Text(LocalizedStringKey(dimension.titleKey))
                } icon: {
                    Image(systemName: dimension.systemImage)
                        .foregroundStyle(tint)
                }
                .font(interfaceScale.font(.caption, weight: .medium))
                Spacer(minLength: 6)
                Text(verbatim: "\(dimension.score)")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .monospacedDigit()
            }

            ProgressView(value: Double(dimension.score), total: 100)
                .tint(tint)
        }
        .frame(maxWidth: .infinity)
    }

    private var signalsSection: some View {
        HStack(alignment: .top, spacing: 14) {
            signalGroup(
                title: "insights.repo.section.community",
                subtitle: "insights.repo.section.community.subtitle",
                systemImage: "person.2.fill",
                signals: snapshot.communitySignals
            )
            signalGroup(
                title: "insights.repo.section.security",
                subtitle: "insights.repo.section.security.subtitle",
                systemImage: "lock.shield.fill",
                signals: snapshot.securitySignals
            )
        }
    }

    private func signalGroup(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        signals: [RepositorySignal]
    ) -> some View {
        InsightsSectionContainer(title: title, subtitle: subtitle, systemImage: systemImage) {
            VStack(spacing: 0) {
                ForEach(Array(signals.enumerated()), id: \.element.id) { index, signal in
                    if index > 0 {
                        Divider().padding(.leading, 28)
                    }
                    signalRow(signal)
                }
            }
        }
    }

    private func signalRow(_ signal: RepositorySignal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: signal.systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(signal.titleKey))
                .font(interfaceScale.font(.caption))
            Spacer(minLength: 8)
            Text(LocalizedStringKey(signal.detailKey))
                .font(interfaceScale.font(.captionSmall, weight: .medium))
                .foregroundStyle(signalColor(signal.state))
        }
        .padding(.vertical, 7)
    }

    private var timelineSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.timeline",
            subtitle: "insights.repo.section.timeline.subtitle",
            systemImage: "clock.arrow.circlepath"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(snapshot.timelineItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(InsightsColor.resolve(item.tintName))
                            .frame(width: 20)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title)
                                .font(interfaceScale.font(.caption, weight: .medium))
                            Text(verbatim: item.detail)
                                .font(interfaceScale.font(.captionSmall))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Text(LocalizedStringKey(item.relativeTimeKey))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func signalColor(_ state: RepositorySignal.State) -> Color {
        switch state {
        case .positive: return .green
        case .warning:  return .orange
        case .missing:  return .red
        }
    }
}
