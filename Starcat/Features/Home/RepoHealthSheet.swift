//
//  RepoHealthSheet.swift
//  Starcat
//
//  Repo Health 详情 sheet。
//
//  设计约束：
//  - Sheet 只读 `RepoHealthStore` 的缓存快照；无缓存时触发非阻塞刷新。
//  - 维度卡展示 payload 结构化 facts（子项标签 + 当前值/状态）,见 RepoHealthFact。
//  - 评分规则改为 popover（2026-06-21 v5,dong4j 反馈）：
//    与 OpenSSF 雷达图一致,点「评分规则」行弹出非模态 popover,失焦自动关闭;
//    不再用底部折叠面板,避免 sheet 高度难控。
//
//      v1 → 内嵌完整 sheet（被移除,理由与 badge 入口重复）
//      v2 → 完全不内嵌入口（被回滚,dong4j 反馈"右侧也是可点击的"）
//      v3 → 内嵌 popover（当前）：有 OpenSSF 聚合分时整行可点 → 弹出非模态
//           popover 展示雷达图（行为同 MenuBarExtra 状态栏面板）；无数据时
//           退化为普通 metadataRow。完整 checks 列表仍走 repo 详情头部
//           `OpenSSFInlineBadge → OpenSSFScoreSheet`,本入口只做「瞄一眼分布」。
//  - OpenSSF 行入口策略（2026-06-21 三段式演进）：

import SwiftUI

