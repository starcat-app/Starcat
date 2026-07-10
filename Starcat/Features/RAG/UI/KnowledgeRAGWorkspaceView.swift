//
//  KnowledgeRAGWorkspaceView.swift
//  Starcat
//
//  知识库 RAG 的真实三栏工作台：会话历史、问答时间线、证据/计划/索引 Inspector。
//
//  工作台遵循主窗口与 Agent Workspace 的同一视觉契约。输入框显式承载 @repo、模型和
//  附件；Issues 等远程上下文只在 Planner 命中后进入确认流程，不提供 slash command。
//

import AppKit
import SwiftUI

struct KnowledgeRAGWorkspaceView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let chromeState: WorkspaceChromeState
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var inspectorTab: RAGInspectorTab = .evidence

    var body: some View {
        HStack(spacing: 0) {
            if !chromeState.isLeftColumnCollapsed {
                conversationRail
                    .frame(width: 286)
                Divider()
            }

            answerSurface
                .layoutPriority(1)

            if !chromeState.isRightColumnCollapsed {
                Divider()
                inspector
                    .frame(minWidth: 320, idealWidth: 356, maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeKnowledgeBoundaryChanges() }
        .task { await viewModel.observeIndexChanges() }
        .environment(\.openURL, OpenURLAction { url in
            viewModel.handleLink(url)
            return .handled
        })
        .alert(
            "rag.workspace.error.title",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("common.ok") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isLeftColumnCollapsed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }

    // MARK: - Conversation rail

    private var conversationRail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "text.book.closed.fill")
                        .font(iconFont(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("rag.workspace.title")
                            .font(ragFont(.headline, weight: .semibold))
                        Text("rag.workspace.subtitle")
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                indexSummary

                Button {
                    Task { await viewModel.newConversation() }
                } label: {
                    Label("rag.workspace.newConversation", systemImage: "plus")
                        .font(ragFont(.callout, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text("rag.workspace.recentConversations")
                        .font(ragFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                    ForEach(viewModel.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
    }

    private var indexSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("rag.workspace.status.knowledgeBase", systemImage: "books.vertical")
                    .font(ragFont(.caption, weight: .semibold))
                Spacer()
                Text("\(viewModel.indexCoverage.indexedRepoCount)/\(viewModel.indexCoverage.knowledgeRepoCount)")
                    .font(ragFont(.caption, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: viewModel.indexCoverage.fraction)
                .progressViewStyle(.linear)
            HStack {
                Text(String(format: String.l10n("rag.workspace.status.readyChunksFormat"), viewModel.indexCoverage.readyChunks))
                Spacer()
                if viewModel.indexCoverage.pendingChunks + viewModel.indexCoverage.failedChunks + viewModel.indexCoverage.staleChunks > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("rag.workspace.status.indexIncomplete")
                }
            }
            .font(ragFont(.caption2))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    }

    private func conversationRow(_ conversation: RAGConversationSummary) -> some View {
        let selected = conversation.id == viewModel.selectedConversationID
        return HStack(spacing: 0) {
            Button {
                Task { await viewModel.selectConversation(conversation.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "bubble.left")
                        .font(iconFont(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .font(ragFont(.callout, weight: selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(String(conversation.updatedAt.prefix(10)))
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Menu {
                Button("common.delete", role: .destructive) {
                    Task { await viewModel.deleteConversation(conversation.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(iconFont(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .help("rag.workspace.conversation.actions")
            .padding(.trailing, 6)
        }
        .background(selected ? Color.accentColor.opacity(0.11) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 8)
    }

    // MARK: - Answer surface

    private var answerSurface: some View {
        VStack(spacing: 0) {
            answerHeader
            Divider()
            messageTimeline
            if !viewModel.pendingRemoteRequests.isEmpty {
                Divider()
                remoteConfirmation
            }
            Divider()
            commandComposer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var answerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.conversations.first(where: { $0.id == viewModel.selectedConversationID })?.title ?? String.l10n("rag.workspace.newConversation"))
                    .font(ragFont(.headline, weight: .semibold))
                    .lineLimit(1)
                Text(stateText(viewModel.answerState))
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            headerChip(String.l10n("rag.workspace.header.knowledge"), icon: "books.vertical", tint: .blue)
            headerChip(viewModel.selectedModelDisplayName, icon: "sparkles", tint: .purple)
            if viewModel.isAnswering {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private func headerChip(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(ragFont(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if viewModel.messages.isEmpty && viewModel.streamingAnswer.isEmpty {
                        emptyConversation
                    }
                    ForEach(viewModel.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }
                    if !viewModel.streamingAnswer.isEmpty {
                        assistantMessage(content: viewModel.streamingAnswer, citations: [])
                            .id("streaming-answer")
                    } else if viewModel.isAnswering {
                        workingIndicator
                            .id("working-indicator")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.streamingAnswer) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo("streaming-answer", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let id = viewModel.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(iconFont(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("rag.workspace.empty.title")
                .font(ragFont(.headline, weight: .semibold))
            Text("rag.workspace.empty.subtitle")
                .font(ragFont(.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.top, 36)
    }

    @ViewBuilder
    private func messageView(_ message: RAGStoredMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .font(ragFont(.body))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 680, alignment: .trailing)
            }
        } else {
            assistantMessage(content: message.content, citations: message.citations)
        }
    }

    private func assistantMessage(content: String, citations: [RAGCitation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("rag.workspace.message.assistant")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { viewModel.copyAnswer(content) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("rag.workspace.answer.copy")
                Button { viewModel.exportAnswer(content) } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("rag.workspace.answer.export")
            }
            RAGMarkdownText(content: content)
                .font(ragFont(.body))
                .textSelection(.enabled)
                .frame(maxWidth: 900, alignment: .leading)
            if !citations.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                            Button {
                                viewModel.selectCitation(citation)
                                inspectorTab = .evidence
                            } label: {
                                Label("S\(index + 1) · \(citation.repoFullName)", systemImage: "quote.opening")
                                    .font(ragFont(.caption, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var workingIndicator: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(stateText(viewModel.answerState))
                .font(ragFont(.callout))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var remoteConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("rag.workspace.remote.confirmTitle", systemImage: "network")
                    .font(ragFont(.callout, weight: .semibold))
                Spacer()
                Button("rag.workspace.remote.skip") { viewModel.skipRemoteContext() }
                    .buttonStyle(.borderless)
                Button("rag.workspace.remote.continue") { viewModel.confirmRemoteContext() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.approvedRemoteResources.isEmpty)
            }
            RAGFlowLayout(spacing: 7) {
                ForEach(viewModel.pendingRemoteRequests, id: \.resource) { request in
                    let enabled = viewModel.approvedRemoteResources.contains(request.resource)
                    Button {
                        viewModel.toggleRemoteResource(request.resource)
                    } label: {
                        Label(remoteResourceName(request.resource), systemImage: enabled ? "checkmark.circle.fill" : "circle")
                            .font(ragFont(.caption, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(enabled ? .orange : .gray)
                    .help(request.reason)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.07))
    }

    // MARK: - Composer

    private var commandComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.selectedRepoContexts.isEmpty || !viewModel.attachments.isEmpty || !viewModel.githubLinkContexts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(viewModel.selectedRepoContexts) { repo in
                            contextChip(title: "@\(repo.fullName)", icon: "shippingbox") {
                                viewModel.removeMention(repoID: repo.id)
                            }
                        }
                        ForEach(viewModel.attachments) { attachment in
                            contextChip(title: attachmentChipTitle(attachment), icon: attachmentIcon(attachment)) {
                                viewModel.removeAttachment(attachment.id)
                            }
                        }
                        ForEach(viewModel.githubLinkContexts, id: \.url) { reference in
                            contextChip(title: "\(reference.owner)/\(reference.repo)", icon: "link") {
                                viewModel.removeGitHubLink(reference.url)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let reason = viewModel.composerBlockingReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }

            ZStack(alignment: .topLeading) {
                if viewModel.draftQuestion.isEmpty {
                    Text("rag.workspace.composer.placeholder")
                        .font(ragFont(.body))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $viewModel.draftQuestion)
                    .font(ragFont(.body))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 118)
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.command) {
                            viewModel.send()
                            return .handled
                        }
                        return .ignored
                    }
                    .onChange(of: viewModel.draftQuestion) { _, _ in
                        viewModel.scheduleGitHubLinkDetection()
                    }
            }
            .popover(
                isPresented: Binding(
                    get: { viewModel.mentionQuery != nil && !viewModel.mentionSuggestions.isEmpty },
                    set: { _ in }
                ),
                arrowEdge: .bottom
            ) {
                mentionPicker
            }

            HStack(spacing: 8) {
                Button { viewModel.chooseAttachments() } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("rag.workspace.composer.attach")

                modelMenu

                if !viewModel.selectedRepoContexts.isEmpty {
                    explicitModeMenu
                }

                Spacer()

                if viewModel.isAnswering {
                    Button { viewModel.cancelAnswer() } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help("rag.workspace.composer.cancel")
                } else {
                    Button { viewModel.send() } label: {
                        Image(systemName: "arrow.up")
                            .font(iconFont(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        viewModel.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.composerBlockingReason != nil
                    )
                    .help("rag.workspace.composer.send")
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func contextChip(title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.remove")
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var mentionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("rag.workspace.mention.title")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.mentionSuggestions) { repo in
                        Button { viewModel.selectMention(repo) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.fullName)
                                        .font(ragFont(.callout, weight: .semibold))
                                    Text(repo.description ?? String.l10n("rag.workspace.mention.noDescription"))
                                        .font(ragFont(.caption))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 360, height: min(CGFloat(viewModel.mentionSuggestions.count) * 54 + 42, 360))
    }

    private var modelMenu: some View {
        Menu {
            ForEach(viewModel.availableModels) { model in
                Button {
                    viewModel.selectedModelID = model.id
                } label: {
                    if viewModel.selectedModelID == model.id {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            Label(viewModel.selectedModelDisplayName, systemImage: "sparkles")
                .font(ragFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("rag.workspace.composer.model")
    }

    private var explicitModeMenu: some View {
        Menu {
            modeButton(.only, key: "rag.workspace.repoMode.only")
            modeButton(.prefer, key: "rag.workspace.repoMode.prefer")
            modeButton(.exclude, key: "rag.workspace.repoMode.exclude")
        } label: {
            Label(repoModeName(viewModel.explicitRepoMode), systemImage: "scope")
                .font(ragFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func modeButton(_ mode: RAGExplicitRepoMode, key: String) -> some View {
        Button {
            viewModel.explicitRepoMode = mode
        } label: {
            if viewModel.explicitRepoMode == mode {
                Label(key, systemImage: "checkmark")
            } else {
                Text(key)
            }
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("rag.workspace.inspector.title")
                    .font(ragFont(.headline, weight: .semibold))
                Picker("", selection: $inspectorTab) {
                    ForEach(RAGInspectorTab.allCases) { tab in
                        Text(tab.titleKey).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(14)
            Divider()

            ScrollView {
                switch inspectorTab {
                case .evidence: evidenceInspector
                case .plan: planInspector
                case .index: indexInspector
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
    }

    private var evidenceInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let citation = viewModel.selectedCitation {
                VStack(alignment: .leading, spacing: 9) {
                    Text(citation.repoFullName)
                        .font(ragFont(.subheadline, weight: .semibold))
                    inspectorValue("rag.workspace.inspector.source", value: citation.source.rawValue)
                    inspectorValue("rag.workspace.inspector.location", value: citation.sectionTitle)
                    inspectorValue("rag.workspace.inspector.matchType", value: citation.hitKind.rawValue)
                    inspectorValue("rag.workspace.inspector.relevance", value: String(format: "%.3f", citation.score))
                    if let chunk = viewModel.selectedCitationChunk {
                        Text("rag.workspace.inspector.chunkPreview")
                            .font(ragFont(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(chunk.content)
                            .font(ragFont(.caption))
                            .textSelection(.enabled)
                            .lineLimit(12)
                        if chunk.isTruncated {
                            Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                                .font(ragFont(.caption))
                                .foregroundStyle(.orange)
                        }
                    }
                    if citation.chunkID == nil {
                        Label("rag.workspace.inspector.chunkMissing", systemImage: "exclamationmark.triangle.fill")
                            .font(ragFont(.caption))
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("rag.workspace.inspector.openStarcat") { viewModel.openCitation(citation) }
                        Button("rag.workspace.inspector.openGitHub") { viewModel.openGitHub(citation) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.bottom, 2)
                Divider()
            }

            Text("rag.workspace.inspector.otherCitations")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(allCitations) { citation in
                Button {
                    viewModel.selectCitation(citation)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(citation.repoFullName)
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(citation.source.rawValue) · \(citation.sectionTitle)")
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            if !viewModel.remoteBlocks.isEmpty {
                Divider()
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
                            value: block.fetchedAt.formatted(date: .abbreviated, time: .shortened)
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var planInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan = viewModel.queryPlan {
                inspectorValue("rag.workspace.inspector.planMode", value: plan.mode.rawValue)
                inspectorValue("rag.workspace.inspector.semanticQuery", value: plan.semanticQuery)
                inspectorValue("rag.workspace.inspector.confidence", value: plan.confidence.rawValue)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var indexInspector: some View {
        VStack(alignment: .leading, spacing: 13) {
            coverageRow("rag.workspace.status.repos", value: "\(viewModel.indexCoverage.indexedRepoCount)/\(viewModel.indexCoverage.knowledgeRepoCount)", color: .blue)
            coverageRow("rag.workspace.status.readyChunks", value: "\(viewModel.indexCoverage.readyChunks)", color: .green)
            coverageRow("rag.workspace.status.pendingChunks", value: "\(viewModel.indexCoverage.pendingChunks)", color: .orange)
            coverageRow("rag.workspace.status.failedChunks", value: "\(viewModel.indexCoverage.failedChunks)", color: .red)
            coverageRow("rag.workspace.status.staleChunks", value: "\(viewModel.indexCoverage.staleChunks)", color: .purple)
            Divider()
            HStack {
                Spacer()
                Button {
                    viewModel.rebuildIndex()
                } label: {
                    Label(
                        viewModel.isIndexing ? "rag.workspace.index.rebuilding" : "rag.workspace.index.rebuild",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(viewModel.isIndexing)
            }
        }
        .padding(14)
    }

    private func inspectorValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(ragFont(.callout, weight: .semibold))
                .textSelection(.enabled)
        }
    }

    private func coverageRow(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(ragFont(.callout))
            Spacer()
            Text(value)
                .font(ragFont(.callout, weight: .semibold, design: .monospaced))
        }
    }

    private var allCitations: [RAGCitation] {
        var seen = Set<UUID>()
        return viewModel.messages.flatMap(\.citations).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Display helpers

    private func stateText(_ state: RAGAnswerState) -> String {
        switch state {
        case .idle, .completed: return String.l10n("rag.workspace.header.ready")
        case .planning: return String.l10n("rag.workspace.state.planning")
        case .needsClarification: return String.l10n("rag.workspace.state.needsClarification")
        case .noKnowledgeRepos: return String.l10n("rag.workspace.state.noKnowledgeRepos")
        case .noCandidates: return String.l10n("rag.workspace.state.noCandidates")
        case .noIndex: return String.l10n("rag.workspace.state.noIndex")
        case .noRelevantChunks: return String.l10n("rag.workspace.state.noRelevantChunks")
        case .retrieving: return String.l10n("rag.workspace.state.retrieving")
        case .awaitingRemoteContextConfirmation: return String.l10n("rag.workspace.state.awaitingRemote")
        case .fetchingRemoteContext: return String.l10n("rag.workspace.state.fetchingRemote")
        case .generating: return String.l10n("rag.workspace.state.generating")
        case .cancelled: return String.l10n("rag.workspace.state.cancelled")
        case .failed(let message): return message
        }
    }

    private func repoModeName(_ mode: RAGExplicitRepoMode) -> String {
        switch mode {
        case .only: return String.l10n("rag.workspace.repoMode.only")
        case .prefer: return String.l10n("rag.workspace.repoMode.prefer")
        case .exclude: return String.l10n("rag.workspace.repoMode.exclude")
        }
    }

    private func remoteResourceName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        }
    }

    private func attachmentChipTitle(_ attachment: RAGComposerAttachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: attachment.sizeInBytes, countStyle: .file)
        let handling: String
        switch attachment.handling {
        case .textContext: handling = String.l10n("rag.workspace.attachment.textContext")
        case .vision: handling = String.l10n("rag.workspace.attachment.vision")
        case .unsupported: handling = String.l10n("rag.workspace.attachment.unsupported")
        }
        return "\(attachment.filename) · \(attachment.contentType) · \(handling) · \(size)"
    }

    private func attachmentIcon(_ attachment: RAGComposerAttachment) -> String {
        switch attachment.handling {
        case .textContext: return "doc"
        case .vision: return "photo"
        case .unsupported: return "exclamationmark.triangle"
        }
    }

    private enum RAGFontRole {
        case headline, subheadline, body, callout, caption, caption2

        var typography: StarcatTypography {
            switch self {
            case .headline: return .panelTitle
            case .subheadline: return .rowTitle
            case .body: return .body
            case .callout: return .bodyEmphasis
            case .caption: return .caption
            case .caption2: return .captionSmall
            }
        }
    }

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }
}

private enum RAGInspectorTab: String, CaseIterable, Identifiable {
    case evidence
    case plan
    case index

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .evidence: return "rag.workspace.inspector.tab.evidence"
        case .plan: return "rag.workspace.inspector.tab.plan"
        case .index: return "rag.workspace.inspector.tab.index"
        }
    }
}

private struct RAGMarkdownText: View {
    let content: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: content) {
            Text(attributed)
        } else {
            Text(content)
        }
    }
}

/// 少量 query/context chips 的紧凑换行布局，避免固定 HStack 在右侧 Inspector 中截断。
private struct RAGFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: min(usedWidth, maxWidth), height: y + lineHeight), points)
    }
}
