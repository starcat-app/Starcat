//
//  RepoHealthSheet.swift
//  Starcat
//
//  Repo Health 详情 sheet。
//
//  设计约束：
//  - Sheet 只读 `RepoHealthStore` 的缓存快照；无缓存时触发非阻塞刷新。
//  - 第一版不在 UI 中展示 payload_json 里的英文证据句，避免未本地化文本直出。
//  - 不内嵌 OpenSSF 详情入口（2026-06-21 dong4j 反馈移除）；
//    OpenSSF 数据作为 Security 维度的来源在 `metadataSection` 里展示即可。
//  - 评分规则做成"底部弹出面板"模式：默认折叠、整行触发条可点，
//    展开后从底部上滑出独立面板（不挤占主内容），符合 macOS inspector 语义。
//

import SwiftUI

struct RepoHealthSheet: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var didRequestInitialSnapshot = false
    /// 评分规则面板展开状态。默认折叠(@State 而非 @AppStorage),
    /// 保证每次打开 sheet 都是折叠态,符合 dong4j 在 2026-06-21 的要求。
    @State private var isRulesExpanded = false

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

    /// 评分规则面板固定高度。
    ///
    /// 内容是 1 公式 + 4 规则行 + 1 缺失说明,固定 280pt 视觉最稳定。
    /// 改自适应会让用户每次展开时面板高度抖动,体验反而不好。
    private static let rulesPanelHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            rulesFooterBar
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 820,
               minHeight: 520, idealHeight: 620, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // 评分规则面板作为"附属于窗口的二级面板",从底部上滑出。
            // 用 overlay 而不是放在 content 内,这样:
            // 1) 主内容(scoreSummary / dimensionGrid / metadataSection)
            //    始终稳定可见,不被规则面板挤掉;
            // 2) 面板展开/折叠动画只影响面板自身,不会触发主内容 frame 重排。
            if isRulesExpanded, let snapshot {
                scoringRulesPanel(snapshot)
                    .frame(height: Self.rulesPanelHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRulesExpanded)
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

            Button {
                Task { await store.refreshFromNetwork(repo: repo) }
            } label: {
                // loading 时把 arrow.clockwise 替换成 ProgressView 自带旋转,
                // 比按钮整体脉冲更克制,避免喧宾夺主。
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "repoHealth.action.refreshing" : "repoHealth.action.refresh")
            .help(isRefreshing ? "repoHealth.action.refreshing" : "repoHealth.action.refresh")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot {
            // 不再套 ScrollView:三段都是固定高度,自然铺完即满,
            // 配合 maxHeight: .infinity,窗口能按内容自适应,
            // 避免出现滚动条(dong4j 2026-06-21 反馈)。
            // .frame(maxHeight: .infinity, alignment: .top) 强制顶部对齐:
            // maxHeight 给了 sheet 弹性空间,但内容自身不撑满时不应在
            // 顶部或底部留白(dong4j 2026-06-21 反馈)。
            VStack(alignment: .leading, spacing: 16) {
                scoreSummary(snapshot)
                dimensionGrid(snapshot)
                metadataSection(snapshot)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if store.isLoading(repoId: repo.id) || !didRequestInitialSnapshot {
            loadingContent
        } else {
            unavailableContent
        }
    }

    private func scoreSummary(_ snapshot: RepoHealthSnapshot) -> some View {
        // alignment: .top —— 原 .center 会让圆卡固定 118pt 撑高整行,
        // 右侧文字高度不到 118pt 时留下顶部空白(dong4j 2026-06-21 反馈)。
        // 改为 top 对齐后圆卡与右侧文字顶部平齐,空白自然消失。
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(healthTint(snapshot.overallScore).opacity(0.14))
                Circle()
                    .stroke(healthTint(snapshot.overallScore).opacity(0.42), lineWidth: 1)
                VStack(spacing: 0) {
                    Text(verbatim: "\(Int(snapshot.overallScore.rounded()))")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(verbatim: snapshot.grade)
                        .font(.headline)
                        .foregroundStyle(healthTint(snapshot.overallScore))
                }
            }
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 8) {
                Text("repoHealth.score.overall")
                    .font(.headline)
                Text(statusText(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let computed = snapshot.computedDate {
                    Text(String(format: String.l10n("repoHealth.computedAtFormat"), formattedDate(computed)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func dimensionGrid(_ snapshot: RepoHealthSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            dimensionCard(title: "repoHealth.dimension.maintenance", score: snapshot.maintenanceScore, systemImage: "wrench.and.screwdriver")
            dimensionCard(title: "repoHealth.dimension.popularity", score: snapshot.popularityScore, systemImage: "star.circle")
            dimensionCard(title: "repoHealth.dimension.quality", score: snapshot.qualityScore, systemImage: "checklist")
            dimensionCard(title: "repoHealth.dimension.security", score: snapshot.securityScore, systemImage: "checkmark.shield")
        }
    }

    private func dimensionCard(title: LocalizedStringKey, score: Double, systemImage: String) -> some View {
        HStack(spacing: 10) {
            // SF Symbol 不同图标的 baseline / metric 不一致,直接设字号会导致
            // 4 张卡片图标视觉重量飘忽。统一 24x24 画布 + imageScale(.large) +
            // symbolRenderingMode(.hierarchical) 让所有 symbol 走同一视觉层级。
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .imageScale(.large)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(healthTint(score))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                ProgressView(value: score, total: 100)
                    .tint(healthTint(score))
            }
            Spacer()
            Text(verbatim: "\(Int(score.rounded()))")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metadataSection(_ snapshot: RepoHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("repoHealth.sources.title")
                .font(.headline)

            metadataRow(
                icon: "tag",
                title: "repoHealth.sources.latestRelease",
                value: payload?.latestReleaseTag ?? String.l10n("repoHealth.sources.missing")
            )
            metadataRow(
                icon: "checkmark.shield",
                title: "repoHealth.sources.openSSF",
                value: payload?.openSSFScore.map { String(format: "%.1f", $0) } ?? String.l10n("repoHealth.sources.missing")
            )
            // 不再内嵌"查看 OpenSSF 详情"入口:
            // 用户需要看 OpenSSF 细节时,从 repo 详情顶部 OpenSSFInlineBadge 进。
            // 这里只在 metadataSection 展示分数本身,避免与详情头部入口重复。
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 底部固定触发条：始终在窗口底部显示,整行可点切换评分规则面板展开/折叠。
    ///
    /// 设计要点:
    /// - 不再嵌套在 metadataSection 内,而是作为窗口的固定 footer,
    ///   视觉上明确"评分规则是附属于窗口的一个二级面板的触发入口";
    /// - chevron 旋转方向:`chevron.up` 展开时旋转 180°(箭头朝上指向会展开的方向),
    ///   折叠时回正(箭头朝下),符合 macOS inspector 的视觉习惯;
    /// - `.buttonStyle(.plain) + .focusEffectDisabled()` 遵守项目 UI 规范
    ///   (禁用 macOS 默认蓝色 focus ring,见 CLAUDE.md)。
    private var rulesFooterBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isRulesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("repoHealth.rules.title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isRulesExpanded ? 180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isRulesExpanded)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityHint(isRulesExpanded ? "repoHealth.rules.a11y.collapse" : "repoHealth.rules.a11y.expand")
    }

    /// 评分规则面板内容(展开时从底部上滑出)。
    ///
    /// 由 `body` 的 `.overlay(alignment: .bottom)` 挂载;高度由 `rulesPanelHeight` 控制。
    /// 与旧的 `scoringRulesSection` 不同:这里不再嵌在 metadata 后面,
    /// 而是作为独立的二级面板,展开时不挤占主内容、只覆盖底部。
    ///
    /// 面板**自带右上 x 关闭按钮**:展开后底部的 `rulesFooterBar` 被面板遮住,
    /// 用户无法从外部折叠,所以必须在面板内提供折叠入口(dong4j 2026-06-21 反馈)。
    ///
    /// 接收 `snapshot` 让 4 条规则图标按各自维度当前分数染色,
    /// 与上方 dimensionGrid 卡片颜色一致(dong4j 2026-06-21 反馈)。
    private func scoringRulesPanel(_ snapshot: RepoHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部一行:标题居左 + x 关闭按钮居右
            HStack(alignment: .center) {
                Text("repoHealth.rules.title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isRulesExpanded = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("common.close")
                .accessibilityLabel("common.close")
            }

            Text("repoHealth.rules.formula")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ruleRow(
                    icon: "wrench.and.screwdriver",
                    title: "repoHealth.dimension.maintenance",
                    detail: "repoHealth.rules.maintenance",
                    tint: healthTint(snapshot.maintenanceScore)
                )
                ruleRow(
                    icon: "star.circle",
                    title: "repoHealth.dimension.popularity",
                    detail: "repoHealth.rules.popularity",
                    tint: healthTint(snapshot.popularityScore)
                )
                ruleRow(
                    icon: "checklist",
                    title: "repoHealth.dimension.quality",
                    detail: "repoHealth.rules.quality",
                    tint: healthTint(snapshot.qualityScore)
                )
                ruleRow(
                    icon: "checkmark.shield",
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func ruleRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, tint: Color) -> some View {
        // 图标颜色与上方 dimensionCard 同色 —— 让"规则说明"和"当前分数"
        // 在视觉上能直接对应(dong4j 2026-06-21 反馈:规则区太单调)。
        // 染色逻辑来自 `healthTint(score)`:绿(>=80) / 黄(>=60) / 红(<60),
        // 与 dimensionCard 完全一致,用户一眼能看出每条规则对应哪个维度的状态。
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

    private func metadataRow(icon: String, title: LocalizedStringKey, value: String) -> some View {
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
        }
        .font(.subheadline)
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
        if score >= 80 { return .green }
        if score >= 60 { return .yellow }
        return .red
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
