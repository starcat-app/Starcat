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
                                Image(systemName: citation.source.systemImageName)
                                    .font(iconFont(size: 12, weight: .semibold))
                                    .foregroundStyle(citation.source.tintColor)
                                    .frame(width: 14, alignment: .center)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    RepoIdentityLabel(
                                        fullName: citation.repoFullName,
                                        avatarSize: 16,
                                        font: ragFont(.callout, weight: .semibold),
                                        spacing: 6,
                                        showAvatarBorder: false
                                    )
                                    // 来源·路径合成单行：小字 + 尾部省略，避免侧栏窄时把 section 折成两行。
                                    (Text(citation.source.titleKey) + Text(" · \(citation.sectionTitle)"))
                                        .font(ragFont(.caption2))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
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
                citationChunkPreview(chunk)
            }
            if citation.chunkID == nil {
                Label("rag.workspace.inspector.chunkMissing", systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("rag.workspace.inspector.citationStarcatDetail") { viewModel.openCitation(citation) }
                Button("rag.workspace.inspector.citationGitHub") { viewModel.openGitHub(citation) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    /// 最多 5 行预览；点击用 popover 看全文，避免点选文本时「字突然变多」。
    private func citationChunkPreview(_ chunk: RAGChunk) -> some View {
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
                citationChunkFullPopover(chunk)
            }

            if chunk.isTruncated {
                Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func citationChunkFullPopover(_ chunk: RAGChunk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("rag.workspace.inspector.chunkPreview")
                .font(ragFont(.callout, weight: .semibold))
                .foregroundStyle(.primary)

            ScrollView {
                Text(chunk.content)
                    .font(ragFont(.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)

            if chunk.isTruncated {
                Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .appLocaleEnvironment()
    }

    var planInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan = viewModel.queryPlan {
                inspectorValue("rag.workspace.inspector.planMode", value: localizedPlanMode(plan.mode))
                if plan.mode == .needsClarification {
                    // 澄清态没有可执行的检索词；展示 Planner 已校验过的追问，避免把空查询误称为优化结果。
                    inspectorValue(
                        "rag.workspace.inspector.clarificationQuestion",
                        value: plan.clarificationQuestion ?? String.l10n("rag.workspace.inspector.clarificationFallback")
                    )
                    inspectorValue(
                        "rag.workspace.inspector.planStatus",
                        value: String.l10n("rag.workspace.inspector.planStatus.awaitingClarification")
                    )
                } else {
                    inspectorValue("rag.workspace.inspector.semanticQuery", value: plan.semanticQuery)
                    inspectorValue("rag.workspace.inspector.confidence", value: localizedPlanConfidence(plan.confidence))
                }
                if !plan.userVisiblePlan.chips.isEmpty {
                    RAGFlowLayout(spacing: 7) {
                        ForEach(plan.userVisiblePlan.chips, id: \.self) { chip in
                            Text(chip)
                                .font(ragFont(.caption, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                if !plan.remoteContextRequests.isEmpty {
                    Divider()
                    ForEach(plan.remoteContextRequests, id: \.resource) { request in
                        Label(remoteResourceName(request.resource), systemImage: "network")
                            .font(ragFont(.callout, weight: .semibold))
                        Text(request.reason)
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)
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

    func localizedPlanMode(_ mode: RAGQueryMode) -> String {
        switch mode {
        case .semanticOnly: return String.l10n("rag.workspace.inspector.planMode.semanticOnly")
        case .filteredSemantic: return String.l10n("rag.workspace.inspector.planMode.filteredSemantic")
        case .structuredOnly: return String.l10n("rag.workspace.inspector.planMode.structuredOnly")
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

    var indexInspector: some View {
        VStack(alignment: .leading, spacing: 13) {
            knowledgeRepositoryRow
            coverageRow("rag.workspace.status.readyChunks", value: "\(viewModel.indexCoverage.readyChunks)", color: .green)
            indexIssueRow(.pending, value: "\(viewModel.indexCoverage.pendingChunks)", color: .orange)
            indexIssueRow(.failed, value: "\(viewModel.indexCoverage.failedChunks)", color: .red)
            indexIssueRow(.stale, value: "\(viewModel.indexCoverage.staleChunks)", color: .purple)
            Divider()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Spacer()
                    indexProgressLabel
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                Button {
                    viewModel.rebuildIndex()
                } label: {
                    HStack(spacing: 6) {
                        rebuildIndexIcon
                        Text("rag.workspace.index.rebuild")
                    }
                }
                .disabled(viewModel.isIndexing)
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
                CopyFeedbackButton(
                    providesContent: { viewModel.debugTraceText },
                    tooltip: "rag.workspace.debug.copyAll"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
                .disabled(viewModel.debugTraces.isEmpty)
                Button("rag.workspace.debug.clear") {
                    viewModel.clearDebugTraces()
                    expandedDebugTraceIDs = []
                    expandedDebugEventIDs = []
                    pendingExpandDebugEventIDs = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.debugTraces.isEmpty)
            }

            if viewModel.debugTraces.isEmpty {
                Text("rag.workspace.debug.empty")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.debugTraces.sorted { $0.startedAt < $1.startedAt }) { trace in
                    let isExpanded = expandedDebugTraceIDs.contains(trace.id)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                    if isExpanded {
                                        expandedDebugTraceIDs.remove(trace.id)
                                        // 收起外层时清掉内部展开，下次进来仍默认折叠。
                                        let eventIDs = Set(trace.events.map(\.id))
                                        expandedDebugEventIDs.subtract(eventIDs)
                                        pendingExpandDebugEventIDs.subtract(eventIDs)
                                    } else {
                                        expandedDebugTraceIDs.insert(trace.id)
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .font(ragFont(.caption2, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                        .fixedSize()
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
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()

                            // 导出独立于折叠，避免点图标误触发展开。
                            Button {
                                viewModel.exportDebugTrace(trace)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(iconFont(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .fixedSize()
                            .help("rag.workspace.debug.export")
                        }

                        if isExpanded {
                            // Stage 默认折叠：外层展开只渲染标题行，payload 点开后再进视图树。
                            // 右侧秒数是本步耗时（相对上一条），不是从 ask 开始的累计时间。
                            let stepDurations = debugEventStepDurations(for: trace.events)
                            ForEach(trace.events) { event in
                                debugEventRow(
                                    event,
                                    stepDurationSeconds: stepDurations[event.id] ?? event.elapsedSeconds
                                )
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(Self.inspectorContentInset)
    }

    /// 单个 stage 行：默认只显示标题/本步耗时/复制；展开后才挂载 payload，避免大段文本拖垮侧栏。
    func debugEventRow(_ event: RAGDebugEvent, stepDurationSeconds: TimeInterval) -> some View {
        let isExpanded = expandedDebugEventIDs.contains(event.id)
        let isExpandPending = pendingExpandDebugEventIDs.contains(event.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    toggleDebugEventExpansion(event)
                } label: {
                    HStack(spacing: 6) {
                        // 展开中用小转圈替代 chevron，提示「已接收点击、正在挂载正文」。
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
                        Text(debugStageKey(event.stage))
                            .font(ragFont(.caption, weight: .semibold))
                        Spacer(minLength: 4)
                        Text(String(format: String.l10n("rag.workspace.debug.elapsedFormat"), locale: locale, stepDurationSeconds))
                            .font(ragFont(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("rag.workspace.debug.stepDuration.help")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                // Prompt / 返回等大段正文挂载前禁止再点，否则会 toggle 成「展开又立刻折叠」。
                .disabled(isExpandPending)
                .opacity(isExpandPending ? 0.72 : 1)

                // 复制独立于折叠，折叠态也能直接拷整段 payload。
                CopyFeedbackButton(
                    providesContent: { event.payload },
                    tooltip: "rag.workspace.debug.copy"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
            }

            if isExpanded {
                Text(event.payload)
                    .font(ragFont(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .onAppear {
                        finishPendingDebugEventExpand(event.id)
                    }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
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
        case .plan: return "rag.workspace.debug.stage.plan"
        case .candidates: return "rag.workspace.debug.stage.candidates"
        case .retrieval: return "rag.workspace.debug.stage.retrieval"
        case .remoteContext: return "rag.workspace.debug.stage.remoteContext"
        case .prompt: return "rag.workspace.debug.stage.prompt"
        case .response: return "rag.workspace.debug.stage.response"
        case .titlePrompt: return "rag.workspace.debug.stage.titlePrompt"
        case .titleResponse: return "rag.workspace.debug.stage.titleResponse"
        case .failure: return "rag.workspace.debug.stage.failure"
        }
    }

    func debugTraceCategoryKey(_ category: RAGDebugTraceCategory) -> LocalizedStringKey {
        switch category {
        case .questionAnswer: return "rag.workspace.debug.category.questionAnswer"
        case .conversationTitle: return "rag.workspace.debug.category.conversationTitle"
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
            Text("rag.workspace.inspector.retrievalScore.explanationTitle")
                .font(ragFont(.headline, weight: .semibold))
                .foregroundStyle(.primary)

            if let scoreBreakdown = citation.scoreBreakdown {
                Text("rag.workspace.inspector.retrievalScore.actualCalculation")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(actualScoreFormula(scoreBreakdown))
                    .font(ragFont(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.60)
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
                .lineLimit(1)
                .minimumScaleFactor(0.68)
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
    var rebuildIndexIcon: some View {
        // 与旁边按钮文案对齐：默认继承 control 字号会偏大，收到 caption。
        if reduceMotion {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .symbolEffect(.rotate, options: .repeating, isActive: viewModel.isIndexing)
        }
    }

    @ViewBuilder
    var indexProgressLabel: some View {
        if let summary = viewModel.indexRefreshSummary {
            HStack(spacing: 5) {
                if let completedAt = summary.completedAt {
                    Text(completedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.18), value: completedAt)
                    Text(verbatim: "|").foregroundStyle(.secondary)
                }
                indexProgressSegment("rag.workspace.index.readmeShort", value: "\(summary.readmesProcessed)/\(summary.totalRepos)", color: .blue)
                Text(verbatim: "|").foregroundStyle(.secondary)
                indexProgressSegment("rag.workspace.index.chunksShort", value: "\(summary.chunksProcessed)/\(summary.totalRepos)", color: .orange)
            }
            .font(ragFont(.caption2))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            EmptyView()
        }
    }

    func indexProgressSegment(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
            Text(value).monospacedDigit()
        }
        .foregroundStyle(color)
    }
    func localizedTimestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
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
                            .minimumScaleFactor(0.82)
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