struct RepoHealthSheet: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var didRequestInitialSnapshot = false
    /// 评分规则 popover（2026-06-21 v5）——与 OpenSSF 行 popover 同一交互模型。
    @State private var isRulesPopoverPresented = false
    /// OpenSSF 行 popover 展示状态(2026-06-21 dong4j 反馈)。
    /// SwiftUI `.popover` 默认「点击外部自动关闭」,与「状态栏图标弹出面板」
    /// 行为一致;这里只持有 Bool,实际渲染在 `metadataSection` 里挂载。
    @State private var isOpenSSFPopoverPresented = false

    private var store: RepoHealthStore { dependencies.repoHealthStore }
    private var snapshot: RepoHealthSnapshot? { store.snapshot(for: repo.id) }
    /// 刷新按钮的 loading 态派生属性。
    /// `RepoHealthStore.refreshFromNetwork` 内部已用 `loadingRepoIDs` 防重入,
    /// 这里只是把 loading 状态投影成按钮内 ProgressView + accessibilityLabel 切换。
    private var isRefreshing: Bool { store.isLoading(repoId: repo.id) }
    private var payload: RepoHealthPayload? {
        guard let raw = snapshot?.payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RepoHealthPayload.self, from: raw)
    }
    /// OpenSSF 雷达图数据源(2026-06-21)。
    /// 与 `payload.openSSFScore`(聚合分,只用于行内文字)不同:这里取的是
    /// `OpenSSFScoreStore` 缓存里的 `checksJSON`,解码出 per-check 分项,
    /// 才能渲染 `OpenSSFRadarChart`。两套数据正常情况同步存在
    /// (RepoHealth 拉取时会一并写入 OpenSSF store),但分两个 store 持有
    /// 是历史决定,这里尊重现状。
    private var openSSFPayload: OpenSSFScorePayload? {
        guard let data = dependencies.openSSFScoreStore.record(for: repo.id)?.checksJSON
        else { return nil }
        return try? JSONDecoder().decode(OpenSSFScorePayload.self, from: data)
    }
    /// 过滤后用于雷达图的检查项——`isEvaluated = false` 的项 score == -1,
    /// 直接画进雷达会让整张图塌成一点,所以这里先滤掉。
    /// 与 `OpenSSFScoreSheet.scoreContent` 走同一份 `evaluated` 过滤,保证
    /// 行内 popover 与独立 sheet 看到完全一样的形状。
    private var evaluatedOpenSSFChecks: [OpenSSFScoreCheck] {
        (openSSFPayload?.checks ?? []).filter(\.isEvaluated)
    }

    /// sheet 固定 idealHeight（v5：维度卡含 facts 行,去掉底部折叠 footer）。
    ///
    /// 分段估算：… + metadata ≈ 200（含评分来源 3 行 + 分割线 + 评分规则）… 取 730。
    private static let sheetIdealHeight: CGFloat = 730

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 820,
               minHeight: Self.sheetIdealHeight,
               idealHeight: Self.sheetIdealHeight,
               maxHeight: .infinity)
        .task(id: repo.id) {
            didRequestInitialSnapshot = false
            await store.loadCachedSnapshots(for: [repo.id])
            if store.snapshot(for: repo.id) == nil {
                // 避开 sheet presentation 的首帧动画窗口：无快照时仍自动计算，
                // 但先让 SwiftUI 完成弹层布局/过渡，再触发 DB 读写与 Store 回写。
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                _ = await store.refresh(repo: repo, force: false)
            }
            didRequestInitialSnapshot = true
            // 同步预拉 OpenSSF 缓存(2026-06-21):
            // 进入 sheet 时即拉 radar 所需的 checksJSON,用户点 OpenSSF 行时
            // popover 可秒开,避免「点开 → 看到「暂无数据」→ 几秒后才填上」的
            // 视觉跳变。`prefetchIfNeeded` 是 fire-and-forget,不会阻塞 task。
            await dependencies.openSSFScoreStore.loadCachedScores(for: [repo.id])
            if dependencies.openSSFScoreStore.record(for: repo.id) == nil {
                dependencies.openSSFScoreStore.prefetchIfNeeded(repo: repo)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("repoHealth.sheet.title")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(verbatim: repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SyncIconButton(
                isRefreshing: isRefreshing,
                disabled: isRefreshing,
                font: .system(size: 14, weight: .medium),
                frameSize: 24,
                tooltip: isRefreshing
                    ? String.l10n("repoHealth.action.refreshing")
                    : String.l10n("repoHealth.action.refresh")
            ) {
                Task { await store.refreshFromNetwork(repo: repo) }
            }
            .accessibilityLabel(isRefreshing ? "repoHealth.action.refreshing" : "repoHealth.action.refresh")

            SheetCloseButton {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            // 三段固定高度铺完即满,无 ScrollView。
            // .frame(maxWidth: .infinity, alignment: .leading) 仅横向撑满 + 左对齐,
            // **不**设 maxHeight,让 content 用自然高度,避免撑出空白。
            // 顶部对齐由外层 VStack(alignment: .leading) + sheet 顶部边距保证。
            VStack(alignment: .leading, spacing: 16) {
                scoreSummary(snapshot)
                dimensionGrid(snapshot)
                metadataSection(snapshot)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if store.isLoading(repoId: repo.id) || !didRequestInitialSnapshot {
            loadingContent
        } else {
            unavailableContent
        }
    }

    private func scoreSummary(_ snapshot: RepoHealthSnapshot) -> some View {
        // v4（2026-06-21, dong4j 反馈「综合健康度太单调」）：
        // A) 270° 进度弧 + 中心等级/分数；状态改 Label+icon；卡片浅 tint wash
        // B) 底部四维 mini 预览条,与下方 dimensionGrid 视觉呼应
        let rounded = Int(snapshot.overallScore.rounded())
        let tint = healthTint(snapshot.overallScore)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                HealthScoreArcGauge(
                    score: snapshot.overallScore,
                    grade: snapshot.grade,
                    scoreLabel: "\(rounded) 分",
                    tint: tint
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("repoHealth.score.overall")
                        .font(.headline)
                    statusLabel(snapshot)
                    if let computed = snapshot.computedDate {
                        Text(String(format: String.l10n("repoHealth.computedAtFormat"), formattedDate(computed)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 0)
            }

            dimensionPreviewStrip(snapshot)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.10), tint.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    /// 四维 mini 预览条 —— summary 底部一行,让用户不用扫 2×2 grid 就知道哪项拖后腿。
    private func dimensionPreviewStrip(_ snapshot: RepoHealthSnapshot) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(healthDimensions(for: snapshot).enumerated()), id: \.offset) { _, dimension in
                HStack(spacing: 5) {
                    Image(systemName: dimension.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .imageScale(.small)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(healthTint(dimension.score))
                    Text(verbatim: "\(Int(dimension.score.rounded()))")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    String(
                        format: String.l10n("repoHealth.preview.dimensionFormat"),
                        String.l10n(dimension.titleKey),
                        Int(dimension.score.rounded())
                    )
                )
            }
        }
    }

    /// fetch 状态行 —— icon + 文案,比纯 secondary 文字更有层次。
    private func statusLabel(_ snapshot: RepoHealthSnapshot) -> some View {
        Label {
            Text(statusText(snapshot))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: statusSystemImage(snapshot.fetchStatus))
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint(snapshot.fetchStatus))
        }
    }

    /// 四个维度的 dimension / title / score / icon —— preview、grid 共用。
    private func healthDimensions(for snapshot: RepoHealthSnapshot) -> [(dimension: RepoHealthDimension, titleKey: String, score: Double, systemImage: String)] {
        [
            (.maintenance, "repoHealth.dimension.maintenance", snapshot.maintenanceScore, "gearshape.circle.fill"),
            (.popularity, "repoHealth.dimension.popularity", snapshot.popularityScore, "star.circle.fill"),
            (.quality, "repoHealth.dimension.quality", snapshot.qualityScore, "doc.circle.fill"),
            (.security, "repoHealth.dimension.security", snapshot.securityScore, "checkmark.shield.fill"),
        ]
    }

    private func facts(for dimension: RepoHealthDimension) -> [RepoHealthFact] {
        payload?.dimensions.first { $0.dimension == dimension }?.facts ?? []
    }

    private func statusSystemImage(_ status: RepoHealthFetchStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .partial: return "info.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func statusTint(_ status: RepoHealthFetchStatus) -> Color {
        switch status {
        case .success: return .green
        case .partial: return .yellow
        case .failed: return .red
        }
    }

    private func dimensionGrid(_ snapshot: RepoHealthSnapshot) -> some View {
        // 固定两列 HStack 而非 LazyVGrid:dong4j 2026-06-21 反馈右列「安全信号」
        // 与左列卡片左边距不齐。LazyVGrid 在左右卡高度差大时列宽/对齐易飘;
        // 两列等宽 VStack 保证列内左缘对齐。
        let dimensions = healthDimensions(for: snapshot)
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                dimensionCard(
                    title: LocalizedStringKey(dimensions[0].titleKey),
                    score: dimensions[0].score,
                    systemImage: dimensions[0].systemImage,
                    facts: facts(for: dimensions[0].dimension)
                )
                dimensionCard(
                    title: LocalizedStringKey(dimensions[2].titleKey),
                    score: dimensions[2].score,
                    systemImage: dimensions[2].systemImage,
                    facts: facts(for: dimensions[2].dimension)
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(spacing: 10) {
                dimensionCard(
                    title: LocalizedStringKey(dimensions[1].titleKey),
                    score: dimensions[1].score,
                    systemImage: dimensions[1].systemImage,
                    facts: facts(for: dimensions[1].dimension)
                )
                dimensionCard(
                    title: LocalizedStringKey(dimensions[3].titleKey),
                    score: dimensions[3].score,
                    systemImage: dimensions[3].systemImage,
                    facts: facts(for: dimensions[3].dimension)
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func dimensionCard(
        title: LocalizedStringKey,
        score: Double,
        systemImage: String,
        facts: [RepoHealthFact]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(healthTint(score))
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(verbatim: "\(Int(score.rounded()))")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            ProgressView(value: score, total: 100)
                .tint(healthTint(score))
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(facts, id: \.key) { fact in
                        factRow(fact)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 单条 fact：左标签（secondary）+ 右当前值（按 tone 染色；有 linkURL 时可点击跳转）。
    private func factRow(_ fact: RepoHealthFact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(fact.labelKey))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            factValueView(fact)
        }
    }

    @ViewBuilder
    private func factValueView(_ fact: RepoHealthFact) -> some View {
        if let linkURL = fact.linkURL, let url = URL(string: linkURL) {
            Link(destination: url) {
                HStack(spacing: 4) {
                    Text(verbatim: factDisplayValue(fact))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(factValueColor(fact.tone))
            }
            .multilineTextAlignment(.trailing)
        } else {
            Text(verbatim: factDisplayValue(fact))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(factValueColor(fact.tone))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factDisplayValue(_ fact: RepoHealthFact) -> String {
        let template = String.l10n(fact.valueKey)
        switch fact.valueArgs.count {
        case 0:
            return template
        case 1:
            return String(format: template, fact.valueArgs[0])
        case 2:
            return String(format: template, fact.valueArgs[0], fact.valueArgs[1])
        default:
            return template
        }
    }

    private func factValueColor(_ tone: RepoHealthFactTone) -> Color {
        switch tone {
        case .good: return .green
        case .neutral: return .primary
        case .bad: return .red
        case .missing: return .secondary
        }
    }

    private func metadataSection(_ snapshot: RepoHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            scoreSourcesSection()

            Divider()
                .padding(.vertical, 2)

            scoringRulesSection(snapshot)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 评分来源：项目元数据 + Release + OpenSSF 三类。
    private func scoreSourcesSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("repoHealth.sources.title")
                .font(.headline)

            metadataRow(
                icon: "tray.full",
                title: "repoHealth.sources.repoMetadata",
                value: String.l10n("repoHealth.sources.repoMetadata.value")
            )

            if let urlString = payload?.latestReleaseUrl,
               let url = URL(string: urlString) {
                Link(destination: url) {
                    metadataRowContent(
                        icon: "tag",
                        title: "repoHealth.sources.latestRelease",
                        value: payload?.latestReleaseTag ?? String.l10n("repoHealth.sources.missing"),
                        showLinkChevron: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("repoHealth.sources.openRelease")
            } else {
                metadataRow(
                    icon: "tag",
                    title: "repoHealth.sources.latestRelease",
                    value: payload?.latestReleaseTag ?? String.l10n("repoHealth.sources.missing")
                )
            }

            if payload?.openSSFScore != nil {
                Button {
                    isOpenSSFPopoverPresented.toggle()
                } label: {
                    metadataRowContent(
                        icon: "checkmark.shield",
                        title: "repoHealth.sources.openSSF",
                        value: payload?.openSSFScore.map { String(format: "%.1f", $0) } ?? String.l10n("repoHealth.sources.missing"),
                        showLinkChevron: true,
                        chevronSystemImage: "chevron.right.circle"
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("repoHealth.sources.openSSFChart")
                .popover(isPresented: $isOpenSSFPopoverPresented, arrowEdge: .trailing) {
                    OpenSSFChartPopover(checks: evaluatedOpenSSFChecks)
                        .appLocaleEnvironment()
                }
            } else {
                metadataRow(
                    icon: "checkmark.shield",
                    title: "repoHealth.sources.openSSF",
                    value: String.l10n("repoHealth.sources.missing")
                )
            }
        }
    }

    /// 评分规则：与「评分来源」分区,popover 展示（失焦自动关闭）。
    private func scoringRulesSection(_ snapshot: RepoHealthSnapshot) -> some View {
        Button {
            isRulesPopoverPresented.toggle()
        } label: {
            metadataRowContent(
                icon: "list.bullet.rectangle",
                title: "repoHealth.rules.title",
                value: String.l10n("repoHealth.rules.openPopover"),
                showLinkChevron: true,
                chevronSystemImage: "chevron.right.circle"
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("repoHealth.rules.openPopover")
        .popover(isPresented: $isRulesPopoverPresented, arrowEdge: .trailing) {
            RepoHealthRulesPopover(snapshot: snapshot)
                .appLocaleEnvironment()
        }
    }

    private func metadataRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
        metadataRowContent(icon: icon, title: title, value: value, showLinkChevron: false)
    }

    /// metadataRow 共享内容。
    /// - showLinkChevron: true 时在右侧多渲染一个箭头 icon,用于 `Link` / `Button` 包裹的整行可点场景
    ///   (2026-06-21 dong4j 反馈"Release 改成链接" → 新增"OpenSSF 行 popover")。
    /// - chevronSystemImage: 箭头 SF Symbol;默认 `arrow.up.right.square`(跳外站语义);
    ///   OpenSSF 行传 `chevron.right.circle`(就地展开语义)。
    private func metadataRowContent(
        icon: String,
        title: LocalizedStringKey,
        value: String,
        showLinkChevron: Bool,
        chevronSystemImage: String = "arrow.up.right.square"
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value)
                .fontWeight(.medium)
                .lineLimit(1)
            if showLinkChevron {
                Image(systemName: chevronSystemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        // hover 时整行高亮,提示可点击(Lift 风格;依赖 Link 默认行为足够,不强加自定义 button style)
        .contentShape(Rectangle())
    }

    private var loadingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("repoHealth.loading")
                .font(.headline)
            Text("repoHealth.loading.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var unavailableContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("repoHealth.unavailable")
                .font(.headline)
            Text("repoHealth.unavailable.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func statusText(_ snapshot: RepoHealthSnapshot) -> String {
        switch snapshot.fetchStatus {
        case .success:
            return String.l10n("repoHealth.status.success")
        case .partial:
            return String.l10n("repoHealth.status.partial")
        case .failed:
            return String.l10n("repoHealth.status.failed")
        }
    }

    private func healthTint(_ score: Double) -> Color {
        RepoHealthTint.color(score: score)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - HealthScoreArcGauge

/// 综合健康度 270° 进度弧 —— 底轨 + tint 前景,中心等级大字 + 分数小字。
///
/// 为什么 270° 而非整圆:底部留 90° 缺口,进度条有明确起止方向,
/// 比静态描边圆环更能传达「63/100」的比例感(dong4j 2026-06-21 v4)。
private struct HealthScoreArcGauge: View {
    let score: Double
    let grade: String
    let scoreLabel: String
    let tint: Color

    private let size: CGFloat = 96
    /// 270° / 360°
    private let arcFraction: CGFloat = 0.75
    private let lineWidth: CGFloat = 7
    /// 让 270° 弧的缺口居中落在底部
    private let startRotation: Double = 135

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.14), tint.opacity(0.03)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 2
                    )
                )

            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(
                    Color.primary.opacity(0.08),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(startRotation))

            Circle()
                .trim(from: 0, to: arcFraction * CGFloat(min(max(score, 0), 100) / 100))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(startRotation))

            VStack(spacing: -2) {
                Text(verbatim: grade)
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint)
                Text(verbatim: scoreLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: String.l10n("repoHealth.badge.a11y"),
                Int(score.rounded()),
                grade
            )
        )
    }
}

// MARK: - RepoHealthRulesPopover

/// 评分规则 popover（2026-06-21 v5）——行为同 `OpenSSFChartPopover`,失焦自动关闭。
struct RepoHealthRulesPopover: View {
    let snapshot: RepoHealthSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("repoHealth.rules.title")
                    .font(.headline)

                Text("repoHealth.rules.formula")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ruleRow(
                        icon: "gearshape.circle.fill",
                        title: "repoHealth.dimension.maintenance",
                        detail: "repoHealth.rules.maintenance",
                        tint: healthTint(snapshot.maintenanceScore)
                    )
                    ruleRow(
                        icon: "star.circle.fill",
                        title: "repoHealth.dimension.popularity",
                        detail: "repoHealth.rules.popularity",
                        tint: healthTint(snapshot.popularityScore)
                    )
                    ruleRow(
                        icon: "doc.circle.fill",
                        title: "repoHealth.dimension.quality",
                        detail: "repoHealth.rules.quality",
                        tint: healthTint(snapshot.qualityScore)
                    )
                    ruleRow(
                        icon: "checkmark.shield.fill",
                        title: "repoHealth.dimension.security",
                        detail: "repoHealth.rules.security",
                        tint: healthTint(snapshot.securityScore)
                    )
                }

                Text("repoHealth.rules.missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .frame(width: 420)
        .frame(maxHeight: 360)
    }

    private func ruleRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func healthTint(_ score: Double) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .yellow }
        return .red
    }
}
