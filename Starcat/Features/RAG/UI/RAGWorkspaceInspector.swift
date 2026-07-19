//
//  RAGWorkspaceInspector.swift
//  Starcat
//
//  知识库 RAG 工作台的引用、计划、索引和调试 Inspector。
//

import AppKit
import SwiftUI

/// 检索漏斗的 popover 入口。一个阶段只打开对应的事实列表，不把 Debug JSON 直接暴露给用户。
private enum RAGRetrievalDetailTarget: String, Identifiable {
    case candidates
    case keyword
    case semantic
    case fusion
    case rerank
    case finalEvidence

    var id: String { rawValue }
}

/// 检索详情胶囊只用系统语义色的浅底与描边；正文保持 primary，明暗主题均有足够对比度。
private enum RetrievalDetailPillTone {
    case retrievalScore
    case vectorSimilarity
    case rerankScore
    case success
    case warning
    case danger
    case neutral

    var color: Color {
        switch self {
        case .retrievalScore: return .accentColor
        case .vectorSimilarity: return .indigo
        case .rerankScore: return .purple
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        case .neutral: return .gray
        }
    }
}

struct RAGWorkspaceInspector: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.ragSettingsNavigation) private var settingsNavigation

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var inspectorTab: RAGInspectorTab = .evidence
    @State private var expandedDebugTraceIDs: Set<UUID> = []
    @State private var expandedDebugEventIDs: Set<UUID> = []
    /// 正在展开 payload 的 event；未完成前禁用再次点击，避免「点两次」先展开后立刻折叠。
    @State private var pendingExpandDebugEventIDs: Set<UUID> = []
    /// 已在后台整理完成的正文快照。主线程只消费分块结果，不再同步生成整段 payload。
    @State private var debugPayloadPresentations: [UUID: RAGDebugPayloadPresentation] = [:]
    /// 正在后台准备的展开项；与 generation 配合，折叠后到达的旧结果不能重新撑开正文。
    @State private var loadingDebugPayloadIDs: Set<UUID> = []
    @State private var debugPayloadLoadGenerations: [UUID: UUID] = [:]
    /// 清空会删除当前会话落盘的 Debug JSON，必须先让用户确认数据范围。
    @State private var isClearDebugTracesConfirmationPresented = false
    @State private var expandedIndexIssueKind: RAGIndexIssueKind?
    @State private var hoveredIndexIssueKind: RAGIndexIssueKind?
    /// 待处理 / 失败 / 过期共用同一套列表行 hover，ID 只在当前展开抽屉内生效。
    @State private var hoveredIndexIssueChunkID: Int64?
    @State private var hoveredIndexBuildStageID: String?
    @State private var isKnowledgeRepositoryRowHovered = false
    @State private var isKnowledgeMetadataRowHovered = false
    @State private var hoveredDebugTraceID: UUID?
    /// 光标悬停的 Debug stage；与父 trace 行共用轻量 accent hover 反馈。
    @State private var hoveredDebugEventID: UUID?
    /// 光标悬停的引用行；用于给列表加 hover 高亮，展开态优先级更高。
    @State private var hoveredCitationID: UUID?
    /// 引用是证据 Inspector 的主内容，首次进入默认展开；正文引用跳转也会主动展开。
    @State private var isCitationsExpanded = true
    @State private var isCitationsSectionHovered = false
    /// 网络证据通常只用于核验实时来源，默认收起，避免历史记录挤占引用列表。
    @State private var isNetworkExpanded = false
    @State private var isNetworkSectionHovered = false
    /// 网络记录与引用卡片同为可展开证据行；ID 加 live/history 前缀避免两类来源碰撞。
    @State private var expandedNetworkItemID: String?
    @State private var hoveredNetworkItemID: String?
    @State private var isRetrievalScoreExplanationPresented = false
    @State private var isCitationChunkPopoverPresented = false
    @State private var isRepoContextXMLPopoverPresented = false
    /// 大型 XML 创建 popover 内容会有短暂延迟；打开完成前锁住入口，避免双击被系统解释为随即关闭。
    @State private var isRepoContextXMLPopoverOpening = false
    @State private var retrievalDetailTarget: RAGRetrievalDetailTarget?
    /// 元数据体积大、引用 tab 优先看证据；默认折叠，需要时再展开。
    @State private var isKnowledgeMetadataExpanded = false
    /// Star Top10 是次级排行，默认折叠在元数据展开内容内部。
    @State private var isStarLeadersExpanded = false

    private static let inspectorContentInset: CGFloat = 14
    private static let indexRowTrailingAffordanceWidth: CGFloat = 16
    /// 索引统计行内边距：hover 蓝条必须盖住完整点击区，不能只贴文字基线显得过扁。
    /// 目标单行约 30–34pt（DESIGN Sidebar / Rail Row），与 caption 行高 + 上下 6pt 对齐。
    private static let indexRowHorizontalPadding: CGFloat = 8
    private static let indexRowVerticalPadding: CGFloat = 6
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
                // 图标只与 headline 同行对齐；若跟 title+caption 整块 center，视觉上会漂到 Context 上方。
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 8) {
                        // 多层来源叠成上下文：比 doc.on.doc 更贴「本轮组装进回答的多路来源」语义。
                        // 注意使用当前 macOS 可用的 SF Symbol；不可用 symbol 会只占位、不绘制图标。
                        Image(systemName: "square.stack.3d.down.right.fill")
                            .font(iconFont(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text("rag.workspace.inspector.title")
                            .font(ragFont(.headline, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text("rag.workspace.inspector.subtitle")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 26)
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

            ScrollViewReader { proxy in
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
                .onChange(of: viewModel.citationFocusSequence) { _, _ in
                    focusSelectedCitation(using: proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
        .onChange(of: viewModel.selectedCitation?.id) { _, _ in
            // 换引用时关掉旧全文，避免 popover 挂在错误分片上。
            isCitationChunkPopoverPresented = false
            isRepoContextXMLPopoverPresented = false
            isRepoContextXMLPopoverOpening = false
        }
        .onChange(of: viewModel.selectedConversationID) { _, _ in
            // 展示快照复制了 Debug payload；切会话时必须连同 generation 一起释放，
            // 否则旧任务回调和旧正文会在窗口级 State 中持续占用内存。
            resetDebugExpansionState()
        }
        #if DEBUG
        .alert("rag.workspace.debug.clear.confirm.title", isPresented: $isClearDebugTracesConfirmationPresented) {
            Button("common.cancel", role: .cancel) {}
            Button("rag.workspace.debug.clear", role: .destructive) {
                viewModel.clearDebugTraces()
                resetDebugExpansionState()
            }
        } message: {
            Text("rag.workspace.debug.clear.confirm.message")
        }
        #endif
    }

    /// 底部芯片 / 证据列表点选驱动展开；先切到引用 tab，再等布局提交后定位目标行。
    /// 直接同步 `scrollTo` 时，目标可能仍在计划/索引 tab 中尚未挂载，滚动请求会被静默丢弃。
    /// 正文蓝色 S1 只弹窗，不走本路径。
    private func focusSelectedCitation(using proxy: ScrollViewProxy) {
        guard let citationID = viewModel.selectedCitation?.id else { return }
        inspectorTab = .evidence
        isCitationsExpanded = true

        Task { @MainActor in
            await Task.yield()
            // 用户快速连点不同引用时，只执行最后一次仍然有效的定位，避免视口跳回旧目标。
            guard viewModel.selectedCitation?.id == citationID else { return }
            if reduceMotion {
                proxy.scrollTo(citationID, anchor: .top)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(citationID, anchor: .top)
                }
            }
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
        // 引用可能跨多轮持续累积；根栈必须按视口懒挂载，避免切回证据 tab 时同步创建
        // 全部头像、hover 与 overlay 视图，阻塞主线程首帧。
        LazyVStack(alignment: .leading, spacing: 10) {
            knowledgeBaseMetadataPanel

            // 元数据是知识库范围快照；下方只展示回答实际保留 marker 的引用。
            Divider().padding(.vertical, 2)

            if allCitations.isEmpty {
                Text("rag.workspace.inspector.noCitations")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
                // 与元数据同构：整行点击、右侧 chevron 和 hover 底色保持一致。
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isCitationsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.bubble.fill")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("rag.workspace.inspector.citations")
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        // 与「元数据」右侧时间同构：折叠态也能一眼看到本轮引用条数。
                        Text(localizedInteger(allCitations.count))
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCitationsExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        isCitationsSectionHovered ? Color.accentColor.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .onHover { isCitationsSectionHovered = $0 }
                .onDisappear { isCitationsSectionHovered = false }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isCitationsSectionHovered
                )

                if isCitationsExpanded {
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
                            // 展开态优先用 accent 底；未展开时光标悬停给一层浅 accent 反馈，其余保持默认底。
                            isExpanded
                                ? Color.accentColor.opacity(0.08)
                                : (hoveredCitationID == citation.id
                                    ? Color.accentColor.opacity(0.045)
                                    : Color(nsColor: .textBackgroundColor).opacity(0.55)),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            // 悬停时描一圈淡 accent 边，强化「可点击 + 当前聚焦」的视觉线索。
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    hoveredCitationID == citation.id && !isExpanded
                                        ? Color.accentColor.opacity(0.35)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                        .onHover { isHovering in
                            if reduceMotion {
                                hoveredCitationID = isHovering ? citation.id : (hoveredCitationID == citation.id ? nil : hoveredCitationID)
                            } else {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    hoveredCitationID = isHovering ? citation.id : (hoveredCitationID == citation.id ? nil : hoveredCitationID)
                                }
                            }
                        }
                        // ScrollViewReader 必须定位整张卡片；展开后仍以标题顶部作为稳定锚点。
                        .id(citation.id)
                    }
                }
            }

            if !viewModel.remoteBlocks.isEmpty || !viewModel.historicalRemoteContextAudits.isEmpty {
                Divider().padding(.top, 4)
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isNetworkExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("rag.workspace.inspector.network")
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        // 本轮 live + 历史审计合计；折叠态先看到总量，再决定是否展开核对。
                        Text(localizedInteger(
                            viewModel.remoteBlocks.count
                                + viewModel.historicalRemoteContextAudits.count
                        ))
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isNetworkExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        isNetworkSectionHovered ? Color.accentColor.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .onHover { isNetworkSectionHovered = $0 }
                .onDisappear { isNetworkSectionHovered = false }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isNetworkSectionHovered
                )

                if isNetworkExpanded {
                    ForEach(Array(viewModel.remoteBlocks.enumerated()), id: \.element.id) { rowIndex, block in
                        networkContextRow(
                            id: "live:\(block.id)",
                            title: block.title,
                            detail: block.errorMessage ?? block.content,
                            isError: block.errorMessage != nil,
                            fetchedAt: localizedTimestamp(block.fetchedAt),
                            sourceURL: block.sourceURL,
                            rowIndex: rowIndex
                        )
                    }

                    ForEach(
                        Array(viewModel.historicalRemoteContextAudits.enumerated()),
                        id: \.element.id
                    ) { rowIndex, audit in
                        networkContextRow(
                            id: "history:\(audit.id)",
                            title: audit.title,
                            detail: audit.errorMessage,
                            isError: audit.errorMessage != nil,
                            fetchedAt: localizedTimestamp(audit.fetchedAt),
                            sourceURL: audit.sourceURL,
                            rowIndex: viewModel.remoteBlocks.count + rowIndex
                        )
                    }
                }
            }
        }
        .padding(Self.inspectorContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: viewModel.selectedCitation?.id)
    }

    /// 网络证据行与引用行使用同一信息层级：callout 标题、caption 字段、右侧 chevron。
    /// 默认底色叠加既有 4.5% primary 斑马纹；hover / 展开态由 accent 覆盖，保证整行反馈。
    private func networkContextRow(
        id: String,
        title: String,
        detail: String?,
        isError: Bool,
        fetchedAt: String,
        sourceURL: URL?,
        rowIndex: Int
    ) -> some View {
        let isExpanded = expandedNetworkItemID == id
        let isHovered = hoveredNetworkItemID == id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    expandedNetworkItemID = isExpanded ? nil : id
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        (Text("rag.workspace.inspector.fetchedAt") + Text(" · \(fetchedAt)"))
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
            .pointerStyle(.link)

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(ragFont(.caption))
                            .foregroundStyle(isError ? Color.orange : Color.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    citationField("rag.workspace.inspector.fetchedAt", value: fetchedAt)
                    if let sourceURL {
                        Link(destination: sourceURL) {
                            Label("rag.workspace.inspector.openGitHub", systemImage: "arrow.up.right.square")
                        }
                        .font(ragFont(.caption, weight: .semibold))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isExpanded
                        ? Color.accentColor.opacity(0.08)
                        : (isHovered
                            ? Color.accentColor.opacity(0.045)
                            : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)))
                )
                .allowsHitTesting(false)
        }
        .onHover { isHovering in
            if reduceMotion {
                hoveredNetworkItemID = isHovering ? id : (hoveredNetworkItemID == id ? nil : hoveredNetworkItemID)
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    hoveredNetworkItemID = isHovering ? id : (hoveredNetworkItemID == id ? nil : hoveredNetworkItemID)
                }
            }
        }
        .onDisappear {
            if hoveredNetworkItemID == id {
                hoveredNetworkItemID = nil
            }
        }
    }

    @ViewBuilder
    var knowledgeBaseMetadataPanel: some View {
        if let snapshot = viewModel.knowledgeBaseMetadataSnapshot {
            VStack(alignment: .leading, spacing: 0) {
                // 标题与下方「引用」同级左对齐：不放进卡片内缩进，避免图标比引用标题更靠右。
                // 整行可点：chevron 只表达状态，不单独做触发区（见 UI-折叠展开-规范）。
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        isKnowledgeMetadataExpanded.toggle()
                    }
                } label: {
                    // chevron 放右侧，与下方「引用」手风琴同构（chevron.right + 旋转），避免左右两套折叠习惯。
                    HStack(spacing: 6) {
                        Image(systemName: "cylinder.split.1x2")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("rag.workspace.inspector.metadata.title")
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        // 展示知识库内容最后变化时间（在库仓库最新 library_updated_at），
                        // 而非快照计算时刻；空库/历史缺失时回退占位符。
                        Group {
                            if let updatedAt = snapshot.contentUpdatedAt {
                                Text(updatedAt, format: .dateTime.month().day().hour().minute())
                            } else {
                                Text("rag.workspace.inspector.metadata.updatedAt.unknown")
                            }
                        }
                        .font(ragFont(.caption2))
                        .foregroundStyle(.secondary)
                        .help("rag.workspace.inspector.metadata.updatedAt.help")
                        Image(systemName: "chevron.right")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isKnowledgeMetadataExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        isKnowledgeMetadataRowHovered ? Color.accentColor.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .onHover { isKnowledgeMetadataRowHovered = $0 }
                .onDisappear { isKnowledgeMetadataRowHovered = false }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isKnowledgeMetadataRowHovered
                )

                if isKnowledgeMetadataExpanded {
                    // 组间距压到接近贴合：分组靠标题图标区分，不再靠大空隙撑开。
                    VStack(alignment: .leading, spacing: 4) {
                        // 三列等分 + 居中：窄侧栏下短标签才不会左侧挤成一团、右侧空白。
                        HStack(spacing: 8) {
                            metadataStat("rag.workspace.inspector.metadata.projects", value: snapshot.projectCount) {
                                openMetadataList(.library)
                            }
                            metadataStat("rag.workspace.inspector.metadata.starred", value: snapshot.starredProjectCount) {
                                openMetadataList(.allStars)
                            }
                            metadataStat("rag.workspace.inspector.metadata.retained", value: snapshot.retainedAfterUnstarCount) {
                                openMetadataList(.library, starFilter: .unstarred)
                            }
                        }

                        metadataOrganizationGroup(snapshot)
                        metadataTagsGroup(snapshot)
                        metadataLanguagesGroup(Array(snapshot.topLanguages.prefix(6)))
                        metadataActivityGroup(snapshot)
                        metadataKnowledgeArtifactsGroup(snapshot)
                        metadataContentFreshnessGroup(snapshot)
                        metadataSourceCoverageGroup(snapshot)
                        metadataIndexAvailabilityGroup(snapshot)
                        metadataIndexGroup(snapshot.indexHealth)

                        if !snapshot.topStarredRepositories.isEmpty {
                            starLeadersSection(snapshot.topStarredRepositories)
                        }
                    }
                    // leading = 0：与「元数据」标题图标左缘齐平，去掉折叠展开造成的层级缩进留白。
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                }
            }
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

    /// 新鲜度只表示近 30 天发生过内容更新，不把超过 30 天的摘要误判成失效。
    @ViewBuilder
    private func metadataContentFreshnessGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.freshness",
                systemImage: "clock.arrow.circlepath",
                tint: .green,
                helpTopic: .freshness,
                snapshot: snapshot
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.notesEdited30d",
                value: localizedInteger(snapshot.privateNotesEditedInLast30DaysProjectCount)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.summariesGenerated30d",
                value: localizedInteger(snapshot.aiSummariesGeneratedInLast30DaysProjectCount)
            )
        }
    }

    /// Star Top10：嵌在元数据展开区内，自身默认折叠。
    @ViewBuilder
    private func starLeadersSection(_ repositories: [KnowledgeBaseMetadataSnapshot.TopRepository]) -> some View {
        metadataGroupCard {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isStarLeadersExpanded.toggle()
                }
            } label: {
                // 与「元数据」/「引用」同款：标题在左，chevron 在右。
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(iconFont(size: 12, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("rag.workspace.inspector.metadata.starLeaders")
                        .font(ragFont(.callout, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(iconFont(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isStarLeadersExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isStarLeadersExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(repositories.enumerated()), id: \.offset) { index, repository in
                        MetadataDrillDownRowButton(
                            help: repository.fullName,
                            rowIndex: index,
                            action: { viewModel.openMetadataRepository(repository) }
                        ) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(ragFont(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, alignment: .trailing)
                                RepoIdentityLabel(
                                    fullName: repository.fullName,
                                    avatarSize: 16,
                                    font: ragFont(.caption, weight: .medium),
                                    spacing: 6,
                                    showAvatarBorder: false
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 3) {
                                    Image(systemName: "star.fill")
                                        .font(iconFont(size: 9, weight: .semibold))
                                        .foregroundStyle(.yellow)
                                    Text(repository.stars.formattedShort)
                                        .font(ragFont(.caption2, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Metadata groups

    /// 整理状态：未读/已读一行，正在使用单独成行，避免旧版把三项挤进同一行。
    @ViewBuilder
    private func metadataOrganizationGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        let unread = metadataStatusCount(snapshot.starredStatusCounts, .unread)
        let read = metadataStatusCount(snapshot.starredStatusCounts, .read)
        let using = metadataStatusCount(snapshot.starredStatusCounts, .using)

        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.status",
                systemImage: "tray.full",
                tint: .accentColor
            )
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("rag.workspace.inspector.metadata.unreadRead")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                metadataValueButton(
                    localizedInteger(unread),
                    helpKey: "repo.status.unread"
                ) {
                    openMetadataList(.allStars, status: .unread)
                }
                Text("·")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                metadataValueButton(
                    localizedInteger(read),
                    helpKey: "repo.status.read"
                ) {
                    openMetadataList(.allStars, status: .read)
                }
            }
            // 与「未读/已读」「标签」「索引」等可点击数值统一：accent 数字 + 圆角描边盒，无图标、无实心胶囊。
            metadataMetricActionRow(
                "repo.status.using",
                value: localizedInteger(using),
                helpKey: "repo.status.using"
            ) {
                openMetadataList(.allStars, status: .using)
            }
        }
    }

    @ViewBuilder
    private func metadataTagsGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.tags",
                systemImage: "tag.fill",
                tint: Color.orange
            )
            metadataMetricActionRow(
                "rag.workspace.inspector.metadata.taggedRatio",
                value: "\(localizedInteger(snapshot.starredTaggedProjectCount)) · \(localizedInteger(snapshot.starredUntaggedProjectCount))",
                helpKey: "sidebar.untagged"
            ) {
                openMetadataList(.untagged)
            }
            metadataMetricActionRow(
                "rag.workspace.inspector.metadata.tagTotal",
                value: localizedInteger(snapshot.tagCount),
                helpKey: "sidebar.tags"
            ) {
                viewModel.revealMainWindowTags()
            }
        }
    }

    /// 主要语言：分享卡同款堆叠色条 + 两列图例（色点 / 名 / 计数）。
    @ViewBuilder
    private func metadataLanguagesGroup(_ languages: [KnowledgeBaseMetadataSnapshot.NamedCount]) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.languages",
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: Color.green
            )
            if languages.isEmpty {
                Text("rag.workspace.inspector.metadata.languagesEmpty")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            } else {
                metadataLanguageStackedBar(languages)
                metadataLanguageLegend(languages)
            }
        }
    }

    @ViewBuilder
    private func metadataActivityGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.activity",
                systemImage: "calendar",
                tint: Color.purple
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.added30d",
                value: localizedInteger(snapshot.addedInLast30DaysCount)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.pushed30d",
                value: localizedInteger(snapshot.pushedInLast30DaysCount)
            )
        }
    }

    /// AI 摘要与私有笔记是知识库可检索内容的覆盖事实，不展示正文，避免元数据面板变成数据泄露入口。
    @ViewBuilder
    private func metadataKnowledgeArtifactsGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.artifacts",
                systemImage: "sparkles",
                tint: .purple,
                helpTopic: .artifacts,
                snapshot: snapshot
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.aiSummaryCoverage",
                value: metadataCoverageValue(snapshot.aiSummaryProjectCount, total: snapshot.projectCount)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.privateNoteCoverage",
                value: metadataCoverageValue(snapshot.privateNoteProjectCount, total: snapshot.projectCount)
            )
            if snapshot.aiGeneratedNoteProjectCount > 0 {
                metadataMetricRow(
                    "rag.workspace.inspector.metadata.aiGeneratedNotes",
                    value: localizedInteger(snapshot.aiGeneratedNoteProjectCount)
                )
            }
        }
    }

    /// 按来源列出实际存在的索引分片，帮助用户区分“有笔记/摘要”与“该来源已进入 RAG 索引”。
    @ViewBuilder
    private func metadataSourceCoverageGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.sourceCoverage",
                systemImage: "square.stack.3d.up",
                tint: .teal,
                helpTopic: .sourceCoverage,
                snapshot: snapshot
            )
            ForEach(snapshot.sourceIndexCoverage, id: \.source.rawValue) { item in
                metadataMetricRow(
                    item.source.titleKey,
                    value: String(
                        format: String.l10n("rag.workspace.inspector.metadata.sourceCoverageFormat"),
                        localizedInteger(item.repositoryCount),
                        localizedInteger(item.readyChunkCount)
                    )
                )
            }
        }
    }

    /// 可用性指标解释“为什么召回不到”，详细统计口径放在 Popover，主面板只保留短标签与数字。
    @ViewBuilder
    private func metadataIndexAvailabilityGroup(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.availability",
                systemImage: "checkmark.shield",
                tint: .orange,
                helpTopic: .availability,
                snapshot: snapshot
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.excludedChunks",
                value: localizedInteger(snapshot.excludedChunkCount)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.withoutREADME",
                value: localizedInteger(snapshot.withoutReadmeSourceProjectCount)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.withoutIndexableSource",
                value: localizedInteger(snapshot.withoutIndexableSourceProjectCount)
            )
        }
    }

    private func metadataCoverageValue(_ count: Int, total: Int) -> String {
        String(
            format: String.l10n("rag.workspace.inspector.metadata.coverageFormat"),
            localizedInteger(count),
            localizedInteger(total)
        )
    }

    @ViewBuilder
    private func metadataIndexGroup(_ health: KnowledgeBaseMetadataSnapshot.IndexHealth) -> some View {
        metadataGroupCard {
            metadataGroupHeader(
                titleKey: "rag.workspace.inspector.metadata.group.index",
                systemImage: "square.stack.3d.up.fill",
                tint: Color.cyan
            )
            metadataMetricActionRow(
                "rag.workspace.inspector.metadata.indexTotal",
                value: localizedInteger(health.totalChunks),
                helpKey: "rag.workspace.header.knowledge"
            ) {
                viewModel.openKnowledgeBaseEntry(
                    presentingWindow: NSApp.keyWindow,
                    settingsNavigation: settingsNavigation
                )
            }
            // 与“索引可用性”统一为单行键值数据。状态颜色会让普通统计看起来像告警，
            // 并且胶囊无法解释 total 与 keyword-only 的差额，因此这里保持无色、可对账。
            metadataMetricRow(
                "rag.workspace.inspector.metadata.index.ready",
                value: localizedInteger(health.readyChunks)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.index.keywordReady",
                value: localizedInteger(health.keywordOnlyChunks)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.index.pending",
                value: localizedInteger(health.pendingChunks)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.index.failed",
                value: localizedInteger(health.failedChunks)
            )
            metadataMetricRow(
                "rag.workspace.inspector.metadata.index.stale",
                value: localizedInteger(health.staleChunks)
            )
        }
    }

    @ViewBuilder
    private func metadataGroupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // 内边距收紧：分组之间主要靠标题色块区分，避免卡片垫出大空隙。
        // leading = 0：与「元数据」标题图标左对齐；trailing 保留，避免贴右边。
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @ViewBuilder
    private func metadataGroupHeader(
        titleKey: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        helpTopic: RAGMetadataSectionHelpTopic? = nil,
        snapshot: KnowledgeBaseMetadataSnapshot? = nil
    ) -> some View {
        // 与「计划」tab 的 planSection 同级：callout + 彩色前缀图标。
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(iconFont(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(titleKey)
                .font(ragFont(.callout, weight: .semibold))
                .foregroundStyle(.primary)
            if let helpTopic, let snapshot {
                RAGMetadataSectionInfoButton(topic: helpTopic, snapshot: snapshot)
            }
            Spacer(minLength: 0)
        }
    }

    func metadataMetricRow(_ titleKey: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titleKey)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // 与可点击数值同字号（.caption），去掉 .rounded 保持不放大。
            Text(value)
                .font(ragFont(.caption, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }

    /// 数字下钻只把值做成按钮，标题仍保持统计标签语义；Plain Button 必须关闭 Focus Ring。
    @ViewBuilder
    private func metadataMetricActionRow(
        _ titleKey: LocalizedStringKey,
        value: String,
        helpKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(titleKey)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            metadataValueButton(value, helpKey: helpKey, action: action)
        }
    }

    private func metadataValueButton(
        _ value: String,
        helpKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        MetadataDrillDownButton(help: helpKey, action: action) {
            // 字号与前置 label（.caption）保持一致；不用 .rounded，圆体数字 x-height 偏大会显得「被放大」。
            Text(value)
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }

    private func metadataLanguageStackedBar(_ languages: [KnowledgeBaseMetadataSnapshot.NamedCount]) -> some View {
        let total = max(languages.reduce(0) { $0 + $1.count }, 1)
        let spacing: CGFloat = 2
        return GeometryReader { proxy in
            let available = max(0, proxy.size.width - CGFloat(max(0, languages.count - 1)) * spacing)
            HStack(spacing: spacing) {
                ForEach(Array(languages.enumerated()), id: \.offset) { _, language in
                    let ratio = CGFloat(language.count) / CGFloat(total)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LanguageColor.color(for: language.name))
                        .frame(width: max(4, available * ratio), height: 8)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("rag.workspace.inspector.metadata.languages"))
    }

    @ViewBuilder
    private func metadataLanguageLegend(_ languages: [KnowledgeBaseMetadataSnapshot.NamedCount]) -> some View {
        let total = max(languages.reduce(0) { $0 + $1.count }, 1)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(stride(from: 0, to: languages.count, by: 2)), id: \.self) { start in
                HStack(spacing: 8) {
                    metadataLanguageLegendItem(languages[start], total: total)
                    if start + 1 < languages.count {
                        metadataLanguageLegendItem(languages[start + 1], total: total)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func metadataLanguageLegendItem(
        _ language: KnowledgeBaseMetadataSnapshot.NamedCount,
        total: Int
    ) -> some View {
        let percent = Double(language.count) * 100.0 / Double(total)
        HStack(spacing: 4) {
            Circle()
                .fill(LanguageColor.color(for: language.name))
                .frame(width: 7, height: 7)
            Text(language.name)
                .font(ragFont(.caption2, weight: .medium))
                .lineLimit(1)
            Text(String(format: "%.0f%%", percent))
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func metadataStat(
        _ titleKey: LocalizedStringKey,
        value: Int,
        action: @escaping () -> Void
    ) -> some View {
        MetadataDrillDownButton(help: titleKey, variant: .stat, action: action) {
            VStack(alignment: .center, spacing: 2) {
                Text(value, format: .number)
                    .font(ragFont(.headline, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                Text(titleKey)
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
        }
    }

    private func metadataStatusCount(
        _ counts: [KnowledgeBaseMetadataSnapshot.NamedCount],
        _ status: RepoStatus
    ) -> Int {
        counts.first { $0.name == status.rawValue }?.count ?? 0
    }

    /// 所有数字钻取都从中性完整预设起步，避免叠加用户此前的语言、信号或隐藏条件。
    private func openMetadataList(
        _ selection: SidebarItem,
        starFilter: RepoStarFilter = .all,
        status: RepoStatus? = nil
    ) {
        var filters = GlobalRepoFilterState.neutral
        filters.starFilter = starFilter
        filters.statusFilter = status
        viewModel.openMainWindowMetadataDestination(selection, filters: filters)
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
            if citation.source == .repoContext {
                repoContextCitationDetail(citation)
            } else {
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

    /// RepoContext 以仓库级 `context.xml` 证据展示，不伪装成 `rag_chunks` 数据库分片。
    /// 历史 XML 只有在 commit/hash 与当轮快照一致时才会由 ViewModel 恢复。
    @ViewBuilder
    private func repoContextCitationDetail(_ citation: RAGCitation) -> some View {
        if let snapshot = viewModel.displayedRepoContextSnapshot {
            citationField("rag.workspace.repoContext.commit", value: snapshot.shortCommitSHA)
            citationField("rag.workspace.repoContext.hash", value: snapshot.shortContentHash)
            citationField(
                "rag.workspace.repoContext.tokens",
                value: snapshot.sentTokens.formatted()
            )
            citationField(
                "rag.workspace.repoContext.cache",
                value: snapshot.cacheHit
                    ? String.l10n("rag.workspace.repoContext.cache.hit")
                    : String.l10n("rag.workspace.repoContext.cache.generated")
            )
            citationField(
                "rag.workspace.repoContext.projection",
                value: snapshot.wasProjected
                    ? String.l10n("rag.workspace.repoContext.projection.projected")
                    : String.l10n("rag.workspace.repoContext.projection.original")
            )
            if let reason = snapshot.projectionReason, !reason.isEmpty {
                citationField("rag.workspace.repoContext.projectionReason", value: reason)
            }
        }

        if let document = viewModel.repoContextDocument {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label("rag.workspace.repoContext.xml", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(ragFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    CopyFeedbackButton(
                        providesContent: { document.xml },
                        tooltip: "rag.workspace.repoContext.copy"
                    ) { didCopy in
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(iconFont(size: 10, weight: .medium))
                            .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    }
                }
                Button {
                    guard !isRepoContextXMLPopoverOpening,
                          !isRepoContextXMLPopoverPresented else { return }
                    isRepoContextXMLPopoverOpening = true
                    isRepoContextXMLPopoverPresented = true
                } label: {
                    Text(document.xml)
                        .font(ragFont(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(isRepoContextXMLPopoverOpening || isRepoContextXMLPopoverPresented)
                .help("rag.workspace.repoContext.xml.expand")
                .padding(8)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .popover(isPresented: $isRepoContextXMLPopoverPresented, arrowEdge: .leading) {
                    RAGRepoContextXMLPopoverContent(citation: citation, document: document)
                        .onAppear {
                            // 内容真正挂载后才解除 opening 锁；presented 仍让入口保持禁用直到关闭。
                            isRepoContextXMLPopoverOpening = false
                        }
                }
                .onChange(of: isRepoContextXMLPopoverPresented) { _, isPresented in
                    if !isPresented {
                        isRepoContextXMLPopoverOpening = false
                    }
                }
            }
        } else {
            Label("rag.workspace.repoContext.historyUnavailable", systemImage: "clock.badge.exclamationmark")
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
        }
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
                    planSection(
                        "rag.workspace.inspector.plan.questionUnderstanding",
                        systemImage: "text.magnifyingglass",
                        tint: .accentColor,
                        helpTopic: .questionUnderstanding
                    ) {
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

                    planSection(
                        "rag.workspace.inspector.plan.questionUnderstanding",
                        systemImage: "text.magnifyingglass",
                        tint: .accentColor,
                        helpTopic: .questionUnderstanding
                    ) {
                        if let question = viewModel.displayedPlanQuestion, !question.isEmpty {
                            planQuestionValue("rag.workspace.inspector.plan.originalQuestion", value: question)
                        }
                        let semanticQuery = resolvedSemanticQuery(plan)
                        if !semanticQuery.isEmpty {
                            planQuestionValue("rag.workspace.inspector.semanticQuery", value: semanticQuery)
                        }
                        let keywordQueries = resolvedKeywordQueries(plan)
                        if !keywordQueries.isEmpty {
                            planQuestionValue(
                                "rag.workspace.inspector.keywordQueries",
                                value: keywordQueries.joined(separator: " · ")
                            )
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

                    planSection(
                        "rag.workspace.inspector.plan.executionStrategy",
                        systemImage: "slider.horizontal.3",
                        tint: .purple,
                        helpTopic: .executionStrategy
                    ) {
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

                    if let repoContextRequest = plan.repoContextRequest {
                        // RepoContext 是独立于分片检索和联网的本地执行步骤，必须在计划中
                        // 单列；把它塞进“联网计划”会错误暗示 XML 会发送给搜索 Provider。
                        // 不展示 planReason：本节出现本身即表示已开启深度思考，与「状态」重复。
                        planSection(
                            "rag.workspace.inspector.plan.repoContext",
                            systemImage: "brain.head.profile",
                            tint: .indigo,
                            helpTopic: .repoContext
                        ) {
                            planMetricRow(
                                "rag.workspace.inspector.plan.repoContext.project",
                                value: repoContextRequest.repoFullName
                            )
                            planMetricRow(
                                "rag.workspace.inspector.plan.repoContext.budget",
                                value: repoContextRequest.configuredTokenBudget.formatted()
                            )
                            if let snapshot = viewModel.displayedRepoContextSnapshot {
                                planMetricRow(
                                    "rag.workspace.inspector.plan.repoContext.status",
                                    value: localizedRepoContextOutcome(snapshot.outcome)
                                )
                                if let commitSHA = snapshot.commitSHA {
                                    planMetricRow(
                                        "rag.workspace.repoContext.commit",
                                        value: String(commitSHA.prefix(12))
                                    )
                                }
                                planMetricRow(
                                    "rag.workspace.repoContext.cache",
                                    value: snapshot.cacheHit
                                        ? String.l10n("rag.workspace.repoContext.cache.hit")
                                        : String.l10n("rag.workspace.repoContext.cache.generated")
                                )
                                // 只展示实际进入 Prompt 的 sentTokens；裁剪与否由「窗口适配」行表达。
                                planMetricRow(
                                    "rag.workspace.repoContext.tokens",
                                    value: snapshot.sentTokens.formatted()
                                )
                                planMetricRow(
                                    "rag.workspace.repoContext.projection",
                                    value: snapshot.wasProjected
                                        ? String.l10n("rag.workspace.repoContext.projection.projected")
                                        : String.l10n("rag.workspace.repoContext.projection.original")
                                )
                            }
                        }
                    }

                    planSection(
                        "rag.workspace.inspector.plan.networkPlan",
                        systemImage: "network",
                        tint: .cyan,
                        helpTopic: .networkPlan
                    ) {
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
                            // 操作块，不是分组标题：caption 层级压在「联网计划」section 之下。
                            networkPlanOperationRow(
                                title: remoteResourceName(request.resource),
                                systemImage: "network"
                            ) {
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
                            // 互联网搜索是联网计划下的一次操作，禁止用 callout/semibold 冒充新 section。
                            networkPlanOperationRow(
                                title: String.l10n("rag.workspace.inspector.plan.webSearch")
                            ) {
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
                        let trace = viewModel.displayedRetrievalTrace
                        planSection(
                            "rag.workspace.inspector.plan.retrievalFunnel",
                            systemImage: "line.3.horizontal.decrease.circle.fill",
                            tint: .orange,
                            helpTopic: .retrievalFunnel
                        ) {
                            retrievalMetricRow(
                                "rag.workspace.inspector.plan.retrieval.candidates",
                                value: localizedInteger(retrieval.candidateRepoCount),
                                target: .candidates,
                                trace: trace
                            )
                            retrievalMetricRow(
                                "rag.workspace.inspector.plan.retrieval.keyword",
                                value: localizedRetrievalBranch(
                                    raw: retrieval.keywordRawCount,
                                    accepted: retrieval.keywordAcceptedCount,
                                    failure: retrieval.keywordFailure,
                                    outcome: retrieval.outcome
                                ),
                                target: .keyword,
                                trace: trace
                            )
                            retrievalMetricRow(
                                "rag.workspace.inspector.plan.retrieval.vector",
                                value: localizedRetrievalBranch(
                                    raw: retrieval.vectorRawCount,
                                    accepted: retrieval.vectorAcceptedCount,
                                    failure: retrieval.vectorFailure,
                                    outcome: retrieval.outcome
                                ),
                                target: .semantic,
                                trace: trace
                            )
                            retrievalMetricRow(
                                "rag.workspace.inspector.plan.retrieval.fusion",
                                value: String(
                                    format: String.l10n("rag.workspace.inspector.plan.retrieval.fusionFormat"),
                                    retrieval.fusionUniqueCount,
                                    retrieval.rankingFilteredCount
                                ),
                                target: .fusion,
                                trace: trace
                            )
                            retrievalMetricRow(
                                "rag.workspace.inspector.plan.retrieval.rerank",
                                value: localizedRerank(retrieval),
                                target: .rerank,
                                trace: trace
                            )
                            retrievalMetricRow(
                                "rag.workspace.inspector.plan.retrieval.result",
                                value: String(
                                    format: String.l10n("rag.workspace.inspector.plan.retrieval.resultFormat"),
                                    retrieval.finalChildHitCount,
                                    retrieval.bundleCount
                                ),
                                target: .finalEvidence,
                                trace: trace
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
                        planSection(
                            "rag.workspace.inspector.plan.retrievalFunnel",
                            systemImage: "line.3.horizontal.decrease.circle.fill",
                            tint: .orange,
                            helpTopic: .retrievalFunnel
                        ) {
                            planMetricRow(
                                "rag.workspace.inspector.plan.retrieval.outcome",
                                value: String.l10n("rag.workspace.inspector.plan.retrieval.guided")
                            )
                        }
                    }

                    if let usage = viewModel.displayedContextUsage {
                        planSection(
                            "rag.workspace.inspector.plan.contextBudget",
                            systemImage: "gauge.with.dots.needle.33percent",
                            tint: .green,
                            helpTopic: .contextBudget
                        ) {
                            RAGContextWindowBreakdownView(
                                usage: usage,
                                variant: .budget
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
    func planSection<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color = .accentColor,
        helpTopic: RAGPlanSectionHelpTopic? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 分组标题：升一档到 callout（与元数据面板标题同层级）+ 前缀彩色图标，
            // 让「计划」tab 的分组比行内文案更醒目、可快速扫读。
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(iconFont(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(ragFont(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                if let helpTopic {
                    RAGPlanSectionInfoButton(topic: helpTopic)
                }
                Spacer(minLength: 0)
            }
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
            if plan.repoContextRequest != nil {
                planChip(String.l10n("rag.workspace.inspector.plan.repoContext.enabled"))
            }
        }
    }

    private func localizedRepoContextOutcome(_ outcome: RAGRepoContextOutcome) -> String {
        switch outcome {
        case .success: return String.l10n("rag.workspace.execution.repoContext.completed")
        case .featureDisabled: return String.l10n("rag.workspace.execution.repoContext.disabled")
        case .degraded: return String.l10n("rag.workspace.execution.repoContext.degraded")
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

    /// 联网计划下的单次操作（GitHub 远程 / 互联网搜索）。
    /// 故意用 caption + secondary，避免与上方 `planSection` 的 callout 标题同级。
    func networkPlanOperationRow<Content: View>(
        title: String,
        systemImage: String? = nil,
        @ViewBuilder details: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            details()
        }
    }

    /// 漏斗数字复用元数据下钻的 caption / accent / plain button 样式；没有逐项轨迹的旧会话保持普通文本。
    @ViewBuilder
    private func retrievalMetricRow(
        _ label: LocalizedStringKey,
        value: String,
        target: RAGRetrievalDetailTarget,
        trace: RAGRetrievalTrace?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trace, retrievalDetailCount(target, trace: trace) > 0 {
                MetadataDrillDownButton(
                    help: "rag.workspace.inspector.plan.retrieval.detail.help",
                    action: { retrievalDetailTarget = target }
                ) {
                    Text(value)
                        .font(ragFont(.caption, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                }
                .popover(item: retrievalDetailBinding(for: target)) { selectedTarget in
                    retrievalDetailPopover(selectedTarget, trace: trace)
                        .appLocaleEnvironment()
                }
            } else {
                Text(value)
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func retrievalDetailPopover(_ target: RAGRetrievalDetailTarget, trace: RAGRetrievalTrace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(retrievalDetailTitle(target))
                .font(ragFont(.callout, weight: .semibold))
                .foregroundStyle(.primary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch target {
                    case .candidates:
                        ForEach(Array(trace.candidates.enumerated()), id: \.element.id) { rowIndex, candidate in
                            retrievalCandidateRow(candidate, rowIndex: rowIndex)
                        }
                    case .rerank:
                        if let rerank = trace.rerank {
                            ForEach(Array(rerank.inputCandidates.enumerated()), id: \.element.inputIndex) { rowIndex, candidate in
                                rerankTraceRow(candidate, rerank: rerank, rowIndex: rowIndex)
                            }
                        } else {
                            retrievalDetailUnavailable
                        }
                    case .keyword, .semantic, .fusion, .finalEvidence:
                        ForEach(Array(retrievalDetailHits(target, trace: trace).enumerated()), id: \.element.id) { rowIndex, hit in
                            retrievalTraceRow(hit, rowIndex: rowIndex)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(12)
        .frame(width: 430, height: retrievalDetailPopoverHeight(target, trace: trace), alignment: .topLeading)
    }

    var retrievalDetailUnavailable: some View {
        Text("rag.workspace.inspector.plan.retrieval.detail.unavailable")
            .font(ragFont(.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    /// 与知识库的其他可扫描列表使用同一斑马纹，避免详情数据堆叠时难以逐行对应。
    private func retrievalZebraBackground(rowIndex: Int) -> Color {
        rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
    }

    /// 详情不足一屏时收紧 popover，避免单个候选仓库被大面积空白淹没；超过上限仍由 ScrollView 承载。
    private func retrievalDetailPopoverHeight(_ target: RAGRetrievalDetailTarget, trace: RAGRetrievalTrace) -> CGFloat {
        let count = max(retrievalDetailCount(target, trace: trace), 1)
        let rowHeight: CGFloat = target == .candidates ? 58 : 84
        let minimumHeight: CGFloat = target == .candidates ? 144 : 176
        return min(max(minimumHeight, 74 + CGFloat(count) * rowHeight), 360)
    }

    private func retrievalCandidateRow(_ candidate: RAGRetrievalCandidateTrace, rowIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            RepoIdentityLabel(
                fullName: candidate.fullName,
                avatarSize: 28,
                font: ragFont(.callout, weight: .semibold),
                spacing: 8,
                showAvatarBorder: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            // 头像/名称仍交给 RepoIdentityLabel；语言和 star 放在同一名称缩进列，
            // 与主窗口仓库行的二级信息结构一致，且不会影响头像缓存与占位逻辑。
            if candidate.language?.isEmpty == false || candidate.stars != nil {
                HStack(spacing: 10) {
                    if let language = candidate.language, !language.isEmpty {
                        LanguageBadge(language: language, style: .compact)
                    }
                    if let stars = candidate.stars {
                        StarsBadge(count: stars, style: .compact)
                    }
                }
                .padding(.leading, 36)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(retrievalZebraBackground(rowIndex: rowIndex))
    }

    private func retrievalTraceRow(_ hit: RAGRetrievalHitTrace, rowIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RepoIdentityLabel(
                    fullName: hit.repositoryName,
                    avatarSize: 16,
                    font: ragFont(.caption, weight: .semibold),
                    spacing: 6,
                    showAvatarBorder: false
                )
                Spacer(minLength: 6)
                retrievalScorePill("rag.browser.retrieval.rankScore", value: hit.score, tone: .retrievalScore)
            }
            Text(hit.sectionTitle)
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: hit.source.systemImageName)
                    .font(iconFont(size: 10, weight: .semibold))
                    .foregroundStyle(hit.source.tintColor)
                    .accessibilityHidden(true)
                Text(hit.source.titleKey)
                Text("·")
                Text(localizedHitKind(hit.hitKind))
                if let vectorSimilarity = hit.vectorSimilarity {
                    retrievalScorePill("rag.browser.retrieval.vectorSimilarity", value: vectorSimilarity, tone: .vectorSimilarity)
                }
                Spacer(minLength: 0)
            }
            .font(ragFont(.caption2))
            .foregroundStyle(.secondary)
            retrievalDispositionPill(hit.disposition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(retrievalZebraBackground(rowIndex: rowIndex))
    }

    private func rerankTraceRow(
        _ candidate: RAGRerankTrace.InputCandidate,
        rerank: RAGRerankTrace,
        rowIndex: Int
    ) -> some View {
        let responseScore = rerank.responseResults.first { $0.inputIndex == candidate.inputIndex }?.rerankScore
        let appliedRank = rerank.appliedOrder.first { $0.inputIndex == candidate.inputIndex }?.rank
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RepoIdentityLabel(
                    fullName: candidate.repositoryName,
                    avatarSize: 16,
                    font: ragFont(.caption, weight: .semibold),
                    spacing: 6,
                    showAvatarBorder: false
                )
                Spacer(minLength: 6)
                retrievalScorePill("rag.browser.retrieval.rankScore", value: candidate.preRerankScore, tone: .retrievalScore)
            }
            Text(candidate.section)
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: candidate.source.systemImageName)
                    .font(iconFont(size: 10, weight: .semibold))
                    .foregroundStyle(candidate.source.tintColor)
                    .accessibilityHidden(true)
                Text(candidate.source.titleKey)
                if let responseScore {
                    retrievalScorePill("rag.workspace.inspector.plan.retrieval.detail.rerankScore", value: responseScore, tone: .rerankScore)
                }
                if let appliedRank {
                    Text("· #\(appliedRank)")
                }
            }
            .font(ragFont(.caption2))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(retrievalZebraBackground(rowIndex: rowIndex))
    }

    /// 颜色只放在描边与浅底上，胶囊文字仍遵循 primary，确保明暗主题下的对比度稳定。
    private func retrievalScorePill(
        _ title: LocalizedStringKey,
        value: Double,
        tone: RetrievalDetailPillTone
    ) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text(String(format: "%.3f", value))
                .monospacedDigit()
        }
        .font(ragFont(.caption2, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.28), lineWidth: 1))
    }

    private func retrievalDispositionPill(_ disposition: RAGRetrievalTraceDisposition) -> some View {
        Text(localizedRetrievalDisposition(disposition))
            .font(ragFont(.caption2, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(retrievalDispositionTone(disposition).color.opacity(0.14), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    retrievalDispositionTone(disposition).color.opacity(0.28),
                    lineWidth: 1
                )
            )
    }

    private func retrievalDispositionTone(_ disposition: RAGRetrievalTraceDisposition) -> RetrievalDetailPillTone {
        switch disposition {
        case .retained: return .success
        case .sourceDisabled: return .neutral
        case .belowVectorSimilarity, .belowEvidenceScore: return .danger
        case .perRepositoryLimit, .totalLimit, .parentContextTokenLimit, .evidenceTokenLimit: return .warning
        }
    }

    private func retrievalDetailCount(_ target: RAGRetrievalDetailTarget, trace: RAGRetrievalTrace) -> Int {
        switch target {
        case .candidates: return trace.candidates.count
        case .keyword: return trace.keywordHits.count
        case .semantic: return trace.semanticHits.count
        case .fusion: return trace.fusionHits.count
        case .rerank: return trace.rerank?.inputCandidates.count ?? 0
        case .finalEvidence: return trace.finalEvidence.count
        }
    }

    /// 每个数字只观察自己的 target，避免多个漏斗行同时对同一份 optional state 挂 popover 时抢锚点。
    private func retrievalDetailBinding(for target: RAGRetrievalDetailTarget) -> Binding<RAGRetrievalDetailTarget?> {
        Binding(
            get: { retrievalDetailTarget == target ? target : nil },
            set: { retrievalDetailTarget = $0 }
        )
    }

    private func retrievalDetailHits(_ target: RAGRetrievalDetailTarget, trace: RAGRetrievalTrace) -> [RAGRetrievalHitTrace] {
        switch target {
        case .keyword: return trace.keywordHits
        case .semantic: return trace.semanticHits
        case .fusion: return trace.fusionHits
        case .finalEvidence: return trace.finalEvidence
        case .candidates, .rerank: return []
        }
    }

    private func retrievalDetailTitle(_ target: RAGRetrievalDetailTarget) -> LocalizedStringKey {
        switch target {
        case .candidates: return "rag.workspace.inspector.plan.retrieval.detail.candidates"
        case .keyword: return "rag.workspace.inspector.plan.retrieval.detail.keyword"
        case .semantic: return "rag.workspace.inspector.plan.retrieval.detail.semantic"
        case .fusion: return "rag.workspace.inspector.plan.retrieval.detail.fusion"
        case .rerank: return "rag.workspace.inspector.plan.retrieval.detail.rerank"
        case .finalEvidence: return "rag.workspace.inspector.plan.retrieval.detail.finalEvidence"
        }
    }

    func localizedHitKind(_ hitKind: RAGHitKind) -> LocalizedStringKey {
        switch hitKind {
        case .keyword: return "rag.workspace.inspector.plan.retrieval.detail.hitKind.keyword"
        case .vector: return "rag.workspace.inspector.plan.retrieval.detail.hitKind.vector"
        case .hybrid: return "rag.workspace.inspector.plan.retrieval.detail.hitKind.hybrid"
        case .repoContext: return "rag.workspace.inspector.plan.retrieval.detail.hitKind.repoContext"
        }
    }

    func localizedRetrievalDisposition(_ disposition: RAGRetrievalTraceDisposition) -> LocalizedStringKey {
        switch disposition {
        case .retained: return "rag.workspace.inspector.plan.retrieval.detail.disposition.retained"
        case .sourceDisabled: return "rag.workspace.inspector.plan.retrieval.detail.disposition.sourceDisabled"
        case .belowVectorSimilarity: return "rag.workspace.inspector.plan.retrieval.detail.disposition.belowVectorSimilarity"
        case .perRepositoryLimit: return "rag.workspace.inspector.plan.retrieval.detail.disposition.perRepositoryLimit"
        case .totalLimit: return "rag.workspace.inspector.plan.retrieval.detail.disposition.totalLimit"
        case .belowEvidenceScore: return "rag.workspace.inspector.plan.retrieval.detail.disposition.belowEvidenceScore"
        case .parentContextTokenLimit: return "rag.workspace.inspector.plan.retrieval.detail.disposition.parentContextTokenLimit"
        case .evidenceTokenLimit: return "rag.workspace.inspector.plan.retrieval.detail.disposition.evidenceTokenLimit"
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
        case .repositoriesWithAISummary: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithAISummary")
        case .repositoriesWithPrivateNotes: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithPrivateNotes")
        case .repositoriesWithAIGeneratedNotes: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithAIGeneratedNotes")
        case .repositoriesWithRecentlyEditedPrivateNotes: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithRecentlyEditedPrivateNotes")
        case .repositoriesWithRecentlyGeneratedAISummaries: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithRecentlyGeneratedAISummaries")
        case .excludedRAGChunks: return String.l10n("rag.workspace.inspector.plan.analytics.measure.excludedRAGChunks")
        case .repositoriesWithoutREADME: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithoutREADME")
        case .repositoriesWithoutIndexableSource: return String.l10n("rag.workspace.inspector.plan.analytics.measure.repositoriesWithoutIndexableSource")
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

    /// `0` 只有在分支确实执行完成后才表示零命中；跳过和失败必须给出不同状态，
    /// 否则用户会误以为限定仓库后根本没有运行分片检索。
    func localizedRetrievalBranch(
        raw: Int,
        accepted: Int,
        failure: RAGRetrievalBranchFailure?,
        outcome: RAGRetrievalDiagnostics.Outcome?
    ) -> String {
        switch RAGRetrievalBranchStatus.resolve(
            raw: raw,
            accepted: accepted,
            failure: failure,
            outcome: outcome
        ) {
        case .completed(let raw, let accepted):
            return localizedFunnelCount(raw: raw, accepted: accepted)
        case .failed(let failure):
            return String(
                format: String.l10n("rag.workspace.inspector.plan.retrieval.branch.failedFormat"),
                localizedRetrievalFailure(failure)
            )
        case .skipped:
            return String.l10n("rag.workspace.inspector.plan.retrieval.branch.skipped")
        }
    }

    func localizedRetrievalFailure(_ failure: RAGRetrievalBranchFailure) -> String {
        switch failure {
        case .providerError:
            return String.l10n("rag.workspace.inspector.plan.retrieval.branch.providerError")
        }
    }

    /// 新计划直接展示 Planner 关键词；旧自定义 Prompt 没有该字段时，回退到 Retriever
    /// 实际执行的查询轨迹，确保界面展示与真实 FTS5 请求一致。
    func resolvedKeywordQueries(_ plan: RAGQueryPlan) -> [String] {
        if !plan.keywordQueries.isEmpty { return plan.keywordQueries }
        return viewModel.displayedRetrievalTrace?.keywordQuery?.terms ?? []
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
        VStack(alignment: .leading, spacing: 12) {
            indexHealthSummary

            VStack(alignment: .leading, spacing: 2) {
                knowledgeRepositoryRow
                indexIssueRow(
                    .pending,
                    count: viewModel.indexStatus.pendingChunks,
                    color: .orange,
                    rowIndex: 1
                )
                indexIssueRow(
                    .failed,
                    count: viewModel.indexStatus.failedChunks,
                    color: .red,
                    rowIndex: 2
                )
                indexIssueRow(
                    .stale,
                    count: viewModel.indexStatus.staleChunks,
                    color: .purple,
                    rowIndex: 3
                )
            }

            // 来源覆盖 + 无法召回缺口：均来自元数据快照。快照要等首次问答或打开工作台时才拉取，
            // 因此为空时整段隐藏，不占位、不显示占位 0。
            if let snapshot = viewModel.knowledgeBaseMetadataSnapshot {
                if !snapshot.sourceIndexCoverage.isEmpty {
                    Divider()
                    indexSourceCoverageSection(snapshot)
                }

                Divider()
                indexCoverageGapSection(snapshot)
            }

            Divider()

            indexBuildSection
        }
        .padding(Self.inspectorContentInset)
    }

    /// 各来源实际进入 RAG 的分片覆盖，帮助区分「有摘要/笔记」与「该来源已可检索」。
    @ViewBuilder
    func indexSourceCoverageSection(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("rag.workspace.inspector.metadata.group.sourceCoverage")
                .font(ragFont(.callout, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(snapshot.sourceIndexCoverage.enumerated()), id: \.element.source.rawValue) { index, item in
                    indexInfoRow(
                        item.source.titleKey,
                        value: String(
                            format: String.l10n("rag.workspace.inspector.metadata.sourceCoverageFormat"),
                            localizedInteger(item.repositoryCount),
                            localizedInteger(item.readyChunkCount)
                        ),
                        rowIndex: index
                    )
                }
            }
        }
    }

    /// 无法召回的缺口：无 README / 无可索引来源属于「有仓库却召不到」，>0 时以橙色提示；
    /// 已排除分片是用户主动行为，保持中性色不误报为告警。
    @ViewBuilder
    func indexCoverageGapSection(_ snapshot: KnowledgeBaseMetadataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("rag.workspace.inspector.metadata.group.availability")
                .font(ragFont(.callout, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                indexInfoRow(
                    "rag.workspace.inspector.metadata.withoutREADME",
                    value: localizedInteger(snapshot.withoutReadmeSourceProjectCount),
                    rowIndex: 0,
                    valueColor: snapshot.withoutReadmeSourceProjectCount > 0 ? .orange : .secondary
                )
                indexInfoRow(
                    "rag.workspace.inspector.metadata.withoutIndexableSource",
                    value: localizedInteger(snapshot.withoutIndexableSourceProjectCount),
                    rowIndex: 1,
                    valueColor: snapshot.withoutIndexableSourceProjectCount > 0 ? .orange : .secondary
                )
                indexInfoRow(
                    "rag.workspace.inspector.metadata.excludedChunks",
                    value: localizedInteger(snapshot.excludedChunkCount),
                    rowIndex: 2
                )
            }
        }
    }

    /// 索引 Tab 内的只读键值行：非交互，仅斑马纹分隔，字号与 issue / 构建阶段行保持一致。
    func indexInfoRow(
        _ label: LocalizedStringKey,
        value: String,
        rowIndex: Int,
        valueColor: Color = .secondary
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(ragFont(.caption, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, Self.indexRowHorizontalPadding)
        .padding(.vertical, Self.indexRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    #if DEBUG
    /// 「调试」tab 内容：开关已在 header，这里只展示已开启后的 trace 列表。
    var debugInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("rag.workspace.debug.privacy.repoContext", systemImage: "lock.doc")
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                // 单条导出走行内按钮；顶部只保留清空整条会话 Debug。
                Button {
                    isClearDebugTracesConfirmationPresented = true
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
                ForEach(Array(viewModel.debugTraces.sorted { $0.startedAt > $1.startedAt }.enumerated()), id: \.element.id) { traceIndex, trace in
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
                        .background(
                            hoveredDebugTraceID == trace.id ? Color.accentColor.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .onHover { isHovering in
                            hoveredDebugTraceID = isHovering ? trace.id : (hoveredDebugTraceID == trace.id ? nil : hoveredDebugTraceID)
                        }
                        .onDisappear {
                            if hoveredDebugTraceID == trace.id {
                                hoveredDebugTraceID = nil
                            }
                        }
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.15),
                            value: hoveredDebugTraceID == trace.id
                        )

                        if isExpanded {
                            // 子 stage 相对父行轻缩进即可，过大空白会浪费窄侧栏。
                            let stepDurations = debugEventStepDurations(for: trace.events)
                            let repoContextEvents = trace.events.filter { isRepoContextDebugStage($0.stage) }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(trace.events.enumerated()), id: \.element.id) { eventIndex, event in
                                    if isRepoContextDebugStage(event.stage) {
                                        // 三个 RepoContext stage 共享一个操作入口；仅在首个事件的位置渲染，
                                        // 避免请求、结果、投影继续表现成三个同级组。
                                        if event.id == repoContextEvents.first?.id {
                                            debugRepoContextGroup(
                                                repoContextEvents,
                                                rowIndex: eventIndex,
                                                stepDurations: stepDurations
                                            )
                                        }
                                    } else {
                                        debugEventRow(
                                            event,
                                            rowIndex: eventIndex,
                                            stepDurationSeconds: stepDurations[event.id] ?? event.elapsedSeconds
                                        )
                                    }
                                }
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                        }
                    }
                    // 斑马纹：奇数条叠一层极淡 primary（与元数据 metadataZebraBackground 同 0.045 约定），
                    // 明暗主题下相邻问答都能一眼分组；放在基底 background 之前 = 叠在白底之上。
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(traceIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045))
                    )
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
        rowIndex: Int,
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
                if let presentation = debugPayloadPresentation(for: event.id),
                   let block = presentation.block(for: event.id) {
                    debugPayloadChunks(for: event, block: block)
                        .onAppear {
                            finishPendingDebugEventExpand(event.id)
                        }
                } else {
                    debugPayloadLoadingSkeleton()
                        .onAppear {
                            scheduleDebugPayloadPreparation(
                                expansionID: event.id,
                                events: [event]
                            )
                        }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        // hover 优先于斑马纹；颜色与父 trace 行一致，且不改变尺寸，避免列表抖动。
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    hoveredDebugEventID == event.id
                        ? Color.accentColor.opacity(0.08)
                        : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045))
                )
        )
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering in
            hoveredDebugEventID = isHovering
                ? event.id
                : (hoveredDebugEventID == event.id ? nil : hoveredDebugEventID)
        }
        .onDisappear {
            if hoveredDebugEventID == event.id {
                hoveredDebugEventID = nil
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: hoveredDebugEventID == event.id
        )
    }

    /// RepoContext 的请求、结果、窗口投影属于同一条上下文准备链路。外层只保留一套
    /// 耗时、复制和折叠操作，展开后再按原始事件顺序展示三个只读区块。
    func debugRepoContextGroup(
        _ events: [RAGDebugEvent],
        rowIndex: Int,
        stepDurations: [UUID: TimeInterval]
    ) -> some View {
        let groupID = events.first?.id
        let isExpanded = groupID.map { expandedDebugEventIDs.contains($0) } ?? false
        let isExpandPending = groupID.map { pendingExpandDebugEventIDs.contains($0) } ?? false
        let totalDuration = events.reduce(0) { result, event in
            result + (stepDurations[event.id] ?? 0)
        }

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                toggleRepoContextDebugGroupExpansion(events)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(iconFont(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text("rag.workspace.context.repoContext")
                        .font(ragFont(.caption, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(String(format: String.l10n("rag.workspace.debug.elapsedFormat"), locale: locale, totalDuration))
                        .font(ragFont(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("rag.workspace.debug.stepDuration.help")
                    // 给复制留位，保证 chevron 与普通 stage 行保持同一列。
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
            .disabled(isExpandPending)
            .opacity(isExpandPending ? 0.72 : 1)
            .overlay(alignment: .trailing) {
                CopyFeedbackButton(
                    providesContent: {
                        events.map { event in
                            "[\(event.stage.rawValue)]\n\(event.renderedPayload())"
                        }
                        .joined(separator: "\n\n")
                    },
                    tooltip: "rag.workspace.debug.copy"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(iconFont(size: 9, weight: .regular))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                        .fixedSize()
                }
                .padding(.trailing, 18)
            }

            if isExpanded, let groupID {
                if let presentation = debugPayloadPresentation(for: groupID) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { blockIndex, event in
                            if blockIndex > 0 {
                                Divider()
                            }
                            if let block = presentation.block(for: event.id) {
                                debugRepoContextBlock(event, block: block)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .onAppear {
                        finishPendingDebugEventExpand(groupID)
                    }
                } else {
                    debugPayloadLoadingSkeleton(lineCount: 5)
                        .padding(.horizontal, 6)
                        .onAppear {
                            scheduleDebugPayloadPreparation(
                                expansionID: groupID,
                                events: events
                            )
                        }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    groupID == hoveredDebugEventID
                        ? Color.accentColor.opacity(0.08)
                        : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045))
                )
        )
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering in
            guard let groupID else { return }
            hoveredDebugEventID = isHovering
                ? groupID
                : (hoveredDebugEventID == groupID ? nil : hoveredDebugEventID)
        }
        .onDisappear {
            if hoveredDebugEventID == groupID {
                hoveredDebugEventID = nil
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: hoveredDebugEventID == groupID
        )
    }

    /// 组内区块只承担阶段辨识与 payload 展示，不再重复复制、耗时和折叠控件。
    private func debugRepoContextBlock(
        _ event: RAGDebugEvent,
        block: RAGDebugPayloadPresentation.Block
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: debugStageIcon(event.stage))
                    .font(iconFont(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(debugStageKey(event.stage))
                    .font(ragFont(.caption2, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            debugPayloadChunks(for: event, block: block)
        }
        .padding(.vertical, 8)
    }

    private func isRepoContextDebugStage(_ stage: RAGDebugEvent.Stage) -> Bool {
        switch stage {
        case .repoContextRequest, .repoContextResponse, .repoContextProjection:
            return true
        default:
            return false
        }
    }

    /// 仅检索诊断拥有稳定的结构化指标；Prompt、模型响应等自由文本可能含端口、模型版本或参数，
    /// 不应因其中出现数字而被误标为检索关键信息。
    private func debugPayloadText(
        for event: RAGDebugEvent,
        payload: String,
        rerankAppliedNotes: [String]
    ) -> Text {
        if event.retrievalPayload != nil {
            return highlightedDebugPayload(payload)
        }
        if event.rerankPayload != nil {
            return styledRerankDebugPayload(
                payload,
                notes: rerankAppliedNotes
            )
        }
        return Text(payload)
    }

    /// 每个 Text 都有严格体积上限，并由外层 ScrollView 的 LazyVStack 按视口挂载。
    /// 这样既保留选中/复制能力，也不会让一段超长 Prompt 独占整个窗口的主线程。
    @ViewBuilder
    private func debugPayloadChunks(
        for event: RAGDebugEvent,
        block: RAGDebugPayloadPresentation.Block
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(block.chunks.indices, id: \.self) { index in
                debugPayloadText(
                    for: event,
                    payload: block.displayText(at: index),
                    rerankAppliedNotes: block.rerankAppliedNotes
                )
                .font(ragFont(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Rerank 主体继续使用紧凑等宽字；仅汇总说明降一级为灰色备注，减少长 Trace 的视觉噪音。
    private func styledRerankDebugPayload(_ payload: String, notes: [String]) -> Text {
        let noteRanges = notes
            .compactMap { payload.range(of: $0) }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !noteRanges.isEmpty else { return Text(payload) }

        var result = Text("")
        var cursor = payload.startIndex
        for range in noteRanges {
            result = result + Text(String(payload[cursor..<range.lowerBound]))
            result = result + Text(String(payload[range]))
                .font(interfaceScale.font(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            cursor = range.upperBound
        }
        return result + Text(String(payload[cursor...]))
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

    /// 项目上下文组使用首个事件 ID 保存展开态；收起时清理组内所有旧事件状态，
    /// 避免热更新或历史视图状态让已合并的子阶段残留为独立展开项。
    private func toggleRepoContextDebugGroupExpansion(_ events: [RAGDebugEvent]) {
        guard let groupID = events.first?.id else { return }
        let eventIDs = Set(events.map(\.id))
        let isExpanded = expandedDebugEventIDs.contains(groupID)
        if isExpanded {
            // 正文尚未挂载完成时不允许折叠，与普通 stage 行同一把锁。
            guard !pendingExpandDebugEventIDs.contains(groupID) else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                expandedDebugEventIDs.subtract(eventIDs)
                ()
            }
            clearDebugEventExpandState(groupID)
            for eventID in eventIDs where eventID != groupID {
                clearDebugEventExpandState(eventID)
            }
            return
        }

        beginDebugEventExpand(groupID)
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
                for eventID in eventIDs {
                    clearDebugEventExpandState(eventID)
                }
            } else {
                expandedDebugTraceIDs.insert(trace.id)
            }
            ()
        }
    }

    /// 折叠可立刻切；展开先立刻打开壳子 + pending 锁，正文延后到下一帧挂载。
    private func toggleDebugEventExpansion(_ event: RAGDebugEvent) {
        let isExpanded = expandedDebugEventIDs.contains(event.id)
        if isExpanded {
            guard !pendingExpandDebugEventIDs.contains(event.id) else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                expandedDebugEventIDs.remove(event.id)
                ()
            }
            clearDebugEventExpandState(event.id)
            return
        }

        beginDebugEventExpand(event.id)
    }

    /// 统一展开入口：先展开 + 上锁，骨架占位；正文渲染完成前不能再点。
    private func beginDebugEventExpand(_ eventID: UUID) {
        guard !pendingExpandDebugEventIDs.contains(eventID) else { return }
        let generation = UUID()
        pendingExpandDebugEventIDs.insert(eventID)
        debugPayloadPresentations.removeValue(forKey: eventID)
        loadingDebugPayloadIDs.remove(eventID)
        debugPayloadLoadGenerations[eventID] = generation
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            expandedDebugEventIDs.insert(eventID)
            ()
        }

        // 兜底只解除交互锁，绝不能像旧实现一样强制挂载尚未准备好的巨型 Text；
        // 后台任务完成后仍可正常提交，用户也可以先折叠离开。
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard expandedDebugEventIDs.contains(eventID),
                  debugPayloadLoadGenerations[eventID] == generation else { return }
            finishPendingDebugEventExpand(eventID)
        }
    }

    /// 骨架出现后才开始后台准备。`RAGDebugEvent` 是 Sendable，字符串整理和分块可以安全
    /// 离开 MainActor；主线程最终只提交不可变快照，不承担 Prompt/XML 的同步构建成本。
    private func scheduleDebugPayloadPreparation(
        expansionID: UUID,
        events: [RAGDebugEvent]
    ) {
        guard expandedDebugEventIDs.contains(expansionID),
              debugPayloadPresentation(for: expansionID) == nil,
              !loadingDebugPayloadIDs.contains(expansionID) else { return }

        let generation = debugPayloadLoadGenerations[expansionID] ?? UUID()
        let localeIdentifier = locale.identifier
        debugPayloadLoadGenerations[expansionID] = generation
        loadingDebugPayloadIDs.insert(expansionID)

        Task { @MainActor in
            let presentation = await Task.detached(priority: .userInitiated) {
                RAGDebugPayloadPresentationBuilder.make(
                    expansionID: expansionID,
                    events: events,
                    localeIdentifier: localeIdentifier
                )
            }.value

            // 折叠/重开会换 generation；旧任务即使稍后返回，也只能被丢弃。
            guard debugPayloadLoadGenerations[expansionID] == generation else { return }
            loadingDebugPayloadIDs.remove(expansionID)
            guard expandedDebugEventIDs.contains(expansionID),
                  locale.identifier == localeIdentifier else { return }
            debugPayloadPresentations[expansionID] = presentation
        }
    }

    private func debugPayloadPresentation(
        for expansionID: UUID
    ) -> RAGDebugPayloadPresentation? {
        guard let presentation = debugPayloadPresentations[expansionID],
              presentation.localeIdentifier == locale.identifier else { return nil }
        return presentation
    }

    private func finishPendingDebugEventExpand(_ eventID: UUID) {
        pendingExpandDebugEventIDs.remove(eventID)
    }

    private func clearDebugEventExpandState(_ eventID: UUID) {
        pendingExpandDebugEventIDs.remove(eventID)
        debugPayloadPresentations.removeValue(forKey: eventID)
        loadingDebugPayloadIDs.remove(eventID)
        debugPayloadLoadGenerations.removeValue(forKey: eventID)
    }

    private func resetDebugExpansionState() {
        expandedDebugTraceIDs = []
        expandedDebugEventIDs = []
        pendingExpandDebugEventIDs = []
        debugPayloadPresentations = [:]
        loadingDebugPayloadIDs = []
        debugPayloadLoadGenerations = [:]
    }

    /// Debug 正文加载占位：行数短、不抢主线程，只表达「已展开、正在挂载」。
    @ViewBuilder
    private func debugPayloadLoadingSkeleton(lineCount: Int = 4) -> some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<lineCount, id: \.self) { index in
                    SkeletonBlock(
                        width: nil,
                        maxWidth: index == lineCount - 1 ? 160 : nil,
                        height: 8,
                        cornerRadius: 3,
                        phase: phase,
                        phaseOffset: Double(index) * 0.08,
                        palette: palette
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityLabel(Text("rag.workspace.conversation.loading"))
        }
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
        case .repoContextRequest: return "rag.workspace.debug.stage.repoContextRequest"
        case .repoContextResponse: return "rag.workspace.debug.stage.repoContextResponse"
        case .repoContextProjection: return "rag.workspace.debug.stage.repoContextProjection"
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
        case .repoContextRequest:
            return "shippingbox"
        case .repoContextResponse:
            return "doc.badge.gearshape"
        case .repoContextProjection:
            return "arrow.down.right.and.arrow.up.left"
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

    /// 原始问题 / 优化后的问题：值字号收到 caption（与「规划说明」正文一致），
    /// 保留原有主色与加粗；不设 lineLimit 并用 fixedSize 强制纵向撑开，
    /// 长问题直接换行完整展示，绝不尾部省略。
    func planQuestionValue(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(ragFont(.caption, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        case .repoContext:
            "rag.workspace.inspector.retrievalScore.formula.repoContext"
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
        case .repoContext:
            return String.l10n("rag.workspace.inspector.retrievalScore.formula.repoContext")
        }
    }

    func formattedScoreValue(_ value: Double, precision: Int) -> String {
        String(format: "%.\(precision)f", locale: locale, value)
    }

    /// 索引页主摘要只保留一份全库向量覆盖，避免“可用分片 / 已向量化 / 向量化阶段”
    /// 三处重复同一数字。标题沿用其他 Tab 的 callout semibold，数值与键值行保持 caption。
    var indexHealthSummary: some View {
        let status = viewModel.indexStatus
        let readyChunks = min(max(status.readyChunks, 0), max(status.totalChunks, 0))
        let totalChunks = max(status.totalChunks, 0)
        let fraction = totalChunks > 0 ? Double(readyChunks) / Double(totalChunks) : 0
        let hasFailure = status.failedChunks > 0
        let hasIssue = status.pendingChunks > 0 || status.staleChunks > 0
        let isHealthy = totalChunks > 0
            && readyChunks == totalChunks
            && !hasFailure
            && !hasIssue
        let tint: Color = hasFailure
            ? .red
            : (hasIssue ? .orange : (isHealthy ? .green : Color.accentColor))

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: isHealthy ? "checkmark.shield.fill" : "chart.bar.doc.horizontal")
                    .font(iconFont(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text("rag.workspace.index.health")
                    .font(ragFont(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(
                    fraction.formatted(
                        .percent
                            .precision(.fractionLength(0))
                            .locale(locale)
                    )
                )
                .font(ragFont(.caption, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 明确标注为「向量就绪」，与下方「关键词就绪」区分：两者是同一批分片的两种可检索能力，
                // 而非互斥集合，因此都以 total 为分母展示，避免用户误读为占比之和应为 100%。
                Text("rag.workspace.inspector.metadata.index.ready")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(readyChunks.formatted()) / \(totalChunks.formatted())")
                    .font(ragFont(.caption, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }

            // 关键词就绪来自元数据快照（indexStatus 不含该口径）；仅在有快照且存在仅关键词分片时展示，
            // 空库或纯向量库不显示，避免恒为 0 的噪声行。
            if let keywordReady = viewModel.knowledgeBaseMetadataSnapshot?.indexHealth.keywordOnlyChunks,
               keywordReady > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("rag.workspace.inspector.metadata.index.keywordReady")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(keywordReady.formatted()) / \(totalChunks.formatted())")
                        .font(ragFont(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                }
            }

            ProgressView(value: Double(readyChunks), total: Double(max(totalChunks, 1)))
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(tint)
                .scaleEffect(x: 1, y: 0.5, anchor: .center)
                .frame(maxWidth: .infinity)
                .frame(height: 7)
                .animation(.easeInOut(duration: 0.18), value: readyChunks)

            embeddingModelConfigurationRow
        }
    }

    /// 当前向量模型决定 ready/stale 口径。配置无效时不能留空，也不能继续把无效模型
    /// 当作当前模型展示；提供直达「AI 设置 → 模型配置 → 向量化」的恢复入口。
    @ViewBuilder
    var embeddingModelConfigurationRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("rag.browser.overview.model")
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let modelName = viewModel.configuredEmbeddingModelName {
                Text(modelName)
                    .font(ragFont(.caption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(modelName)
            } else {
                Button("rag.workspace.index.embeddingModel.configure") {
                    settingsNavigation("ai.embedding")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }

        if let issue = viewModel.embeddingConfigurationIssue {
            Text(issue.localizedDescription)
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var knowledgeRepositoryRow: some View {
        Button {
            viewModel.showKnowledgeBrowser(
                presentingWindow: NSApp.keyWindow,
                settingsNavigation: settingsNavigation
            )
        } label: {
            HStack(spacing: 8) {
                Text("rag.browser.overview.repositoryCoverage")
                    .font(ragFont(.caption))
                    .foregroundStyle(.primary)
                Spacer()
                indexRowValue("\(viewModel.indexStatus.indexedRepoCount)/\(viewModel.indexStatus.knowledgeRepoCount)")
                indexRowTrailingAffordance(systemImage: "arrow.up.right.square")
            }
            .padding(.horizontal, Self.indexRowHorizontalPadding)
            .padding(.vertical, Self.indexRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isKnowledgeRepositoryRowHovered ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .help("rag.browser.open")
        .onHover { isKnowledgeRepositoryRowHovered = $0 }
    }

    func indexIssueRow(
        _ kind: RAGIndexIssueKind,
        count: Int,
        color: Color,
        rowIndex: Int
    ) -> some View {
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
                HStack(spacing: 8) {
                    Text(indexIssueTitle(kind))
                        .font(ragFont(.caption))
                        .foregroundStyle(.primary)
                    Spacer()
                    indexRowValue("\(count)", color: count > 0 ? color : .secondary)
                    indexRowTrailingAffordance(systemImage: isExpanded ? "chevron.down" : "chevron.right")
                }
                .padding(.horizontal, Self.indexRowHorizontalPadding)
                .padding(.vertical, Self.indexRowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    hoveredIndexIssueKind == kind
                        ? Color.accentColor.opacity(0.08)
                        : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
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

    func indexRowValue(_ value: String, color: Color = .primary) -> some View {
        Text(value)
            .font(ragFont(.caption, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
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
                ForEach(Array(chunks.enumerated()), id: \.element.id) { indexedChunk in
                    indexIssueChunkRow(
                        kind,
                        chunk: indexedChunk.element,
                        rowIndex: indexedChunk.offset
                    )
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

    /// 三类问题分片共享同一列表结构：每一行只承载一个语义字段，避免窄 Inspector
    /// 把仓库名、来源和章节路径挤在同一行。斑马纹负责连续扫描，hover 只增强当前行。
    func indexIssueChunkRow(
        _ kind: RAGIndexIssueKind,
        chunk: RAGChunk,
        rowIndex: Int
    ) -> some View {
        let isHovered = chunk.id.map { hoveredIndexIssueChunkID == $0 } ?? false
        let section = chunk.sectionPath.isEmpty ? chunk.title : chunk.sectionPath

        return VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.knowledgeRepositoryName(for: chunk.repoId))
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(viewModel.knowledgeRepositoryName(for: chunk.repoId))

            (Text("rag.workspace.index.issues.sourcePrefix") + Text(indexIssueSourceTitle(chunk.source)))
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)

            Text(String(
                format: String.l10n("rag.workspace.index.issues.sectionFormat"),
                section
            ))
            .font(ragFont(.caption2))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(section)

            indexIssueReason(kind, chunk: chunk)
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            isHovered
                ? Color.accentColor.opacity(0.08)
                : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .onHover { hovering in
            if hovering {
                hoveredIndexIssueChunkID = chunk.id
            } else if hoveredIndexIssueChunkID == chunk.id {
                hoveredIndexIssueChunkID = nil
            }
        }
        .onDisappear {
            if hoveredIndexIssueChunkID == chunk.id {
                hoveredIndexIssueChunkID = nil
            }
        }
    }

    @ViewBuilder
    func indexIssueReason(_ kind: RAGIndexIssueKind, chunk: RAGChunk) -> some View {
        switch kind {
        case .pending:
            Text(String(
                format: String.l10n("rag.workspace.index.issues.reasonFormat"),
                pendingIndexIssueReason()
            ))
        case .failed:
            Text(String(
                format: String.l10n("rag.workspace.index.issues.reasonFormat"),
                userFacingEmbeddingFailure(chunk.embeddingError)
            ))
        case .stale:
            Text(String(
                format: String.l10n("rag.workspace.index.issues.reasonFormat"),
                String.l10n("rag.workspace.index.issues.staleReason")
            ))
            Text(String(
                format: String.l10n("rag.workspace.index.issues.previousModelFormat"),
                chunk.embeddingModel ?? String.l10n("rag.workspace.index.embeddingModel.unavailable")
            ))
            Text(String(
                format: String.l10n("rag.workspace.index.issues.currentModelFormat"),
                viewModel.configuredEmbeddingModelName
                    ?? String.l10n("rag.workspace.index.embeddingModel.unavailable")
            ))
        }
    }

    /// 一批 embedding 请求失败后 builder 会停止，尚未领取的分片仍是 pending。
    /// 这时“等待生成向量”会掩盖真正阻塞原因，应明确显示最近一次索引失败。
    func pendingIndexIssueReason() -> String {
        if let issue = viewModel.embeddingConfigurationIssue {
            return issue.localizedDescription
        }
        if case .failed(let lastFailure) = viewModel.indexingStatus {
            return String(
                format: String.l10n("rag.workspace.index.issues.pendingAfterFailureFormat"),
                userFacingEmbeddingFailure(lastFailure)
            )
        }
        return String.l10n("rag.workspace.index.issues.pendingReason")
    }

    /// 旧版本把 Provider 错误体的 SDK 解码失败原样存入 `embedding_error`，看起来像是
    /// 笔记正文格式损坏。该字段只记录向量化失败，因此在展示层将这类遗留文案迁移成
    /// 准确的模型响应错误；新的失败会直接保存 `AIEmbeddingError` 的友好描述。
    func userFacingEmbeddingFailure(_ storedError: String?) -> String {
        guard let storedError, !storedError.isEmpty else {
            return String.l10n("rag.workspace.index.issues.failedReason")
        }
        let normalized = storedError.lowercased()
        if normalized.contains("格式不正确") || normalized.contains("correct format") {
            return AIEmbeddingError.invalidResponse.localizedDescription
        }
        return storedError
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

    /// 最近构建与健康摘要分区：摘要回答“现在能否检索”，这里回答“最近一轮跑到哪一步”。
    /// 刷新入口固定在标题右侧，避免旧版按钮悬空在面板底部。
    var indexBuildSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("rag.workspace.index.recentBuild")
                    .font(ragFont(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let completedAt = viewModel.indexRefreshSummary?.completedAt {
                    Text(
                        completedAt.formatted(
                            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
                        )
                    )
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
                }
                SyncIconButton(
                    isRefreshing: viewModel.isIndexing,
                    disabled: viewModel.isIndexing,
                    font: ragFont(.caption),
                    frameSize: 18,
                    tooltip: String.l10n("rag.workspace.index.rebuild")
                ) {
                    viewModel.rebuildIndex()
                }
            }

            if let summary = viewModel.indexRefreshSummary {
                let activeStageID: String? = switch viewModel.indexingStatus {
                case .fetchingReadmes: "readme"
                case .building: "source"
                case .embedding: "embedding"
                case .idle, .completed, .failed: nil
                }
                let readmeComplete = summary.totalRepos > 0
                    && summary.readmesProcessed >= summary.totalRepos
                let sourceBuildComplete = summary.totalRepos > 0
                    && summary.sourceReposProcessed >= summary.totalRepos
                let embeddingComplete = summary.completedAt != nil
                    || (
                        summary.totalChunksAtEmbedding > 0
                        && summary.embeddingReadyChunks >= summary.totalChunksAtEmbedding
                    )

                VStack(alignment: .leading, spacing: 2) {
                    indexBuildStageRow(
                        id: "readme",
                        "rag.workspace.index.readmeShort",
                        value: "\(summary.readmesProcessed)/\(summary.totalRepos)",
                        rowIndex: 0,
                        isComplete: readmeComplete,
                        isActive: activeStageID == "readme"
                    )
                    indexBuildStageRow(
                        id: "source",
                        "rag.workspace.index.sourceBuild",
                        value: "\(summary.sourceReposProcessed)/\(summary.totalRepos)",
                        rowIndex: 1,
                        isComplete: sourceBuildComplete,
                        isActive: activeStageID == "source"
                    )
                    indexBuildStageRow(
                        id: "embedding",
                        "rag.workspace.index.embedding",
                        value: embeddingProgressValue(for: summary),
                        rowIndex: 2,
                        isComplete: embeddingComplete,
                        isActive: activeStageID == "embedding"
                    )
                }
            }
        }
    }

    /// 阶段标题 / 数字与计划 Tab 的键值行同为 caption；callout 只留给分组标题。
    func indexBuildStageRow(
        id: String,
        _ label: LocalizedStringKey,
        value: String,
        rowIndex: Int,
        isComplete: Bool,
        isActive: Bool
    ) -> some View {
        let tint: Color = isComplete ? .green : (isActive ? Color.accentColor : .secondary)
        let systemImage = isComplete
            ? "checkmark.circle.fill"
            : (isActive ? "circle.dotted" : "circle")

        return HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(iconFont(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13)
                .accessibilityHidden(true)
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(ragFont(.caption, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.horizontal, Self.indexRowHorizontalPadding)
        .padding(.vertical, Self.indexRowVerticalPadding)
        .background(
            hoveredIndexBuildStageID == id
                ? Color.accentColor.opacity(0.08)
                : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovered in
            if reduceMotion {
                hoveredIndexBuildStageID = isHovered
                    ? id
                    : (hoveredIndexBuildStageID == id ? nil : hoveredIndexBuildStageID)
            } else {
                withAnimation(.easeInOut(duration: 0.12)) {
                    hoveredIndexBuildStageID = isHovered
                        ? id
                        : (hoveredIndexBuildStageID == id ? nil : hoveredIndexBuildStageID)
                }
            }
        }
        .onDisappear {
            if hoveredIndexBuildStageID == id {
                hoveredIndexBuildStageID = nil
            }
        }
    }

    /// 对用户展示全库向量覆盖，而不是本轮待处理队列；这样无新增分片的刷新仍会显示 20,281/20,281。
    func embeddingProgressValue(for summary: RAGIndexRefreshSummary) -> String {
        guard summary.totalChunksAtEmbedding > 0 else {
            return "\(viewModel.indexStatus.readyChunks)/\(viewModel.indexStatus.totalChunks)"
        }
        return "\(summary.embeddingReadyChunks)/\(summary.totalChunksAtEmbedding)"
    }

    func localizedTimestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// 历史网络审计从 SQLite 读出 ISO8601 字符串；展示时再按当前 App 语言和时区格式化。
    /// 旧数据若无法解析则保留原值，避免为了视觉一致性吞掉可用于排查的信息。
    func localizedTimestamp(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = ISO8601DateFormatter.githubDate(from: value) else { return value }
        return localizedTimestamp(date)
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
        viewModel.conversationCitations
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

    var body: some View {
        EqualWidthSegmentedControl(
            items: tabs,
            selection: $selection,
            title: \.titleKey,
            font: font,
            controlHeight: 32
        )
    }
}
