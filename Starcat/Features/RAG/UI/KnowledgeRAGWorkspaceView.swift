//
//  KnowledgeRAGWorkspaceView.swift
//  Starcat
//
//  知识库 RAG 工作台的迁移期 UI 验证视图。
//
//  这个文件暂时不接 RAG 后端,但 UI 字段按后续真实数据契约设计:repo 元信息
//  来自现有本地库,引用证据来自未来 rag_chunks / Retriever。迁移验证阶段不展示
//  拿不到或只适合调试的检索内部字段。
//

import AppKit
import SwiftUI

struct KnowledgeRAGWorkspaceView: View {

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let onClose: () -> Void

    @State private var selectedConversationID: RAGDemoConversation.ID = RAGDemoData.conversations[0].id
    @State private var selectedCitationID: RAGDemoCitation.ID = RAGDemoData.citations[0].id
    @State private var draftQuestion: String = ""
    @State private var isStreaming: Bool = true
    @State private var didSendDemoQuestion: Bool = false
    @State private var isWindowPinned: Bool = false

    private var selectedCitation: RAGDemoCitation {
        RAGDemoData.citations.first { $0.id == selectedCitationID } ?? RAGDemoData.citations[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            conversationRail
                .frame(width: 318)
            Divider()
            answerSurface
                .layoutPriority(1)
            Divider()
            citationInspector
                .frame(minWidth: 390, idealWidth: 420, maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
    }

    // MARK: - Conversation Rail

    private var conversationRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                railTitle
                backButton
                statusBlock
                newConversationButton
            }
            .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近问答")
                        .font(ragFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                    ForEach(RAGDemoData.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.bottom, 18)
            }

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var railTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(ragIconFont(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("知识库问答")
                    .font(ragFont(.headline, weight: .semibold))
                Text("只读 · 本地知识库")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var backButton: some View {
        Button(action: onClose) {
            Label("关闭窗口", systemImage: "xmark")
                .font(ragFont(.callout, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusBlock: some View {
        VStack(spacing: 10) {
            statusRow(icon: "scope", label: "范围", value: "知识库")
            statusRow(icon: "shippingbox", label: "仓库", value: "126 repos")

            VStack(alignment: .leading, spacing: 6) {
                statusRow(icon: "square.stack.3d.up", label: "Ready chunks", value: "1,248")
                ProgressView(value: 0.92)
                    .tint(Color.accentColor)
                    .controlSize(.small)
            }

            statusRow(icon: "doc.text.magnifyingglass", label: "来源", value: "README / 笔记 / 摘要")
            statusRow(icon: "lock", label: "模式", value: "只读")
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(ragIconFont(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var newConversationButton: some View {
        Button {
            selectedConversationID = RAGDemoData.conversations[0].id
            selectedCitationID = RAGDemoData.citations[0].id
            draftQuestion = ""
            didSendDemoQuestion = false
            isStreaming = true
        } label: {
            Label("新会话", systemImage: "plus.circle.fill")
                .font(ragFont(.callout, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private func conversationRow(_ conversation: RAGDemoConversation) -> some View {
        let isSelected = conversation.id == selectedConversationID
        return Button {
            selectedConversationID = conversation.id
            selectedCitationID = RAGDemoData.citations[conversation.citationIndex].id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left")
                    .font(ragIconFont(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(ragFont(.callout, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(conversation.subtitle)
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Text(conversation.time)
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 10)
    }

    // MARK: - Answer Surface

    private var answerSurface: some View {
        VStack(spacing: 0) {
            answerHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    questionBubble
                    answerBlock
                    if didSendDemoQuestion {
                        pendingQuestionBlock
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            commandComposer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var answerHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("知识库问答")
                    .font(ragFont(.headline, weight: .semibold))
                Text("知识库 · 126 repos · 1,248 ready chunks · GPT-4.1 · 只读")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            headerChip("Knowledge", systemImage: "books.vertical", tint: .blue)
            headerChip("GPT-4.1", systemImage: "sparkles", tint: .purple)
            headerChip(isStreaming ? "Streaming" : "Ready", systemImage: "dot.radiowaves.left.and.right", tint: .green)

            Button(action: { isStreaming.toggle() }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(ragIconFont(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)

        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private func headerChip(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        )
    }

    private var questionBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 90)
            VStack(alignment: .trailing, spacing: 6) {
                Text("我的知识库里有哪些适合做本地 RAG 的 Swift 项目？")
                    .font(ragFont(.body))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                Text("09:41")
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var answerBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cat")
                .font(ragIconFont(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 16) {
                Text("根据知识库中的 repo 元信息、README chunk、笔记和已有摘要，当前最相关的是下面几个 Swift 项目。每个项目都绑定了本轮回答实际使用的引用。")
                    .font(ragFont(.body))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)

                repoBundleList

                Text("如果只做第一版本地 RAG，优先从 GRDB.swift 的本地存储能力和 swift-markdown 的文档解析能力开始；MCP Swift SDK 更适合作为后续工具调用扩展。")
                    .font(ragFont(.body))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)

                citationChips

                HStack(spacing: 10) {
                    iconAction("doc.on.doc")
                    iconAction("hand.thumbsup")
                    iconAction("hand.thumbsdown")
                    Spacer()
                    Text("09:41")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var repoBundleList: some View {
        VStack(spacing: 10) {
            ForEach(RAGDemoData.repoBundles) { bundle in
                repoBundleRow(bundle)
            }
        }
    }

    private func repoBundleRow(_ bundle: RAGDemoRepoBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: bundle.localDetailAvailable ? "shippingbox.fill" : "globe")
                    .font(ragIconFont(size: 14, weight: .semibold))
                    .foregroundStyle(bundle.localDetailAvailable ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(bundle.fullName)
                        .font(ragFont(.callout, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(bundle.description)
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)
                Text(bundle.status)
                    .font(ragFont(.caption2, weight: .semibold))
                    .foregroundStyle(bundle.localDetailAvailable ? Color.accentColor : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((bundle.localDetailAvailable ? Color.accentColor : Color.primary).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                metadataPill(bundle.language, systemImage: "circle.fill")
                metadataPill("\(bundle.stars) stars", systemImage: "star")
                metadataPill(bundle.sources.joined(separator: " / "), systemImage: "doc.text")
                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(bundle.citationIDs, id: \.self) { citationID in
                    if let citation = RAGDemoData.citations.first(where: { $0.id == citationID }) {
                        citationButton(citation)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func metadataPill(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .font(ragFont(.caption2, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private var citationChips: some View {
        HStack(spacing: 8) {
            ForEach(RAGDemoData.citations) { citation in
                Button {
                    selectedCitationID = citation.id
                } label: {
                    citationChipContent(citation)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    private func citationButton(_ citation: RAGDemoCitation) -> some View {
        Button {
            selectedCitationID = citation.id
        } label: {
            citationChipContent(citation)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func citationChipContent(_ citation: RAGDemoCitation) -> some View {
        HStack(spacing: 5) {
            Text("[\(citation.rank)]")
                .font(ragFont(.caption2, weight: .bold, design: .monospaced))
            Text(citation.source)
                .lineLimit(1)
            Text("\(Int(citation.score * 100))%")
                .foregroundStyle(citation.id == selectedCitationID ? Color.accentColor : .secondary)
        }
        .font(ragFont(.caption2, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(citation.id == selectedCitationID ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(citation.id == selectedCitationID ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func iconAction(_ systemName: String) -> some View {
        Button {} label: {
            Image(systemName: systemName)
                .font(ragIconFont(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
    }

    private var pendingQuestionBlock: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 90)
            Text(draftQuestion.isEmpty ? "继续追问知识库..." : draftQuestion)
                .font(ragFont(.body))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var commandComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                composerChip("Scope: 知识库", systemImage: "books.vertical")
                composerChip("Sources: README / Notes / Summary", systemImage: "doc.text.magnifyingglass")
                composerChip("Model: GPT-4.1", systemImage: "sparkles")
                Spacer()
            }

            HStack(spacing: 10) {
                Button {} label: {
                    Image(systemName: "paperclip")
                        .font(ragIconFont(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)

                TextField("继续追问知识库...", text: $draftQuestion)
                    .textFieldStyle(.plain)
                    .font(ragFont(.body))
                    .onSubmit(sendDemoQuestion)

                Button(action: sendDemoQuestion) {
                    Image(systemName: "arrow.up")
                        .font(ragIconFont(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func composerChip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(ragFont(.caption2, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sendDemoQuestion() {
        guard !draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            didSendDemoQuestion = true
            isStreaming = false
        }
    }

    // MARK: - Citation Inspector

    private var citationInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selectedCitationSummary
                    chunkPreview
                    otherCitations
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("引用")
                    .font(ragFont(.headline, weight: .semibold))
                Text("本轮回答实际使用的来源")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                toggleWindowPinned()
            } label: {
                Image(systemName: isWindowPinned ? "pin.fill" : "pin")
                    .font(ragIconFont(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(isWindowPinned ? Color.accentColor : .secondary)
            .help(isWindowPinned ? "取消窗口置顶" : "置顶窗口")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func toggleWindowPinned() {
        guard let window = NSApp.keyWindow else { return }
        let nextPinned = !isWindowPinned
        window.level = nextPinned ? .floating : .normal
        isWindowPinned = nextPinned
    }

    private var selectedCitationSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(ragIconFont(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCitation.repo)
                        .font(ragFont(.subheadline, weight: .semibold))
                    Text(selectedCitation.fullName)
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            inspectorFact("来源", selectedCitation.source, badgeTint: .blue)
            inspectorFact("位置", selectedCitation.sectionPath, badgeTint: .primary, isNeutral: true)
            inspectorFact("相关度", "\(Int(selectedCitation.score * 100))%", badgeTint: .green)
            inspectorFact("详情页", selectedCitation.localDetailAvailable ? "Starcat 本地详情" : "GitHub", badgeTint: selectedCitation.localDetailAvailable ? .accentColor : .secondary)

            Button {
                NSWorkspace.shared.open(selectedCitation.githubURL)
            } label: {
                HStack {
                    Text(selectedCitation.localDetailAvailable ? "打开 Starcat 详情" : "打开 GitHub")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                }
                .font(ragFont(.callout, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func inspectorFact(_ label: String, _ value: String, badgeTint: Color, isNeutral: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(isNeutral ? AnyShapeStyle(.primary) : AnyShapeStyle(badgeTint))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((isNeutral ? Color.primary : badgeTint).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var chunkPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("引用片段")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(selectedCitation.sourceDetail)
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedCitation.title)
                        .font(ragFont(.callout, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(selectedCitation.parentTitle)
                        .font(ragFont(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Text(selectedCitation.snippet)
                    .font(ragFont(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if selectedCitation.isTruncated {
                    Label("片段已按 token 预算截断", systemImage: "scissors")
                        .font(ragFont(.caption2, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var otherCitations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("其它引用")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(RAGDemoData.citations) { citation in
                Button {
                    selectedCitationID = citation.id
                } label: {
                    HStack(spacing: 9) {
                        Text("\(citation.rank)")
                            .font(ragFont(.caption2, weight: .bold, design: .monospaced))
                            .foregroundStyle(citation.id == selectedCitationID ? .white : .secondary)
                            .frame(width: 20, height: 20)
                            .background(citation.id == selectedCitationID ? Color.accentColor : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(citation.sectionPath)
                                .font(ragFont(.caption, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(citation.fullName) · \(citation.source)")
                                .font(ragFont(.caption2))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                        Text("\(Int(citation.score * 100))%")
                            .font(ragFont(.caption, weight: .semibold, design: .monospaced))
                            .foregroundStyle(citation.id == selectedCitationID ? Color.accentColor : .secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(9)
                    .background(citation.id == selectedCitationID ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    // MARK: - Typography

    private enum RAGFontRole {
        case headline
        case subheadline
        case body
        case callout
        case caption
        case caption2

        /// Maps local workspace roles onto the shared `DESIGN.md` typography tokens.
        var typography: StarcatTypography {
            switch self {
            case .headline:    return .panelTitle
            case .subheadline: return .rowTitle
            case .body:        return .body
            case .callout:     return .bodyEmphasis
            case .caption:     return .caption
            case .caption2:    return .captionSmall
            }
        }
    }

    private func ragFont(
        _ role: RAGFontRole,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func ragIconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }
}
