//
//  AIUsageDashboardView.swift
//  Starcat
//
//  AI 用量统计窗口。采用 macOS 原生高密度卡片、Charts 与可下钻明细。
//

import Charts
import SwiftUI

struct AIUsageDashboardView: View {
    enum DetailTab: String, CaseIterable, Identifiable {
        case feature
        case model
        case calls

        var id: String { rawValue }
    }

    @State var viewModel: AIUsageDashboardViewModel
    @State private var detailTab: DetailTab = .feature
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if viewModel.snapshot.summary.callCount == 0, !viewModel.isLoading, viewModel.errorMessage == nil {
                    emptyState
                } else {
                    dashboard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if viewModel.isLoading, viewModel.snapshot.summary.callCount == 0 {
                    ProgressView()
                        .controlSize(.large)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        // AppKit 恢复较大窗口时，内容必须填满 hosting view 并钉在顶部；
        // 否则空状态只有最小固有高度，会在窗口中垂直居中，形成大块顶部留白。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.reload() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("ai.usage.title", systemImage: "chart.bar.xaxis")
                        .font(.title3.weight(.semibold))
                    Text("ai.usage.subtitle")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)

                SyncIconButton(
                    isRefreshing: viewModel.isLoading,
                    disabled: viewModel.isLoading,
                    tooltip: String.l10n("ai.usage.refresh")
                ) { reload() }
            }

