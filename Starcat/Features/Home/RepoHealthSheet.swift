//
//  RepoHealthSheet.swift
//  Starcat
//
//  Repo Health 详情 sheet。
//
//  设计约束：
//  - Sheet 只读 `RepoHealthStore` 的缓存快照；无缓存时触发非阻塞刷新。
//  - 第一版不在 UI 中展示 payload_json 里的英文证据句，避免未本地化文本直出。
//  - OpenSSF 行入口策略（2026-06-21 三段式演进）：
//      v1 → 内嵌完整 sheet（被移除,理由与 badge 入口重复）
//      v2 → 完全不内嵌入口（被回滚,dong4j 反馈"右侧也是可点击的"）
//      v3 → 内嵌 popover（当前）：有 OpenSSF 聚合分时整行可点 → 弹出非模态
//           popover 展示雷达图（行为同 MenuBarExtra 状态栏面板）；无数据时
//           退化为普通 metadataRow。完整 checks 列表仍走 repo 详情头部
//           `OpenSSFInlineBadge → OpenSSFScoreSheet`,本入口只做「瞄一眼分布」。
//  - 评分规则做成"底部面板切换"模式（2026-06-21 v2 方案）：
//    折叠态渲染触发条、展开态渲染面板,**同一位置根据状态切换**,
//    不用 overlay 弹层。overlay 路线在展开时会让 sheet 撑高
//    多出来的空间滞留在 content 与面板之间形成大片空白
//    (dong4j 2026-06-21 反馈),v2 改用 VStack footer 切换彻底解决。
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

    /// sheet 折叠态的基础 idealHeight。
    ///
    /// 由 header(50) + content(自然高度约 380,含 padding 412) + rulesFooterBar(50) 累加而来。
    /// 圆卡从固定 118pt 改为自适应 88/104pt 后 content 高度下降约 30pt。
    /// 展开态在下面 + Self.rulesPanelHeight 撑高。
    private static let collapsedIdealHeight: CGFloat = 470

    /// 评分规则面板区高度(展开时)。
    private static let rulesPanelHeight: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            // footer 区根据 isRulesExpanded 在两个 view 之间切换:
            // - 折叠:rulesFooterBar(50pt,触发条)
            // - 展开:scoringRulesPanel(280pt,完整面板)
            // 同一 VStack 槽位,不引入 overlay → content 高度永远不会
            // 因为面板展开而被向下推(dong4j 2026-06-21 v2 方案)。
            rulesSection
        }
        // sheet 高度根据 isRulesExpanded 动态变化。
        // maxHeight 给 .infinity 是为了让 macOS 允许用户手动拉大,
        // 但默认 idealHeight 已经够紧凑,不会自动留白。
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 820,
               minHeight: 520,
               idealHeight: isRulesExpanded ? Self.collapsedIdealHeight + Self.rulesPanelHeight : Self.collapsedIdealHeight,
               maxHeight: .infinity)
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

    /// footer 区——根据展开状态切换触发条 / 面板。
    @ViewBuilder
    private var rulesSection: some View {
        if isRulesExpanded, let snapshot {
            scoringRulesPanel(snapshot)
        } else {
            rulesFooterBar
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
        // alignment: .top —— 圆卡与右侧文字顶部平齐,
        // 避免 HStack 默认 center 让圆卡在视觉上"悬空"。
        //
        // v2（2026-06-21, dong4j 反馈"突出等级,弱化分数"）：
        // 圆环内"等级在上大写突出"+"分数在下小字弱化"。
        // 圆环本身：tint 色描边（2pt）+ 同色 0.08 opacity 浅填充,
        // 视觉更像一个"等级徽章"而非"分数表盘"。
        let rounded = Int(snapshot.overallScore.rounded())
        let cardSize: CGFloat = 96
        let tint = healthTint(snapshot.overallScore)

        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                // 双层圆环：外圈细描边 + 内圈超浅填充,营造"等级徽章"质感
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.18), tint.opacity(0.04)],
                            center: .center,
                            startRadius: 0,
                            endRadius: cardSize / 2
                        )
                    )
                Circle()
                    .stroke(tint.opacity(0.55), lineWidth: 2)
                VStack(spacing: -2) {
                    // 等级:大字 36pt + bold + tint 色,视觉中心
                    Text(verbatim: snapshot.grade)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(tint)
                    // 分数:小字 12pt + secondary 色,弱化
                    Text(verbatim: "\(rounded) 分")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: cardSize, height: cardSize)

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
        // 4 个 icon 统一走"容器型 fill"（circle / shield）,与 star.circle.fill、
        // checkmark.shield.fill 同一视觉重量;裸 fill（wrench / clipboard）在
        // 24×24 画布下会显得比右侧两个大(dong4j 2026-06-21 第三轮反馈)。
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            dimensionCard(title: "repoHealth.dimension.maintenance", score: snapshot.maintenanceScore, systemImage: "gearshape.circle.fill")
            dimensionCard(title: "repoHealth.dimension.popularity", score: snapshot.popularityScore, systemImage: "star.circle.fill")
            dimensionCard(title: "repoHealth.dimension.quality", score: snapshot.qualityScore, systemImage: "doc.circle.fill")
            dimensionCard(title: "repoHealth.dimension.security", score: snapshot.securityScore, systemImage: "checkmark.shield.fill")
        }
    }

    private func dimensionCard(title: LocalizedStringKey, score: Double, systemImage: String) -> some View {
        HStack(spacing: 10) {
            // SF Symbol line 风格 vs fill 风格混合使用时,line 风格自带描边
            // 在 16pt 下视觉重量明显偏小;4 张卡片混用时大小看起来不一致
            // (dong4j 2026-06-21 反馈)。统一用 fill 风格 + 24x24 画布 +
            // imageScale(.large) + symbolRenderingMode(.hierarchical) 让所有
            // symbol 走同一渲染路径,避免 baseline / 描边 / metric 差异。
            //
            // 命名约束:四个维度都用容器型 symbol（*.circle.fill / *.shield.fill）,
            // 避免裸 fill 与 circle/shield 混排时 bounding box 不一致。
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

            // Release 行:有 htmlUrl 时整行可点跳转 GitHub release 页面
            // (2026-06-21 dong4j 反馈);无值时退化为普通 metadataRow。
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
                .help("repoHealth.sources.openRelease")
            } else {
                metadataRow(
                    icon: "tag",
                    title: "repoHealth.sources.latestRelease",
                    value: payload?.latestReleaseTag ?? String.l10n("repoHealth.sources.missing")
                )
            }

            // OpenSSF 行:有聚合分时整行可点击,弹出非模态 popover 展示雷达图
            // (2026-06-21 dong4j 反馈);无值时退化为普通 metadataRow。
            // 视觉提示用 `chevron.right.circle`(与 Release 行的 `arrow.up.right.square`
            // 区分语义:Release 是「跳到外站」,这里是「就地展开面板」)。
            // 完整 checks 列表仍走 repo 详情头部 OpenSSFInlineBadge → OpenSSFScoreSheet,
            // popover 只做「瞄一眼分布」的轻量入口,避免一个指标在两个深度入口中重复。
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
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 底部触发条:仅在折叠态显示,展开态由 `scoringRulesPanel` 接管 footer 槽位。
    ///
    /// 设计要点(2026-06-21 v2):
    /// - 不再用 overlay 弹层,改用"footer 槽位"切换——同一 VStack 位置
    ///   根据 `isRulesExpanded` 在触发条和面板之间二选一,避免之前 overlay
    ///   路线带来的"展开时 content 区域被向下推形成大片空白"问题;
    /// - chevron 折叠时朝上(暗示"点我展开"),展开后此 view 不在视图中,
    ///   面板内自带 x 关闭按钮。
    /// - `.buttonStyle(.plain) + .focusEffectDisabled()` 遵守项目 UI 规范
    ///   (禁用 macOS 默认蓝色 focus ring,见 CLAUDE.md)。
    private var rulesFooterBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isRulesExpanded = true
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
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityHint("repoHealth.rules.a11y.expand")
    }

    /// 评分规则面板(展开时)。
    ///
    /// 由 `rulesSection` 在 footer 槽位渲染;高度由 `rulesPanelHeight` 控制。
    /// 顶部带一个 HStack:左标题 + 右 x 关闭按钮,展开后用户从这里关闭。
    /// 4 条规则图标按各自维度当前分数染色,与上方 dimensionGrid 卡片颜色一致。
    private func scoringRulesPanel(_ snapshot: RepoHealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部一行:标题 + x 关闭按钮
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
