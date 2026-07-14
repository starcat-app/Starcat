//
//  RAGWorkspaceInspector.swift
//  Starcat
//
//  知识库 RAG 工作台的引用、计划、索引和调试 Inspector。
//

import AppKit
import SwiftUI

struct RAGWorkspaceInspector: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var inspectorTab: RAGInspectorTab = .evidence
    @State private var expandedDebugTraceIDs: Set<UUID> = []
    @State private var expandedDebugEventIDs: Set<UUID> = []
    /// 正在展开 payload 的 event；未完成前禁用再次点击，避免「点两次」先展开后立刻折叠。
    @State private var pendingExpandDebugEventIDs: Set<UUID> = []
    @State private var expandedIndexIssueKind: RAGIndexIssueKind?
    @State private var hoveredIndexIssueKind: RAGIndexIssueKind?
    @State private var isKnowledgeRepositoryRowHovered = false
    @State private var isRetrievalScoreExplanationPresented = false
    @State private var isCitationChunkPopoverPresented = false
    /// 元数据体积大、引用 tab 优先看证据；默认折叠，需要时再展开。
    @State private var isKnowledgeMetadataExpanded = false
    /// Star Top10 是次级排行，默认折叠在元数据展开内容内部。
    @State private var isStarLeadersExpanded = false

    private static let inspectorContentInset: CGFloat = 14
    private static let indexRowTrailingAffordanceWidth: CGFloat = 16
    /// Matched chunk 预览行数；超出尾部省略，全文进 popover。
    private static let citationChunkPreviewLineLimit = 5

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    var body: some View {
        // 外层必须 leading：默认 center 会把标题整块居中，和下面左对齐正文错位。
        VStack(alignment: .leading, spacing: 0) {
            // 与中栏 answerHeader 同构（headline + caption + 上下 11pt），保证分割线水平对齐。
            // tabs 放在分割线下方，避免把右栏 header 撑高。
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("rag.workspace.inspector.title")
                        .font(ragFont(.headline, weight: .semibold))
                        .lineLimit(1)
                    Text("rag.workspace.inspector.subtitle")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                #if DEBUG
                // Debug 总开关放在「引用」右侧；开启后才露出「调试」tab。
                HStack(spacing: 5) {
                    Image(systemName: "ladybug")
                        .font(iconFont(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { viewModel.isDebugModeEnabled },
                        set: { enabled in
                            viewModel.isDebugModeEnabled = enabled
                            if enabled {
                                inspectorTab = .debug
                            } else if inspectorTab == .debug {
                                inspectorTab = .evidence
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
                .help("rag.workspace.debug.enabled")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("rag.workspace.debug.enabled")
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()

            // 等宽铺满：系统 segmented 会按文案长短挤段宽，中文短标签看起来和英文不一致。
            RAGInspectorTabBar(
                tabs: visibleInspectorTabs,
                selection: $inspectorTab,
                font: ragFont(.caption, weight: .medium)
            )
            .padding(.horizontal, Self.inspectorContentInset)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ScrollView {
                switch inspectorTab {
                case .evidence: evidenceInspector
                case .plan: planInspector
                case .index: indexInspector
                #if DEBUG
                case .debug: debugInspector
                #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
        .onChange(of: viewModel.citationFocusSequence) { _, _ in
            // 用 sequence 而不是 citation.id：同条芯片再点时 id 不变，仍需从调试等 tab 切回证据。
            if viewModel.selectedCitation != nil {
                inspectorTab = .evidence
            }
        }
        .onChange(of: viewModel.selectedCitation?.id) { _, _ in
            // 换引用时关掉旧全文，避免 popover 挂在错误分片上。
            isCitationChunkPopoverPresented = false
        }
    }

    /// 调试 tab 仅在 DEBUG 且开关打开时出现，避免未开启时占 segmented 宽度。
    var visibleInspectorTabs: [RAGInspectorTab] {
        #if DEBUG
        if viewModel.isDebugModeEnabled {
            return Array(RAGInspectorTab.allCases)
        }
        return RAGInspectorTab.allCases.filter { $0 != .debug }
        #else
        return Array(RAGInspectorTab.allCases)
        #endif
    }

    var evidenceInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            knowledgeBaseMetadataPanel

            // 元数据是面向整个知识库的事实，引用是本轮命中的证据；用分割线明确两者不能互相替代。
            Divider().padding(.vertical, 2)

            if allCitations.isEmpty {
                Text("rag.workspace.inspector.noCitations")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
                Text("rag.workspace.inspector.citations")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                // 手风琴：引用列表在上，点一条在该行下方展开细节。
                ForEach(allCitations) { citation in
                    let isExpanded = viewModel.selectedCitation?.id == citation.id
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            viewModel.toggleCitation(citation)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    RepoIdentityLabel(
                                        fullName: citation.repoFullName,
                                        avatarSize: 16,
                                        font: ragFont(.callout, weight: .semibold),
                                        spacing: 6,
                                        showAvatarBorder: false
                                    )
                                    // source 图标跟面包屑同排：一眼对来源类型，又不挤第一行 logo。
                                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                                        Image(systemName: citation.source.systemImageName)
                                            .font(iconFont(size: 11, weight: .semibold))
                                            .foregroundStyle(citation.source.tintColor)
                                        // 来源·路径合成单行：小字 + 尾部省略，避免侧栏窄时把 section 折成两行。
                                        (Text(citation.source.titleKey) + Text(" · \(citation.sectionTitle)"))
                                            .font(ragFont(.caption2))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(iconFont(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()

                        if isExpanded {
                            citationDetail(citation)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                        }
                    }
                    .background(
                        isExpanded
                            ? Color.accentColor.opacity(0.08)
                            : Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }

            if !viewModel.remoteBlocks.isEmpty {
                Divider().padding(.top, 4)
                Text("rag.workspace.inspector.remoteContext")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(viewModel.remoteBlocks, id: \.id) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.title)
                            .font(ragFont(.callout, weight: .semibold))
                        Text(block.errorMessage ?? block.content)
                            .font(ragFont(.caption))
                            .foregroundStyle(block.errorMessage == nil
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color.orange)
                            .lineLimit(6)
                        inspectorValue(
                            "rag.workspace.inspector.fetchedAt",
                            value: localizedTimestamp(block.fetchedAt)
                        )
                        if let url = block.sourceURL {
                            Link(destination: url) {
                                Label("rag.workspace.inspector.openGitHub", systemImage: "arrow.up.right.square")
                            }
                            .font(ragFont(.caption))
                        }
                    }
                    .padding(.vertical, 5)
                }
            }

            if !viewModel.historicalRemoteContextAudits.isEmpty {
                Divider().padding(.top, 4)
                Text("rag.workspace.inspector.remoteContext")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(viewModel.historicalRemoteContextAudits) { audit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(audit.title)
                            .font(ragFont(.callout, weight: .semibold))
                        if let errorMessage = audit.errorMessage {
                            Text(errorMessage)
                                .font(ragFont(.caption))
                                .foregroundStyle(.orange)
                        }
                        inspectorValue("rag.workspace.inspector.fetchedAt", value: audit.fetchedAt)
                        if let url = audit.sourceURL {
                            Link(destination: url) {
                                Label("rag.workspace.inspector.openGitHub", systemImage: "arrow.up.right.square")
                            }
                            .font(ragFont(.caption))
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(Self.inspectorContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: viewModel.selectedCitation?.id)
    }

    @ViewBuilder
    var knowledgeBaseMetadataPanel: some View {
        if let snapshot = viewModel.knowledgeBaseMetadataSnapshot {
            VStack(alignment: .leading, spacing: 0) {
                // 整行可点：chevron 只表达状态，不单独做触发区（见 UI-折叠展开-规范）。
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isKnowledgeMetadataExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isKnowledgeMetadataExpanded ? "chevron.down" : "chevron.right")
                            .font(ragFont(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Image(systemName: "cylinder.split.1x2")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("rag.workspace.inspector.metadata.title")
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(snapshot.generatedAt, format: .dateTime.hour().minute().second())
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(10)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if isKnowledgeMetadataExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("rag.workspace.inspector.metadata.subtitle")
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)

                        // 三列等分 + 居中：窄侧栏下短标签才不会左侧挤成一团、右侧空白。
                        HStack(spacing: 8) {
                            metadataStat("rag.workspace.inspector.metadata.projects", value: snapshot.projectCount)
                            metadataStat("rag.workspace.inspector.metadata.starred", value: snapshot.starredProjectCount)
                            metadataStat("rag.workspace.inspector.metadata.retained", value: snapshot.retainedAfterUnstarCount)
                        }

                        Divider()

                        metadataRow("rag.workspace.inspector.metadata.status", value: metadataDistribution(snapshot.statusCounts))
                        metadataRow(
                            "rag.workspace.inspector.metadata.tags",
                            value: "\(snapshot.taggedProjectCount) / \(snapshot.untaggedProjectCount) · \(snapshot.tagCount)"
                        )
                        metadataRow(
                            "rag.workspace.inspector.metadata.languages",
                            value: metadataDistribution(snapshot.topLanguages)
                        )
                        metadataRow(
                            "rag.workspace.inspector.metadata.activity",
                            value: "\(snapshot.addedInLast30DaysCount) / \(snapshot.pushedInLast30DaysCount)"
                        )
                        metadataRow(
                            "rag.workspace.inspector.metadata.index",
                            value: "\(snapshot.indexHealth.readyChunks) / \(snapshot.indexHealth.pendingChunks) / \(snapshot.indexHealth.failedChunks) / \(snapshot.indexHealth.staleChunks)"
                        )

                        if !snapshot.topStarredRepositories.isEmpty {
                            Divider()
                            starLeadersSection(snapshot.topStarredRepositories)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("rag.workspace.inspector.metadata.loading")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    /// Star Top10：嵌在元数据展开区内，自身默认折叠。
    @ViewBuilder
    private func starLeadersSection(_ repositories: [KnowledgeBaseMetadataSnapshot.TopRepository]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isStarLeadersExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isStarLeadersExpanded ? "chevron.down" : "chevron.right")
                        .font(ragFont(.caption2, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("rag.workspace.inspector.metadata.starLeaders")
                        .font(ragFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isStarLeadersExpanded {
                ForEach(Array(repositories.enumerated()), id: \.offset) { index, repository in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(ragFont(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(repository.fullName)
                            .font(ragFont(.caption, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(repository.stars, format: .number)
                            .font(ragFont(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func metadataStat(_ titleKey: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(value, format: .number)
                .font(ragFont(.headline, weight: .semibold, design: .rounded))
            Text(titleKey)
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    func metadataRow(_ titleKey: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titleKey)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(ragFont(.caption, weight: .medium))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    func metadataDistribution(_ counts: [KnowledgeBaseMetadataSnapshot.NamedCount]) -> String {
        counts.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
    }

    @ViewBuilder
    func citationDetail(_ citation: RAGCitation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            // 证据字段与「Matched chunk」同用 caption，避免 callout 值字号一截大一截小。
            VStack(alignment: .leading, spacing: 3) {
                Text("rag.workspace.inspector.source")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                Label {
                    Text(citation.source.titleKey)
                        .font(ragFont(.caption, weight: .semibold))
                } icon: {
                    Image(systemName: citation.source.systemImageName)
                        .font(iconFont(size: 11, weight: .semibold))
                        .foregroundStyle(citation.source.tintColor)
                }
            }
            citationField("rag.workspace.inspector.location", value: citation.sectionTitle)
            citationField("rag.workspace.inspector.matchType", value: citation.hitKind.rawValue)
            retrievalScoreValue(citation)
            if let vectorSimilarity = citation.vectorSimilarity {
                citationField(
                    "rag.workspace.inspector.vectorSimilarity",
                    value: String(format: "%.3f", locale: locale, vectorSimilarity)
                )
            }
            if let chunk = viewModel.selectedCitationChunk, viewModel.selectedCitation?.id == citation.id {
                if let createdAtLabel = chunkCreatedAtLabel(chunk) {
                    citationField("rag.workspace.inspector.chunkCreatedAt", value: createdAtLabel)
                }
                // 与综合检索分一致：info.circle 标明可点开 popover 看全文。
                Button {
                    isCitationChunkPopoverPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Text("rag.workspace.inspector.chunkPreview")
                        Image(systemName: "info.circle")
                            .font(iconFont(size: 11, weight: .medium))
                    }
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.inspector.chunkPreview.expand")
                citationChunkPreview(citation, chunk: chunk)
            }
            if citation.chunkID == nil {
                Label("rag.workspace.inspector.chunkMissing", systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Spacer()
                // logo-only：与知识库详情同源，文案降级为 help / accessibility。
                Button {
                    viewModel.openCitation(citation)
                } label: {
                    // App Icon 带玻璃外框，缩小时看不清；用 CompactMark 放大主体。
                    StarcatCompactMark(size: 16)
                        .squareLogoActionChrome()
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.inspector.citationStarcatDetail")
                .accessibilityLabel(Text("rag.workspace.inspector.citationStarcatDetail"))

                Button {
                    viewModel.openGitHub(citation)
                } label: {
                    // Devicons 经典 mark；template 以适配明暗主题。
                    Image("github")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                        .squareLogoActionChrome()
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.inspector.citationGitHub")
                .accessibilityLabel(Text("rag.workspace.inspector.citationGitHub"))
            }
        }
        .padding(.top, 2)
    }

    /// 最多 5 行预览；点击用 popover 看全文，避免点选文本时「字突然变多」。
    private func citationChunkPreview(_ citation: RAGCitation, chunk: RAGChunk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isCitationChunkPopoverPresented = true
            } label: {
                Text(chunk.content)
                    .font(ragFont(.caption))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(Self.citationChunkPreviewLineLimit)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("rag.workspace.inspector.chunkPreview.expand")
            .popover(isPresented: $isCitationChunkPopoverPresented, arrowEdge: .leading) {
                RAGCitationChunkPopoverContent(citation: citation, chunk: chunk)
            }

            if chunk.isTruncated {
                Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }
        }
    }

    var planInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan = viewModel.displayedQueryPlan {
                if plan.mode == .needsClarification {
                    // 澄清态没有可执行的检索词；展示 Planner 已校验过的追问，避免把空查询误称为优化结果。
                    planSection("rag.workspace.inspector.plan.questionUnderstanding") {
                        inspectorValue(
                            "rag.workspace.inspector.clarificationQuestion",
                            value: plan.clarificationQuestion ?? String.l10n("rag.workspace.inspector.clarificationFallback")
                        )
                        inspectorValue(
                            "rag.workspace.inspector.planStatus",
                            value: String.l10n("rag.workspace.inspector.planStatus.awaitingClarification")
                        )
                    }
                } else {
                    planSummary(plan)

                    planSection("rag.workspace.inspector.plan.questionUnderstanding") {
                        if let question = viewModel.displayedPlanQuestion, !question.isEmpty {
                            inspectorValue("rag.workspace.inspector.plan.originalQuestion", value: question)
                        }
                        let semanticQuery = resolvedSemanticQuery(plan)
                        if !semanticQuery.isEmpty {
                            inspectorValue("rag.workspace.inspector.semanticQuery", value: semanticQuery)
                        }
                        if !plan.userVisiblePlan.planningNotes.isEmpty {
                            Text("rag.workspace.inspector.planNotes")
                                .font(ragFont(.caption))
                                .foregroundStyle(.secondary)
                            ForEach(plan.userVisiblePlan.planningNotes, id: \.self) { note in
                                Label(note, systemImage: "checkmark.circle")
                                    .font(ragFont(.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    planSection("rag.workspace.inspector.plan.executionStrategy") {
                        planMetricRow(
                            "rag.workspace.inspector.planMode",
                            value: localizedPlanMode(plan.mode)
                        )
                        let filters = localizedPlanFilters(plan.filters)
                        if filters.isEmpty {
                            planMetricRow(
                                "rag.workspace.inspector.plan.filters",
                                value: String.l10n("rag.workspace.inspector.plan.filters.none")
                            )
                        } else {
                            RAGFlowLayout(spacing: 7) {
                                ForEach(filters, id: \.self) { filter in
                                    planChip(filter)
                                }
                            }
                        }
                        if let sort = plan.sort {
                            inspectorValue(
                                "rag.workspace.inspector.planSort",
                                value: localizedPlanSort(sort)
                            )
                        }
                        if let candidateLimit = plan.candidateLimit {
                            inspectorValue(
                                "rag.workspace.inspector.planCandidateLimit",
                                value: String(
                                    format: String.l10n("rag.workspace.inspector.planCandidateLimitFormat"),
                                    candidateLimit
                                )
                            )
                        }
                        if let analytics = plan.analytics {
                            planMetricRow(
                                "rag.workspace.inspector.plan.analytics",
                                value: localizedAnalytics(analytics)
                            )
                        }
                    }

                    planSection("rag.workspace.inspector.plan.networkPlan") {
                        planMetricRow(
                            "rag.workspace.inspector.plan.liveEvidence",
                            value: plan.requiresLiveEvidence
                                ? String.l10n("rag.workspace.inspector.plan.liveEvidence.required")
                                : String.l10n("rag.workspace.inspector.plan.liveEvidence.notRequired")
                        )
                        if plan.remoteContextRequests.isEmpty, plan.webSearchRequests.isEmpty {
                            planMetricRow(
                                "rag.workspace.inspector.plan.networkStatus",
                                value: String.l10n("rag.workspace.inspector.plan.networkStatus.none")
                            )
                        }
                        ForEach(Array(plan.remoteContextRequests.enumerated()), id: \.offset) { _, request in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(remoteResourceName(request.resource), systemImage: "network")
                                    .font(ragFont(.callout, weight: .semibold))
                                if !request.query.isEmpty {
                                    Text(request.query)
                                        .font(ragFont(.caption))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                }
                                Text(request.reason)
                                    .font(ragFont(.caption))
                                    .foregroundStyle(.secondary)
                                Text(String(
                                    format: String.l10n("rag.workspace.inspector.planRemoteBudgetFormat"),
                                    request.maxRepos,
                                    request.perRepoLimit
                                ))
                                .font(ragFont(.caption2))
                                .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(plan.webSearchRequests) { request in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("rag.workspace.inspector.plan.webSearch", systemImage: "globe")
                                    .font(ragFont(.callout, weight: .semibold))
                                Text(request.query)
                                    .font(ragFont(.caption))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Text(request.reason)
                                    .font(ragFont(.caption))
                                    .foregroundStyle(.secondary)
                                Text(String(
                                    format: String.l10n("rag.workspace.inspector.plan.webSearchBudgetFormat"),
                                    request.maxResults
                                ))
                                .font(ragFont(.caption2))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let retrieval = viewModel.displayedRetrievalSnapshot {
                        planSection("rag.workspace.inspector.plan.retrievalFunnel") {
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.candidates",
                                value: localizedInteger(retrieval.candidateRepoCount)
                            )
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.keyword",
                                value: localizedFunnelCount(
                                    raw: retrieval.keywordRawCount,
                                    accepted: retrieval.keywordAcceptedCount
                                )
                            )
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.vector",
                                value: localizedFunnelCount(
                                    raw: retrieval.vectorRawCount,
                                    accepted: retrieval.vectorAcceptedCount
                                )
                            )
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.fusion",
                                value: String(
                                    format: String.l10n("rag.workspace.inspector.plan.retrieval.fusionFormat"),
                                    retrieval.fusionUniqueCount,
                                    retrieval.rankingFilteredCount
                                )
                            )
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.rerank",
                                value: localizedRerank(retrieval)
                            )
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.result",
                                value: String(
                                    format: String.l10n("rag.workspace.inspector.plan.retrieval.resultFormat"),
                                    retrieval.finalChildHitCount,
                                    retrieval.bundleCount
                                )
                            )
                            if let outcome = retrieval.outcome {
                                planMetricRow(
                                    "rag.workspace.inspector.plan.retrieval.outcome",
                                    value: localizedRetrievalOutcome(outcome)
                                )
                            }
                            if let settings = retrieval.settings {
                                planMetricRow(
                                    "rag.workspace.inspector.plan.retrieval.sources",
                                    value: localizedSources(settings.enabledSources)
                                )
                                planMetricRow(
                                    "rag.workspace.inspector.plan.retrieval.limits",
                                    value: String(
                                        format: String.l10n("rag.workspace.inspector.plan.retrieval.limitsFormat"),
                                        settings.finalEvidenceChunkLimit,
                                        settings.perRepositoryEvidenceLimit,
                                        settings.evidenceTokenBudget.formatted()
                                    )
                                )
                            }
                        }
                    } else if plan.mode == .guidedDiscovery {
                        planSection("rag.workspace.inspector.plan.retrievalFunnel") {
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.outcome",
                                value: String.l10n("rag.workspace.inspector.plan.retrieval.guided")
                            )
                        }
                    }

                    if let usage = viewModel.displayedContextUsage {
                        planSection("rag.workspace.inspector.plan.contextBudget") {
                            HStack(alignment: .firstTextBaseline) {
                                Text(String(
                                    format: String.l10n("rag.workspace.context.percentFull"),
                                    Int((usage.usageRatio * 100).rounded())
                                ))
                                .font(ragFont(.caption, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(String(
                                    format: String.l10n("rag.workspace.context.tokensSummary"),
                                    contextTokenText(usage.inputTokens),
                                    contextTokenText(usage.windowTokens)
                                ))
                                .font(ragFont(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            }
                            ProgressView(value: usage.usageRatio)
                                .progressViewStyle(.linear)
                                .controlSize(.mini)
                                .tint(.accentColor)
                            ForEach(activeContextSegments(usage)) { kind in
                                planMetricRow(
                                    LocalizedStringKey(kind.displayKey),
                                    value: contextTokenText(usage.tokenCount(for: kind))
                                )
                            }
                            planMetricRow(
                                "rag.workspace.context.reservedOutput",
                                value: contextTokenText(usage.reservedOutputTokens)
                            )
                        }
                    }
                }
            } else {
                Text("rag.workspace.inspector.noPlan")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Self.inspectorContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func planSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    func planSummary(_ plan: RAGQueryPlan) -> some View {
        RAGFlowLayout(spacing: 7) {
            planChip(String.l10n("rag.workspace.inspector.plan.scope.knowledgeBase"))
            planChip(localizedPlanMode(plan.mode))
            if plan.requiresLiveEvidence {
                planChip(String.l10n("rag.workspace.inspector.plan.liveEvidence.required"))
            }
        }
    }

    func planChip(_ value: String) -> some View {
        Text(value)
            .font(ragFont(.caption, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    func planMetricRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    func resolvedSemanticQuery(_ plan: RAGQueryPlan) -> String {
        let validated = plan.semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !validated.isEmpty { return validated }
        return plan.userVisiblePlan.semantic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func localizedPlanFilters(_ filters: RAGRepoFilter) -> [String] {
        var values: [String] = []
        if let status = filters.status {
            values.append(localizedFilter("rag.workspace.inspector.plan.filter.status", value: localizedRepoStatus(status)))
        }
        if !filters.languages.isEmpty {
            values.append(localizedFilter("rag.workspace.inspector.plan.filter.languages", value: filters.languages.joined(separator: ", ")))
        }
        if !filters.tags.isEmpty {
            values.append(localizedFilter("rag.workspace.inspector.plan.filter.tags", value: filters.tags.joined(separator: ", ")))
        }
        appendNumericFilter(&values, key: "rag.workspace.inspector.plan.filter.stars", minimum: filters.minStars, maximum: filters.maxStars)
        appendNumericFilter(&values, key: "rag.workspace.inspector.plan.filter.forks", minimum: filters.minForks, maximum: filters.maxForks)
        if !filters.licenses.isEmpty {
            values.append(localizedFilter("rag.workspace.inspector.plan.filter.licenses", value: filters.licenses.joined(separator: ", ")))
        }
        if let includeArchived = filters.includeArchived {
            values.append(localizedFilter(
                "rag.workspace.inspector.plan.filter.archived",
                value: localizedBoolean(includeArchived)
            ))
        }
        if let includeForks = filters.includeForks {
            values.append(localizedFilter(
                "rag.workspace.inspector.plan.filter.forkRepos",
                value: localizedBoolean(includeForks)
            ))
        }
        appendDateFilter(&values, key: "rag.workspace.inspector.plan.filter.starredAt", after: filters.starredAfter, before: filters.starredBefore)
        appendDateFilter(&values, key: "rag.workspace.inspector.plan.filter.libraryUpdatedAt", after: filters.libraryUpdatedAfter, before: filters.libraryUpdatedBefore)
        appendDateFilter(&values, key: "rag.workspace.inspector.plan.filter.repoCreatedAt", after: filters.repoCreatedAfter, before: filters.repoCreatedBefore)
        appendDateFilter(&values, key: "rag.workspace.inspector.plan.filter.pushedAt", after: filters.pushedAfter, before: filters.pushedBefore)
        return values
    }

    func localizedFilter(_ key: String, value: String) -> String {
        String(format: String.l10n("rag.workspace.inspector.plan.filterFormat"), String.l10n(key), value)
    }

    func appendNumericFilter(_ values: inout [String], key: String, minimum: Int?, maximum: Int?) {
        guard minimum != nil || maximum != nil else { return }
        let range: String
        switch (minimum, maximum) {
        case let (minimum?, maximum?): range = "\(localizedInteger(minimum))–\(localizedInteger(maximum))"
        case let (minimum?, nil): range = "≥ \(localizedInteger(minimum))"
        case let (nil, maximum?): range = "≤ \(localizedInteger(maximum))"
        case (nil, nil): return
        }
        values.append(localizedFilter(key, value: range))
    }

    func appendDateFilter(_ values: inout [String], key: String, after: Date?, before: Date?) {
        guard after != nil || before != nil else { return }
        let dateStyle = Date.FormatStyle(date: .numeric, time: .omitted).locale(locale)
        let range: String
        switch (after, before) {
        case let (after?, before?): range = "\(after.formatted(dateStyle))–\(before.formatted(dateStyle))"
        case let (after?, nil): range = "≥ \(after.formatted(dateStyle))"
        case let (nil, before?): range = "≤ \(before.formatted(dateStyle))"
        case (nil, nil): return
        }
        values.append(localizedFilter(key, value: range))
    }

    func localizedBoolean(_ value: Bool) -> String {
        String.l10n(value ? "rag.workspace.inspector.plan.boolean.yes" : "rag.workspace.inspector.plan.boolean.no")
    }

    func localizedRepoStatus(_ status: RepoStatus) -> String {
        switch status {
        case .unread: return String.l10n("repo.status.unread")
        case .read: return String.l10n("repo.status.read")
        case .using: return String.l10n("repo.status.using")
        }
    }

    func localizedAnalytics(_ analytics: KnowledgeBaseAnalyticsPlan) -> String {
        String(
            format: String.l10n("rag.workspace.inspector.plan.analyticsFormat"),
            localizedAnalyticsDimension(analytics.dimension),
            localizedAnalyticsMeasure(analytics.measure),
            localizedAnalyticsDirection(analytics.direction),
            analytics.limit
        )
    }

    func localizedAnalyticsDimension(_ dimension: KnowledgeBaseAnalyticsDimension?) -> String {
        switch dimension {
        case .repository: return String.l10n("rag.workspace.inspector.plan.analytics.dimension.repository")
        case .language: return String.l10n("rag.workspace.inspector.plan.analytics.dimension.language")
        case .status: return String.l10n("rag.workspace.inspector.plan.analytics.dimension.status")
        case .tag: return String.l10n("rag.workspace.inspector.plan.analytics.dimension.tag")
        case nil: return String.l10n("rag.workspace.inspector.plan.analytics.dimension.all")
        }
    }

    func localizedAnalyticsMeasure(_ measure: KnowledgeBaseAnalyticsMeasure) -> String {
        switch measure {
        case .count: return String.l10n("rag.workspace.inspector.plan.analytics.measure.count")
        case .maxStars: return String.l10n("rag.workspace.inspector.plan.analytics.measure.maxStars")
        case .averageStars: return String.l10n("rag.workspace.inspector.plan.analytics.measure.averageStars")
        case .maxForks: return String.l10n("rag.workspace.inspector.plan.analytics.measure.maxForks")
        case .averageForks: return String.l10n("rag.workspace.inspector.plan.analytics.measure.averageForks")
        }
    }

    func localizedAnalyticsDirection(_ direction: KnowledgeBaseAnalyticsSortDirection) -> String {
        switch direction {
        case .ascending: return String.l10n("rag.workspace.inspector.plan.analytics.direction.ascending")
        case .descending: return String.l10n("rag.workspace.inspector.plan.analytics.direction.descending")
        }
    }

    func localizedFunnelCount(raw: Int, accepted: Int) -> String {
        String(format: String.l10n("rag.workspace.inspector.plan.retrieval.funnelFormat"), raw, accepted)
    }

    func localizedRerank(_ snapshot: RAGRetrievalSnapshot) -> String {
        switch snapshot.rerankState {
        case .completed:
            return String(
                format: String.l10n("rag.workspace.inspector.plan.retrieval.rerank.completedFormat"),
                snapshot.rerankedCount,
                snapshot.rerankCandidateCount
            )
        case .failedFallback: return String.l10n("rag.workspace.inspector.plan.retrieval.rerank.fallback")
        case .skipped: return String.l10n("rag.workspace.inspector.plan.retrieval.rerank.skipped")
        case .disabled, nil: return String.l10n("rag.workspace.inspector.plan.retrieval.rerank.disabled")
        }
    }

    func localizedRetrievalOutcome(_ outcome: RAGRetrievalDiagnostics.Outcome) -> String {
        switch outcome {
        case .completed: return String.l10n("rag.workspace.inspector.plan.retrieval.outcome.completed")
        case .noCandidates: return String.l10n("rag.workspace.inspector.plan.retrieval.outcome.noCandidates")
        case .noReadyChunks: return String.l10n("rag.workspace.inspector.plan.retrieval.outcome.noReadyChunks")
        case .sourcesDisabled: return String.l10n("rag.workspace.inspector.plan.retrieval.outcome.sourcesDisabled")
        case .skippedStructured: return String.l10n("rag.workspace.inspector.plan.retrieval.outcome.skippedStructured")
        case .noEvidence: return String.l10n("rag.workspace.inspector.plan.retrieval.outcome.noEvidence")
        }
    }

    func localizedSources(_ sources: Set<RAGChunkSource>) -> String {
        sources.sorted { $0.rawValue < $1.rawValue }.map { source in
            switch source {
            case .readme: return String.l10n("rag.browser.source.readme")
            case .notes: return String.l10n("rag.browser.source.notes")
            case .summary: return String.l10n("rag.browser.source.summary")
            case .metadata: return String.l10n("rag.browser.source.metadata")
            }
        }.joined(separator: ", ")
    }

    func activeContextSegments(_ usage: RAGContextUsage) -> [RAGContextUsageSegmentKind] {
        RAGContextUsageSegmentKind.allCases.filter {
            $0 != .reservedOutput && usage.tokenCount(for: $0) > 0
        }
    }

    func contextTokenText(_ tokens: Int) -> String {
        if tokens >= 1_000 {
            return (Double(tokens) / 1_000)
                .formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + "K"
        }
        return localizedInteger(tokens)
    }

    func localizedInteger(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    func localizedPlanMode(_ mode: RAGQueryMode) -> String {
        switch mode {
        case .semanticOnly: return String.l10n("rag.workspace.inspector.planMode.semanticOnly")
        case .filteredSemantic: return String.l10n("rag.workspace.inspector.planMode.filteredSemantic")
        case .structuredOnly: return String.l10n("rag.workspace.inspector.planMode.structuredOnly")
        case .guidedDiscovery: return String.l10n("rag.workspace.inspector.planMode.guidedDiscovery")
        case .needsClarification: return String.l10n("rag.workspace.inspector.planMode.needsClarification")
        }
    }

    func localizedPlanConfidence(_ confidence: RAGQueryPlanConfidence) -> String {
        switch confidence {
        case .high: return String.l10n("rag.workspace.inspector.confidence.high")
        case .medium: return String.l10n("rag.workspace.inspector.confidence.medium")
        case .needsClarification: return String.l10n("rag.workspace.inspector.confidence.needsClarification")
        }
    }

    func localizedPlanSort(_ sort: RAGRepoSort) -> String {
        let field: String
        switch sort.field {
        case .stars: field = String.l10n("rag.workspace.inspector.planSort.stars")
        case .forks: field = String.l10n("rag.workspace.inspector.planSort.forks")
        case .pushedAt: field = String.l10n("rag.workspace.inspector.planSort.pushedAt")
        case .repoCreatedAt: field = String.l10n("rag.workspace.inspector.planSort.repoCreatedAt")
        case .libraryUpdatedAt: field = String.l10n("rag.workspace.inspector.planSort.libraryUpdatedAt")
        case .starredAt: field = String.l10n("rag.workspace.inspector.planSort.starredAt")
        }
        let direction = switch sort.direction {
        case .ascending: String.l10n("rag.workspace.inspector.planSort.ascending")
        case .descending: String.l10n("rag.workspace.inspector.planSort.descending")
        }
        return String(format: String.l10n("rag.workspace.inspector.planSortFormat"), field, direction)
    }

    var indexInspector: some View {
        VStack(alignment: .leading, spacing: 13) {
            knowledgeRepositoryRow
            coverageRow("rag.workspace.status.readyChunks", value: "\(viewModel.indexCoverage.readyChunks)", color: .green)
            indexIssueRow(.pending, value: "\(viewModel.indexCoverage.pendingChunks)", color: .orange)
            indexIssueRow(.failed, value: "\(viewModel.indexCoverage.failedChunks)", color: .red)
            indexIssueRow(.stale, value: "\(viewModel.indexCoverage.staleChunks)", color: .purple)
            embeddingCoverageProgress
            Divider()
            VStack(alignment: .trailing, spacing: 13) {
                indexProgressLabel
                // icon-only：统一走 SyncIconButton，文案保留为 tooltip / accessibility。
                SyncIconButton(
                    isRefreshing: viewModel.isIndexing,
                    disabled: viewModel.isIndexing,
                    font: .caption,
                    frameSize: 18,
                    tooltip: String.l10n("rag.workspace.index.rebuild")
                ) {
                    viewModel.rebuildIndex()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Self.inspectorContentInset)
    }

    #if DEBUG
    /// 「调试」tab 内容：开关已在 header，这里只展示已开启后的 trace 列表。
    var debugInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Spacer()
                // 单条导出走行内按钮；顶部只保留清空整条会话 Debug。
                Button {
                    viewModel.clearDebugTraces()
                    expandedDebugTraceIDs = []
                    expandedDebugEventIDs = []
                    pendingExpandDebugEventIDs = []
                } label: {
                    Image(systemName: "trash")
                        .font(iconFont(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("rag.workspace.debug.clear")
                .accessibilityLabel(Text("rag.workspace.debug.clear"))
                .disabled(viewModel.debugTraces.isEmpty)
            }

            if viewModel.debugTraces.isEmpty {
                Text("rag.workspace.debug.empty")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.debugTraces.sorted { $0.startedAt > $1.startedAt }) { trace in
                    let isExpanded = expandedDebugTraceIDs.contains(trace.id)
                    VStack(alignment: .leading, spacing: 8) {
                        // 整行可折叠；导出叠在 chevron 左侧独立点击，避免误触展开。
                        Button {
                            toggleDebugTraceExpansion(trace)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: debugTraceCategoryIcon(trace.category))
                                    .font(iconFont(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                    .accessibilityHidden(true)
                                // 英文标题更长：不够宽时只截标题，不挤换时间戳。
                                Text(debugTraceCategoryKey(trace.category))
                                    .font(ragFont(.caption, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(0)
                                Spacer(minLength: 4)
                                // 固定 `yyyy-MM-dd HH:mm` 单行；避免窄侧栏把日期/时间折成两行。
                                Text(debugTraceCompactTimestamp(trace.startedAt))
                                    .font(ragFont(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .layoutPriority(1)
                                Image(systemName: debugTraceStateIcon(trace.state))
                                    .font(iconFont(size: 11, weight: .semibold))
                                    .foregroundStyle(debugTraceStateColor(trace.state))
                                    .fixedSize()
                                    .layoutPriority(1)
                                    .help(debugTraceStateKey(trace.state))
                                // 给导出留位，chevron 始终贴行尾。
                                Color.clear
                                    .frame(width: 14)
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(ragFont(.caption2, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .overlay(alignment: .trailing) {
                            Button {
                                viewModel.exportDebugTrace(trace)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(iconFont(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help("rag.workspace.debug.export")
                            // 14 导出 + 6 间距，叠在 clear slot 上，chevron 仍最右。
                            .padding(.trailing, 18)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, isExpanded ? 0 : 10)

                        if isExpanded {
                            // 子 stage 相对父行轻缩进即可，过大空白会浪费窄侧栏。
                            let stepDurations = debugEventStepDurations(for: trace.events)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(trace.events) { event in
                                    debugEventRow(
                                        event,
                                        stepDurationSeconds: stepDurations[event.id] ?? event.elapsedSeconds
                                    )
                                }
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                        }
                    }
                    // 浅底 + separator 细边框：同一 trace 折叠/展开时边界都清晰，不强于侧栏其它卡片。
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    )
                }
            }
        }
        .padding(Self.inspectorContentInset)
    }

    /// 单个 stage 行：默认只显示标题/本步耗时/复制；展开后才挂载 payload，避免大段文本拖垮侧栏。
    func debugEventRow(
        _ event: RAGDebugEvent,
        stepDurationSeconds: TimeInterval
    ) -> some View {
        let isExpanded = expandedDebugEventIDs.contains(event.id)
        let isExpandPending = pendingExpandDebugEventIDs.contains(event.id)
        // Rerank 在检索完成后才拿到远端耗时；其 Trace 行必须显示服务的真实耗时，不能显示
        // 同一批 Debug event 的累计时间差。
        let displayedDuration = event.rerankPayload?.diagnostics.elapsedSeconds ?? stepDurationSeconds
        return VStack(alignment: .leading, spacing: 7) {
            // 与父行一致：chevron 贴最右；复制叠在其左侧独立点击。
            Button {
                toggleDebugEventExpansion(event)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: debugStageIcon(event.stage))
                        .font(iconFont(size: 11, weight: .semibold))
                        .foregroundStyle(debugStageColor(event.stage))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(debugStageKey(event.stage))
                        .font(ragFont(.caption, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(String(format: String.l10n("rag.workspace.debug.elapsedFormat"), locale: locale, displayedDuration))
                        .font(ragFont(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("rag.workspace.debug.stepDuration.help")
                    // 给复制留位；展开中用小转圈替代右侧 chevron。
                    Color.clear
                        .frame(width: 10)
                    if isExpandPending {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(ragFont(.caption2, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            // Prompt / 返回等大段正文挂载前禁止再点，否则会 toggle 成「展开又立刻折叠」。
            .disabled(isExpandPending)
            .opacity(isExpandPending ? 0.72 : 1)
            .overlay(alignment: .trailing) {
                // 复制独立于折叠。字号必须明显小于 body 默认 Symbol：
                // `doc.on.doc` 同字号也比标题行 `checkmark.circle.fill` 显大，
                // 与 AI 气泡复制一致用 9pt + 10×10 锁死，避免 feedback 成功勾再次撑开。
                CopyFeedbackButton(
                    providesContent: { event.renderedPayload() },
                    tooltip: "rag.workspace.debug.copy"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(iconFont(size: 9, weight: .regular))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                        .fixedSize()
                }
                // 10 复制位 + 6 间距，叠在 clear slot 上，chevron / 转圈仍最右。
                .padding(.trailing, 18)
            }

            if isExpanded {
                debugPayloadText(for: event)
                    .font(ragFont(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .onAppear {
                        finishPendingDebugEventExpand(event.id)
                    }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 仅检索诊断拥有稳定的结构化指标；Prompt、模型响应等自由文本可能含端口、模型版本或参数，
    /// 不应因其中出现数字而被误标为检索关键信息。
    private func debugPayloadText(for event: RAGDebugEvent) -> Text {
        let payload = event.renderedPayload()
        guard event.retrievalPayload != nil else { return Text(payload) }
        return highlightedDebugPayload(payload)
    }

    /// 数值是检索配置和漏斗判读的关键线索；在保留等宽调试文本可复制性的同时，用系统强调色
    /// 标出阈值、上限、Token 预算、召回和过滤计数，避免用户在长行里肉眼搜索数字。
    private func highlightedDebugPayload(_ payload: String) -> Text {
        let numberPattern = #"(?:\d+\.\d+|\d+)"#
        var result = Text("")
        var cursor = payload.startIndex

        while let range = payload.range(of: numberPattern, options: .regularExpression, range: cursor..<payload.endIndex) {
            result = result + Text(String(payload[cursor..<range.lowerBound]))
            result = result + Text(String(payload[range]))
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            cursor = range.upperBound
        }
        return result + Text(String(payload[cursor...]))
    }

    /// 由累计 `elapsedSeconds` 差分得到本步耗时；首条相对 ask 起点。
    func debugEventStepDurations(for events: [RAGDebugEvent]) -> [UUID: TimeInterval] {
        var durations: [UUID: TimeInterval] = [:]
        var previousElapsed: TimeInterval = 0
        for event in events {
            durations[event.id] = max(0, event.elapsedSeconds - previousElapsed)
            previousElapsed = event.elapsedSeconds
        }
        return durations
    }

    /// 父级 trace 折叠：收起时同步清掉内部 stage 展开态。
    private func toggleDebugTraceExpansion(_ trace: RAGDebugTrace) {
        let isExpanded = expandedDebugTraceIDs.contains(trace.id)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            if isExpanded {
                expandedDebugTraceIDs.remove(trace.id)
                let eventIDs = Set(trace.events.map(\.id))
                expandedDebugEventIDs.subtract(eventIDs)
                pendingExpandDebugEventIDs.subtract(eventIDs)
            } else {
                expandedDebugTraceIDs.insert(trace.id)
            }
        }
    }

    /// 折叠可立刻切；展开先加 pending 锁，等 payload `onAppear`（或超时兜底）再解锁。
    private func toggleDebugEventExpansion(_ event: RAGDebugEvent) {
        let isExpanded = expandedDebugEventIDs.contains(event.id)
        if isExpanded {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                expandedDebugEventIDs.remove(event.id)
            }
            pendingExpandDebugEventIDs.remove(event.id)
            return
        }

        guard !pendingExpandDebugEventIDs.contains(event.id) else { return }
        pendingExpandDebugEventIDs.insert(event.id)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            expandedDebugEventIDs.insert(event.id)
        }

        // 极端超大 payload 若 `onAppear` 迟迟不来，2s 后仍解锁，避免行永久禁用。
        let eventID = event.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            finishPendingDebugEventExpand(eventID)
        }
    }

    private func finishPendingDebugEventExpand(_ eventID: UUID) {
        pendingExpandDebugEventIDs.remove(eventID)
    }

    func debugStageKey(_ stage: RAGDebugEvent.Stage) -> LocalizedStringKey {
        switch stage {
        case .request: return "rag.workspace.debug.stage.request"
        case .plannerPrompt: return "rag.workspace.debug.stage.plannerPrompt"
        case .plannerResponse: return "rag.workspace.debug.stage.plannerResponse"
        case .plan: return "rag.workspace.debug.stage.plan"
        case .candidates: return "rag.workspace.debug.stage.candidates"
        case .structuredAnalytics: return "rag.workspace.debug.stage.structuredAnalytics"
        case .rerank: return "rag.workspace.debug.stage.rerank"
        case .retrieval: return "rag.workspace.debug.stage.retrieval"
        case .remoteRequest: return "rag.workspace.debug.stage.remoteRequest"
        case .remoteResponse: return "rag.workspace.debug.stage.remoteResponse"
        case .remoteContext: return "rag.workspace.debug.stage.remoteContext"
        case .prompt: return "rag.workspace.debug.stage.prompt"
        case .response: return "rag.workspace.debug.stage.response"
        case .compressionPrompt: return "rag.workspace.debug.stage.compressionPrompt"
        case .compressionResponse: return "rag.workspace.debug.stage.compressionResponse"
        case .titlePrompt: return "rag.workspace.debug.stage.titlePrompt"
        case .titleResponse: return "rag.workspace.debug.stage.titleResponse"
        case .failure: return "rag.workspace.debug.stage.failure"
        }
    }

    /// Debug stage → SF Symbol；按「请求 / Prompt / 返回 / 检索 / 远程 / 失败」语义分组，便于扫读。
    func debugStageIcon(_ stage: RAGDebugEvent.Stage) -> String {
        switch stage {
        case .request:
            return "paperplane"
        case .plannerPrompt:
            return "brain"
        case .plannerResponse:
            return "text.bubble"
        case .plan:
            return "list.bullet.rectangle"
        case .candidates:
            return "building.2"
        case .structuredAnalytics:
            return "chart.bar.xaxis"
        case .rerank:
            return "arrow.up.arrow.down.circle"
        case .retrieval:
            return "magnifyingglass"
        case .remoteRequest:
            return "network"
        case .remoteResponse:
            return "icloud.and.arrow.down"
        case .remoteContext:
            return "globe"
        case .prompt:
            return "text.quote"
        case .response:
            return "text.alignleft"
        case .compressionPrompt:
            return "arrow.down.right.and.arrow.up.left"
        case .compressionResponse:
            return "doc.text"
        case .titlePrompt:
            return "character.textbox"
        case .titleResponse:
            return "textformat"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    func debugStageColor(_ stage: RAGDebugEvent.Stage) -> Color {
        switch stage {
        case .failure:
            return .orange
        default:
            return .secondary
        }
    }

    func debugTraceCategoryKey(_ category: RAGDebugTraceCategory) -> LocalizedStringKey {
        switch category {
        case .questionAnswer: return "rag.workspace.debug.category.questionAnswer"
        case .conversationTitle: return "rag.workspace.debug.category.conversationTitle"
        }
    }

    func debugTraceCategoryIcon(_ category: RAGDebugTraceCategory) -> String {
        switch category {
        case .questionAnswer: return "books.vertical"
        case .conversationTitle: return "textformat"
        }
    }

    func debugTraceStateKey(_ state: RAGDebugTrace.State) -> LocalizedStringKey {
        switch state {
        case .running: return "rag.workspace.debug.state.running"
        case .completed: return "rag.workspace.debug.state.completed"
        case .failed: return "rag.workspace.debug.state.failed"
        case .cancelled: return "rag.workspace.debug.state.cancelled"
        }
    }

    /// 调试标题行时间：固定 `yyyy-MM-dd HH:mm`，不跟系统本地化长格式。
    func debugTraceCompactTimestamp(_ date: Date) -> String {
        Self.debugTraceTimestampFormatter.string(from: date)
    }

    func debugTraceStateIcon(_ state: RAGDebugTrace.State) -> String {
        switch state {
        case .running: return "clock"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    func debugTraceStateColor(_ state: RAGDebugTrace.State) -> Color {
        switch state {
        case .running: return .secondary
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private static let debugTraceTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    #endif

    func inspectorValue(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(ragFont(.callout, weight: .semibold))
                .textSelection(.enabled)
        }
    }

    /// 引用详情字段：与 Matched chunk 同 caption 字号，仅证据展开区使用。
    func citationField(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(ragFont(.caption, weight: .semibold))
                .textSelection(.enabled)
        }
    }

    /// 融合分只负责检索排序，无法被直接解读为百分比；点击该行在独立 popover 中解释当前命中方式的公式。
    func retrievalScoreValue(_ citation: RAGCitation) -> some View {
        Button {
            isRetrievalScoreExplanationPresented.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("rag.workspace.inspector.retrievalScore")
                    Image(systemName: "info.circle")
                        .font(iconFont(size: 11, weight: .medium))
                }
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
                Text(String(format: "%.3f", locale: locale, citation.score))
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.workspace.inspector.retrievalScore.help")
        .popover(isPresented: $isRetrievalScoreExplanationPresented, arrowEdge: .leading) {
            retrievalScoreExplanation(citation)
        }
    }

    /// 公式随命中方式变化；特别是 hybrid 不能误用 vector-only 公式解释。
    func retrievalScoreExplanation(_ citation: RAGCitation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                // 与设置页 / 占位符 popover 同款：标题旁默认色图标，标明「公式说明」。
                Image(systemName: "function")
                    .font(iconFont(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("rag.workspace.inspector.retrievalScore.explanationTitle")
                    .font(ragFont(.headline, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if let scoreBreakdown = citation.scoreBreakdown {
                Text("rag.workspace.inspector.retrievalScore.actualCalculation")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(actualScoreFormula(scoreBreakdown))
                    .font(ragFont(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("rag.workspace.inspector.retrievalScore.actualCalculationUnavailable")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }

            Text("rag.workspace.inspector.retrievalScore.formulaLabel")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(retrievalScoreFormulaKey(for: citation.hitKind))
                .font(ragFont(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                scoreExplanationRow("rag.workspace.inspector.retrievalScore.rank")
                if citation.hitKind != .keyword {
                    scoreExplanationRow("rag.workspace.inspector.retrievalScore.cosine")
                    scoreExplanationRow("rag.workspace.inspector.retrievalScore.vectorWeight")
                }
                if citation.hitKind != .vector {
                    scoreExplanationRow("rag.workspace.inspector.retrievalScore.keyword")
                }
                scoreExplanationRow("rag.workspace.inspector.retrievalScore.sourceWeight")
                scoreExplanationRow("rag.workspace.inspector.retrievalScore.preferBoost")
            }
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .appLocaleEnvironment()
    }

    func retrievalScoreFormulaKey(for hitKind: RAGHitKind) -> LocalizedStringKey {
        switch hitKind {
        case .vector:
            "rag.workspace.inspector.retrievalScore.formula.vector"
        case .keyword:
            "rag.workspace.inspector.retrievalScore.formula.keyword"
        case .hybrid:
            "rag.workspace.inspector.retrievalScore.formula.hybrid"
        }
    }

    func scoreExplanationRow(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(ragFont(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 用持久化的融合快照拼出代入式，绝不根据 UI 上已四舍五入的最终分数反推排名或加成。
    func actualScoreFormula(_ score: RAGScoreBreakdown) -> String {
        let final = formattedScoreValue(score.finalScore, precision: 3)
        let rrfConstant = formattedScoreValue(score.rrfConstant, precision: 0)
        let sourceWeight = formattedScoreValue(score.sourceWeight, precision: 2)
        let boost = formattedScoreValue(score.preferredRepoBoost, precision: 2)

        switch score.hitKind {
        case .vector:
            return "\(final) = (\(formattedScoreValue(score.vectorWeight, precision: 2)) / (\(rrfConstant) + \(score.vectorRank ?? 0)) + \(formattedScoreValue(score.vectorSimilarity ?? 0, precision: 3)) × \(formattedScoreValue(score.vectorScoreWeight, precision: 2))) × \(sourceWeight) + \(boost)"
        case .keyword:
            return "\(final) = (\(formattedScoreValue(score.keywordWeight, precision: 2)) / (\(rrfConstant) + \(score.keywordRank ?? 0)) + \(formattedScoreValue(score.keywordScore ?? 0, precision: 3)) × \(formattedScoreValue(score.keywordScoreWeight, precision: 2))) × \(sourceWeight) + \(boost)"
        case .hybrid:
            return "\(final) = (\(formattedScoreValue(score.keywordWeight, precision: 2)) / (\(rrfConstant) + \(score.keywordRank ?? 0)) + \(formattedScoreValue(score.keywordScore ?? 0, precision: 3)) × \(formattedScoreValue(score.keywordScoreWeight, precision: 2)) + \(formattedScoreValue(score.vectorWeight, precision: 2)) / (\(rrfConstant) + \(score.vectorRank ?? 0)) + \(formattedScoreValue(score.vectorSimilarity ?? 0, precision: 3)) × \(formattedScoreValue(score.vectorScoreWeight, precision: 2))) × \(sourceWeight) + \(boost)"
        }
    }

    func formattedScoreValue(_ value: Double, precision: Int) -> String {
        String(format: "%.\(precision)f", locale: locale, value)
    }

    var knowledgeRepositoryRow: some View {
        Button {
            viewModel.showKnowledgeBrowser(presentingWindow: NSApp.keyWindow)
        } label: {
            HStack(spacing: 9) {
                Circle().fill(Color.blue).frame(width: 8, height: 8)
                // 索引统计行用 caption，与证据 tab 的 inspector 密度对齐，避免 callout 抢主阅读层级。
                Text("rag.workspace.status.repos").font(ragFont(.caption))
                Spacer()
                indexRowValue("\(viewModel.indexCoverage.indexedRepoCount)/\(viewModel.indexCoverage.knowledgeRepoCount)")
                indexRowTrailingAffordance(systemImage: "arrow.up.right.square")
            }
            .contentShape(Rectangle())
            .background(
                isKnowledgeRepositoryRowHovered ? Color.accentColor.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .help("rag.browser.open")
        .onHover { isKnowledgeRepositoryRowHovered = $0 }
    }

    func coverageRow(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(ragFont(.caption))
            Spacer()
            indexRowValue(value)
            indexRowTrailingAffordance()
        }
    }

    func indexIssueRow(_ kind: RAGIndexIssueKind, value: String, color: Color) -> some View {
        let isExpanded = expandedIndexIssueKind == kind
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if isExpanded {
                    expandedIndexIssueKind = nil
                } else {
                    expandedIndexIssueKind = kind
                    Task { await viewModel.loadIndexIssueChunks(kind) }
                }
            } label: {
                HStack(spacing: 9) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(indexIssueTitle(kind)).font(ragFont(.caption))
                    Spacer()
                    indexRowValue(value)
                    indexRowTrailingAffordance(systemImage: isExpanded ? "chevron.down" : "chevron.right")
                }
                .contentShape(Rectangle())
                .background(
                    hoveredIndexIssueKind == kind ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)
            .onHover { hoveredIndexIssueKind = $0 ? kind : nil }

            if isExpanded {
                indexIssueDrawer(kind, color: color)
            }
        }
    }

    func indexRowValue(_ value: String) -> some View {
        Text(value)
            .font(ragFont(.caption, weight: .semibold, design: .monospaced))
            .frame(minWidth: 44, alignment: .trailing)
    }

    @ViewBuilder
    func indexRowTrailingAffordance(systemImage: String? = nil) -> some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(iconFont(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.indexRowTrailingAffordanceWidth)
        } else {
            Color.clear
                .frame(width: Self.indexRowTrailingAffordanceWidth)
        }
    }

    @ViewBuilder
    func indexIssueDrawer(_ kind: RAGIndexIssueKind, color: Color) -> some View {
        let chunks = viewModel.indexIssueChunks(for: kind)
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isLoadingIndexIssue(kind), chunks.isEmpty {
                ProgressView().controlSize(.small)
            } else if chunks.isEmpty {
                Text("rag.workspace.index.issues.empty")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chunks, id: \.id) { chunk in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(viewModel.knowledgeRepositoryName(for: chunk.repoId))
                                .font(ragFont(.caption, weight: .semibold))
                            Text(indexIssueSourceTitle(chunk.source))
                                .font(ragFont(.caption2))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(chunk.sectionPath.isEmpty ? chunk.title : chunk.sectionPath)
                                .font(ragFont(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        indexIssueReason(kind, chunk: chunk)
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            if viewModel.hasMoreIndexIssueChunks(kind) {
                Button("rag.workspace.index.issues.loadMore") {
                    Task { await viewModel.loadIndexIssueChunks(kind, append: true) }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(color)
            }
        }
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    func indexIssueReason(_ kind: RAGIndexIssueKind, chunk: RAGChunk) -> some View {
        switch kind {
        case .pending:
            Text("rag.workspace.index.issues.pendingReason")
        case .failed:
            Text(chunk.embeddingError?.isEmpty == false ? chunk.embeddingError! : String.l10n("rag.workspace.index.issues.failedReason"))
        case .stale:
            Text("rag.workspace.index.issues.staleReason")
            Text("\(chunk.embeddingModel ?? "-") → \(viewModel.embeddingModel)")
        }
    }

    func indexIssueTitle(_ kind: RAGIndexIssueKind) -> LocalizedStringKey {
        switch kind {
        case .pending: return "rag.workspace.status.pendingChunks"
        case .failed: return "rag.workspace.status.failedChunks"
        case .stale: return "rag.workspace.status.staleChunks"
        }
    }

    func indexIssueSourceTitle(_ source: RAGChunkSource) -> LocalizedStringKey {
        source.titleKey
    }

    @ViewBuilder
    var indexProgressLabel: some View {
        if let summary = viewModel.indexRefreshSummary {
            VStack(alignment: .leading, spacing: 13) {
                if let completedAt = summary.completedAt {
                    indexProgressLine(
                        "rag.workspace.index.lastCompleted",
                        value: completedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)),
                        color: .green
                    )
                } else {
                    // 首次刷新尚无成功记录也保留整行，避免阶段统计在开始后突然下移。
                    indexProgressLine(
                        "rag.workspace.index.lastCompleted",
                        value: "—",
                        color: .secondary
                    )
                }
                indexProgressLine("rag.workspace.index.readmeShort", value: "\(summary.readmesProcessed)/\(summary.totalRepos)", color: .blue)
                indexProgressLine("rag.workspace.index.sourceBuild", value: "\(summary.sourceReposProcessed)/\(summary.totalRepos)", color: .orange)
                indexProgressLine("rag.workspace.index.embedding", value: embeddingProgressValue(for: summary), color: .green)
            }
            .font(ragFont(.caption2))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    /// 刷新历史改为纵向阶段清单，避免仓库数与分片数并排时被误读为同一口径。
    func indexProgressLine(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    /// 对用户展示全库向量覆盖，而不是本轮待处理队列；这样无新增分片的刷新仍会显示 20,281/20,281。
    func embeddingProgressValue(for summary: RAGIndexRefreshSummary) -> String {
        guard summary.totalChunksAtEmbedding > 0 else {
            return "\(viewModel.indexCoverage.readyChunks)/\(viewModel.indexCoverage.totalChunks)"
        }
        return "\(summary.embeddingReadyChunks)/\(summary.totalChunksAtEmbedding)"
    }

    /// 常显的整体向量覆盖率。embedding 过程中使用 builder 的批次快照即时推进，完成后回到数据库聚合的真实覆盖率。
    var embeddingCoverageProgress: some View {
        let liveProgress = viewModel.indexEmbeddingProgress
        let progress = liveProgress.map {
            (readyChunks: $0.processedChunks, totalChunks: $0.totalChunks)
        } ?? displayedEmbeddingCoverage
        let title: LocalizedStringKey = liveProgress == nil
            ? "rag.workspace.index.embeddingCoverage"
            : "rag.workspace.index.embeddingCurrent"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(progress.readyChunks.formatted()) / \(progress.totalChunks.formatted())")
                    .font(ragFont(.caption2))
                    .monospacedDigit()
                    .foregroundStyle(liveProgress == nil ? Color.green : Color.accentColor)
                    .contentTransition(.numericText())
            }
            ProgressView(
                value: Double(progress.readyChunks),
                total: Double(max(progress.totalChunks, 1))
            )
            .progressViewStyle(.linear)
            .controlSize(.mini)
            .tint(liveProgress == nil ? .green : Color.accentColor)
            // 保持原有整行长度，只压缩视觉高度，避免用宽度改变索引区的既有布局。
            .scaleEffect(x: 1, y: 0.5, anchor: .center)
            .frame(maxWidth: .infinity)
            .frame(height: 7)
            .animation(.easeInOut(duration: 0.18), value: progress.readyChunks)
        }
    }

    /// 非 embedding 阶段只表达全库健康度；进入 embedding 后由上方本轮进度覆盖，避免混淆两种口径。
    var displayedEmbeddingCoverage: (readyChunks: Int, totalChunks: Int) {
        (viewModel.indexCoverage.readyChunks, viewModel.indexCoverage.totalChunks)
    }
    func localizedTimestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// 引用详情里展示分片入库时间；ISO 解析失败则跳过，不堆原始字符串。
    func chunkCreatedAtLabel(_ chunk: RAGChunk) -> String? {
        let raw = chunk.createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let date = ISO8601DateFormatter.shared.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
        else { return nil }
        return localizedTimestamp(date)
    }

    /// 右侧「证据」列表：按相关度降序，同分再按仓库名稳定排序。
    var allCitations: [RAGCitation] {
        var seen = Set<UUID>()
        return viewModel.messages
            .flatMap(\.citations)
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.repoFullName.localizedStandardCompare($1.repoFullName) == .orderedAscending
            }
    }
    func remoteResourceName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        case .externalWeb: return "Web Search"
        }
    }
}

/// 引用侧栏等宽 tab：铺满可用宽度，中英文标签长短不再改变段宽观感。
private struct RAGInspectorTabBar: View {
    let tabs: [RAGInspectorTab]
    @Binding var selection: RAGInspectorTab
    let font: Font

    @Environment(\.starcatReduceMotion) private var reduceMotion

    private static let horizontalInset: CGFloat = 3
    private static let dividerWidth: CGFloat = 1
    private static let controlHeight: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            // 由确定的父宽度一次性分配每段宽度，避免多个 `.infinity` 子项反向参与
            // HStack 的尺寸协商；后者在 macOS 26 的 SwiftUI 布局引擎中会造成主线程自旋。
            let dividerCount = max(tabs.count - 1, 0)
            let contentWidth = max(
                0,
                proxy.size.width
                    - Self.horizontalInset * 2
                    - CGFloat(dividerCount) * Self.dividerWidth
            )
            let tabWidth = tabs.isEmpty ? 0 : contentWidth / CGFloat(tabs.count)

            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    Button {
                        selection = tab
                    } label: {
                        Text(tab.titleKey)
                            .font(font)
                            .lineLimit(1)
                            .frame(width: tabWidth, height: Self.controlHeight - Self.horizontalInset * 2)
                            .foregroundStyle(selection == tab ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selection == tab ? Color.accentColor : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])

                    if index < tabs.count - 1 {
                        Rectangle()
                            .fill(showsDivider(before: index + 1) ? Color.primary.opacity(0.18) : .clear)
                            .frame(width: Self.dividerWidth, height: 14)
                    }
                }
            }
            .padding(Self.horizontalInset)
        }
        .frame(height: Self.controlHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
    }

    /// 仅在相邻两个未选中段之间画竖线，与系统 segmented 分隔习惯一致。
    private func showsDivider(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return selection != tabs[index - 1] && selection != tabs[index]
    }
}