            HStack(spacing: 12) {
                Picker("ai.usage.filter.range", selection: $viewModel.filter.timeRange) {
                    ForEach(AIUsageTimeRange.allCases) { range in
                        Text(range.titleKey).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: viewModel.filter.timeRange) { _, _ in reload() }

                Spacer(minLength: 20)

                filterMenu(
                    title: "ai.usage.filter.feature",
                    selection: featureFilterTitle
                ) {
                    Button("ai.usage.filter.allFeatures") {
                        Task { await viewModel.selectFeature(nil) }
                    }
                    Divider()
                    ForEach(AIUsageFeature.allCases.filter { $0 != .unknown }) { feature in
                        Button(feature.titleKey) {
                            Task { await viewModel.selectFeature(feature) }
                        }
                    }
                }

                filterMenu(
                    title: "ai.usage.filter.provider",
                    selection: viewModel.filter.providerID.map(providerFilterTitle)
                        ?? String.l10n("ai.usage.filter.allProviders"),
                    tooltip: viewModel.filter.providerID
                ) {
                    Button("ai.usage.filter.allProviders") {
                        viewModel.filter.providerID = nil
                        reload()
                    }
                    if !viewModel.snapshot.filterOptions.providerIDs.isEmpty { Divider() }
                    ForEach(viewModel.snapshot.filterOptions.providerIDs, id: \.self) { provider in
                        Button(providerFilterTitle(provider)) {
                            viewModel.filter.providerID = provider
                            reload()
                        }
                    }
                }

                filterMenu(
                    title: "ai.usage.filter.model",
                    selection: viewModel.filter.model ?? String.l10n("ai.usage.filter.allModels"),
                    tooltip: viewModel.filter.model
                ) {
                    Button("ai.usage.filter.allModels") {
                        Task { await viewModel.selectModel(nil) }
                    }
                    if !viewModel.snapshot.filterOptions.models.isEmpty { Divider() }
                    ForEach(viewModel.snapshot.filterOptions.models, id: \.self) { model in
                        Button(model) {
                            Task { await viewModel.selectModel(model) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func filterMenu<Content: View>(
        title: LocalizedStringKey,
        selection: String,
        tooltip: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Text(selection)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        // 按钮保持紧凑，完整模型名或历史 Provider ID 仍可通过悬停查看。
        .help(tooltip ?? selection)
        .accessibilityLabel(Text(title) + Text(": ") + Text(selection))
        .frame(maxWidth: 145)
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                kpiGrid
                trendCard
                detailCard
            }
            .padding(24)
        }
    }

    private var kpiGrid: some View {
        let summary = viewModel.snapshot.summary
        return HStack(spacing: 12) {
            metricCard(
                title: "ai.usage.metric.totalTokens",
                value: compact(summary.totalTokens),
                detail: String(format: String.l10n("ai.usage.metric.knownRateFormat"), percent(summary.usageAvailabilityRate)),
                icon: "sum",
                tint: .accentColor
            )
            metricCard(
                title: "ai.usage.metric.inputTokens",
                value: compact(summary.inputTokens),
                detail: String.l10n("ai.usage.metric.inputHint"),
                icon: "arrow.down.left",
                tint: .blue
            )
            metricCard(
                title: "ai.usage.metric.outputTokens",
                value: compact(summary.outputTokens),
                detail: String.l10n("ai.usage.metric.outputHint"),
                icon: "arrow.up.right",
                tint: .purple
            )
            metricCard(
                title: "ai.usage.metric.calls",
                value: compact(summary.callCount),
                detail: String(format: String.l10n("ai.usage.metric.successRateFormat"), percent(summary.successRate)),
                icon: "bolt.horizontal.circle",
                tint: .green
            )
            metricCard(
                title: "ai.usage.metric.embeddingItems",
                value: compact(summary.embeddingItemCount),
                detail: String.l10n("ai.usage.metric.embeddingHint"),
                icon: "point.3.connected.trianglepath.dotted",
                tint: .orange
            )
        }
    }

    private func metricCard(
        title: LocalizedStringKey,
        value: String,
        detail: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardSurface()
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ai.usage.trend.title")
                        .font(.headline)
                    Text("ai.usage.trend.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                legend(color: .blue, key: "ai.usage.metric.inputTokens")
                legend(color: .purple, key: "ai.usage.metric.outputTokens")
            }

            Chart(viewModel.snapshot.daily) { point in
                BarMark(
                    x: .value(String.l10n("ai.usage.trend.day"), point.day),
                    y: .value(String.l10n("ai.usage.metric.inputTokens"), point.inputTokens)
                )
                .foregroundStyle(Color.blue.gradient)
                BarMark(
                    x: .value(String.l10n("ai.usage.trend.day"), point.day),
                    y: .value(String.l10n("ai.usage.metric.outputTokens"), point.outputTokens)
                )
                .foregroundStyle(Color.purple.gradient)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let amount = value.as(Int.self) { Text(compact(amount)) }
                    }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
            .frame(height: 190)

            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.secondary)
                Text(String(
                    format: String.l10n("ai.usage.trend.callsFormat"),
                    compact(viewModel.snapshot.summary.callCount)
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .dashboardCard()
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("ai.usage.detail.title", selection: $detailTab) {
                ForEach(DetailTab.allCases) { tab in Text(tab.titleKey).tag(tab) }
            }
            .pickerStyle(.segmented)
            .frame(width: 360)

            Divider()

            switch detailTab {
            case .feature:
                dimensionRows(viewModel.snapshot.byFeature, kind: .feature)
            case .model:
                dimensionRows(viewModel.snapshot.byModel, kind: .model)
            case .calls:
                recentCallRows
            }
        }
        .dashboardCard()
    }

    private enum DimensionKind { case feature, model }

    private func dimensionRows(_ points: [AIUsageDimensionPoint], kind: DimensionKind) -> some View {
        let maxTokens = max(1, points.map(\.totalTokens).max() ?? 1)
        return LazyVStack(spacing: 0) {
            ForEach(points) { point in
                Button {
                    switch kind {
                    case .feature:
                        Task { await viewModel.selectFeature(AIUsageFeature(rawValue: point.key)) }
                    case .model:
                        Task { await viewModel.selectModel(point.key) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(dimensionTitle(point.key, kind: kind))
                            .font(kind == .model ? .callout.monospaced() : .callout)
                            .frame(width: 180, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.accentColor.opacity(0.55))
                                        .frame(width: proxy.size.width * CGFloat(point.totalTokens) / CGFloat(maxTokens))
                                }
                        }
                        .frame(height: 8)
                        Text(compact(point.inputTokens))
                            .foregroundStyle(.blue)
                            .frame(width: 70, alignment: .trailing)
                        Text(compact(point.outputTokens))
                            .foregroundStyle(.purple)
                            .frame(width: 70, alignment: .trailing)
                        Text(compact(point.totalTokens))
                            .fontWeight(.medium)
                            .frame(width: 80, alignment: .trailing)
                        Text(String(format: String.l10n("ai.usage.calls.shortFormat"), point.callCount))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                    .contentShape(Rectangle())
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                if point.id != points.last?.id { Divider() }
            }
        }
    }

    private var recentCallRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 最近调用仍保留完整 80 条快照，但交给 macOS 原生 Table 独立滚动，
            // 避免高频 Embedding 调用把整个 Dashboard 撑成超长页面。
            Table(viewModel.snapshot.recentEvents) {
                TableColumn("ai.usage.calls.time") { event in
                    Text(callDate(event.completedAt))
                }
                .width(min: 110, ideal: 130, max: 160)

                TableColumn("ai.usage.calls.feature") { event in
                    Text(featureTitle(event.feature))
                }
                .width(min: 100, ideal: 130, max: 150)

                TableColumn("ai.usage.calls.model") { event in
                    Text(event.model)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .help(event.model)
                }
                .width(min: 180, ideal: 280)

                TableColumn("ai.usage.calls.status") { event in
                    Label(statusTitle(event.status), systemImage: statusIcon(event.status))
                        .foregroundStyle(statusColor(event.status))
                }
                .width(min: 72, ideal: 88, max: 100)

                TableColumn("ai.usage.calls.duration") { event in
                    Text(duration(event.durationMs))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 78, max: 90)

                TableColumn("ai.usage.metric.totalTokens") { event in
                    Text(event.totalTokens.map(compact) ?? "—")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 86, max: 100)

                TableColumn("ai.usage.calls.source") { event in
                    Text(sourceTitle(event.usageSource))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 64, ideal: 78, max: 90)
            }
            .font(.caption)
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .frame(height: 420)

            Text(String(
                format: String.l10n("ai.usage.calls.recentCountFormat"),
                viewModel.snapshot.recentEvents.count
            ))
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func providerFilterTitle(_ providerID: String) -> String {
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == providerID }) else {
            return String(
                format: String.l10n("ai.usage.filter.unknownProviderFormat"),
                shortProviderID(providerID)
            )
        }

        let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return shortProviderID(providerID) }

        // 同名配置必须保留可区分性，但不再把完整 UUID 暴露给用户。
        let duplicateCount = viewModel.snapshot.filterOptions.providerIDs.filter { optionID in
            settings.aiProviderProfiles.first(where: { $0.id == optionID })?
                .displayName.trimmingCharacters(in: .whitespacesAndNewlines) == displayName
        }.count
        if duplicateCount > 1 {
            return "\(displayName) · \(shortProviderID(providerID, length: 4))"
        }
        return displayName
    }

    private func shortProviderID(_ providerID: String, length: Int = 8) -> String {
        String(providerID.prefix(length)).uppercased()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("ai.usage.empty.title", systemImage: "chart.bar.xaxis")
        } description: {
            Text("ai.usage.empty.description")
        } actions: {
            if viewModel.filter != AIUsageFilter() {
                Button("ai.usage.empty.clearFilters") {
                    viewModel.filter = AIUsageFilter()
                    reload()
                }
            }
        }
    }

    private func legend(color: Color, key: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(key).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var featureFilterTitle: String {
        viewModel.filter.feature.map { String.l10n($0.titleKeyString) }
            ?? String.l10n("ai.usage.filter.allFeatures")
    }

    private func dimensionTitle(_ key: String, kind: DimensionKind) -> String {
        kind == .feature ? featureTitle(key) : key
    }

    private func featureTitle(_ rawValue: String) -> String {
        guard let feature = AIUsageFeature(rawValue: rawValue) else { return rawValue }
        return String.l10n(feature.titleKeyString)
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(locale))
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    private func callDate(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp)
            .formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    private func duration(_ milliseconds: Int) -> String {
        let duration = Duration.milliseconds(milliseconds)
        if milliseconds < 1_000 {
            return duration.formatted(
                .units(allowed: [.milliseconds], width: .abbreviated).locale(locale)
            )
        }
        return duration.formatted(
            .units(
                allowed: [.seconds],
                width: .abbreviated,
                fractionalPart: .show(length: 1)
            )
            .locale(locale)
        )
    }

    private func statusTitle(_ rawValue: String) -> LocalizedStringKey {
        switch AIUsageStatus(rawValue: rawValue) {
        case .succeeded: "ai.usage.status.succeeded"
        case .failed: "ai.usage.status.failed"
        case .cancelled: "ai.usage.status.cancelled"
        case nil: "ai.usage.status.unknown"
        }
    }

    private func statusIcon(_ rawValue: String) -> String {
        switch AIUsageStatus(rawValue: rawValue) {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }

    private func statusColor(_ rawValue: String) -> Color {
        switch AIUsageStatus(rawValue: rawValue) {
        case .succeeded: .green
        case .failed: .orange
        case .cancelled, nil: .secondary
        }
    }

    private func sourceTitle(_ rawValue: String) -> LocalizedStringKey {
        switch AIUsageSource(rawValue: rawValue) {
        case .provider: "ai.usage.source.provider"
        case .estimated: "ai.usage.source.estimated"
        case .unavailable, nil: "ai.usage.source.unavailable"
        }
    }

    private func reload() {
        Task { await viewModel.reload() }
    }
}

private extension AIUsageTimeRange {
    var titleKey: LocalizedStringKey {
        switch self {
        case .today: "ai.usage.range.today"
        case .sevenDays: "ai.usage.range.sevenDays"
        case .thirtyDays: "ai.usage.range.thirtyDays"
        case .all: "ai.usage.range.all"
        }
    }
}

private extension AIUsageFeature {
    var titleKeyString: String { "ai.usage.feature.\(rawValue)" }
    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyString) }
}

private extension AIUsageDashboardView.DetailTab {
    var titleKey: LocalizedStringKey {
        switch self {
        case .feature: "ai.usage.detail.feature"
        case .model: "ai.usage.detail.model"
        case .calls: "ai.usage.detail.calls"
        }
    }
}

private struct AIUsageDashboardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // 浅色主题降低灰底存在感；深色主题保留更高明度差，避免卡片边界消失。
        let backgroundOpacity = colorScheme == .light ? 0.025 : 0.07
        content
            .background(Color.primary.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private extension View {
    func dashboardSurface() -> some View {
        modifier(AIUsageDashboardSurfaceModifier())
    }

    func dashboardCard() -> some View {
        padding(16)
            .dashboardSurface()
    }
}
