//
//  RepoAIWindowContentView.swift
//  Starcat
//
//  详情页 AI 助手窗口的 SwiftUI 内容（HOM-150）。
//
//  模块职责：
//  - 把"AI 摘要"和"AI 对话"放在同一个浮动窗口里，但状态完全独立：
//    重新生成摘要不会清空对话；发送消息不会丢失摘要。
//  - 三段布局：顶部摘要（限高 + 内部滚动）→ 分隔线 → 中部对话列表（撑满剩余高度）
//    → 分隔线 → 底部输入条。
//  - 摘要部分复用既有的 `RepoAIInsightViewModel`（生成 / 缓存 / 标签推荐三段），
//    对话部分由新的 `RepoAIChatViewModel` 承担。
//
//  关键约束：
//  - 摘要"重新生成"和"复制"按钮的行为复用 `RepoAIInsightViewModel`（既有 VM 不改动），
//    UI 只是把这两个动作单独拎出来放在顶部右上角，让对话区域不被它们盖住。
//  - 对话列表在新增 message 时要自动滚到底部（ScrollViewReader + scrollTo），
//    否则用户得手动拖滚动条。
//  - 错误条采用克制橙色样式；两个 VM 各自的 errorMessage 都留位置（chat 失败不应
//    隐藏摘要错误，反之亦然）。
//
//  历史背景：本视图是 HOM-150 引入的新交互；旧的"详情页内嵌 AI tab"
//  （RepoAIInsightPanel.swift）已被替换并随该迭代删除。
//

import SwiftUI

struct RepoAIWindowContentView: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel

    @State private var insightVM: RepoAIInsightViewModel?
    @State private var chatVM: RepoAIChatViewModel?

    var body: some View {
        VStack(spacing: 0) {
            summarySection
                .frame(maxWidth: .infinity)
                // 摘要段限高 + 内部 ScrollView，避免长摘要把对话区压扁到几乎不可用。
                // 280pt 是经验值：刚好露出"一句话总结 + 项目说明" 2~3 行，再多需要
                // 用户拖摘要内部滚动条往下读。
                .frame(maxHeight: 280)

            Divider()

            chatSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            AIChatInputView(
                text: chatInputBinding,
                isSending: chatVM?.isSending ?? false,
                onSend: sendChatMessage
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .task(id: repo.id) {
            await initializeViewModelsIfNeeded()
            await insightVM?.load(repo: repo)
        }
    }

    // MARK: - 初始化

    /// 首次进入窗口时构造两个 VM。
    ///
    /// 用 `@State` 包一层而不是在 init 里直接创建，是因为 SwiftUI struct init 不能
    /// 安全地访问 @Environment（环境在 body 求值时才注入）；放进 `.task` 拿到环境
    /// 后再创建可靠得多。
    private func initializeViewModelsIfNeeded() async {
        if insightVM == nil {
            let ivm = RepoAIInsightViewModel(
                service: dependencies.repoAIInsightService,
                tagRepository: dependencies.tagRepository,
                repoTagRepository: dependencies.repoTagRepository
            )
            // 与旧详情页 AI Tab 行为一致：应用标签后刷新主窗 Sidebar + 列表。
            // 窗口可能独立于主窗存在，但 HomeViewModel 是同一实例，刷新调用安全。
            ivm.onTagsChanged = { [weak homeViewModel] in
                Task {
                    await homeViewModel?.refreshSidebar()
                    await homeViewModel?.reloadItems()
                }
            }
            insightVM = ivm
        }
        if chatVM == nil {
            chatVM = RepoAIChatViewModel(service: dependencies.repoAIInsightService)
        }
    }

    // MARK: - 摘要段

    @ViewBuilder
    private var summarySection: some View {
        if let vm = insightVM {
            VStack(alignment: .leading, spacing: 0) {
                summaryHeader(vm: vm)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = vm.errorMessage {
                            errorBanner(message: error)
                        }

                        if vm.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在读取本地 AI 缓存…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let draft = vm.streamingSummaryText, !draft.isEmpty {
                            streamingSummary(draft)
                        } else if let insight = vm.insight {
                            insightContent(insight, vm: vm)
                        } else {
                            emptySummaryState(vm: vm)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("初始化中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summaryHeader(vm: RepoAIInsightViewModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Label("AI 摘要", systemImage: "sparkles")
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)

            Spacer()

            // "重新生成"/"复制"按钮只在已有 insight 且非加载中时显示，避免重复触发。
            if let insight = vm.insight, !vm.isGenerating {
                Button {
                    copySummaryToClipboard(insight)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("复制摘要到剪贴板")

                Button {
                    Task { await vm.generate(repo: repo) }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("重新生成摘要（不影响对话）")
            } else if vm.isGenerating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 只复制摘要 markdown，不带对话 / 推荐标签，与 HOM-150 验收要求一致。
    private func copySummaryToClipboard(_ insight: RepoAIInsight) {
        let content = (insight.summaryMarkdown ?? insight.summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    @ViewBuilder
    private func emptySummaryState(vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("尚未生成 AI 摘要")
                .font(.subheadline.weight(.semibold))
            Text("可以直接在下方对话区追问；如需结构化摘要，点击右侧「生成摘要」。摘要会读取本仓库的元数据、README、topics 并以 Markdown 输出。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await vm.generate(repo: repo) }
            } label: {
                if vm.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("生成摘要", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
            .disabled(vm.isGenerating)
        }
    }

    private func streamingSummary(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在生成 AI 摘要…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RepoAISummaryMarkdownView(markdown: text)
        }
    }

    @ViewBuilder
    private func insightContent(_ insight: RepoAIInsight, vm: RepoAIInsightViewModel) -> some View {
        RepoAISummaryMarkdownView(markdown: insight.summaryMarkdown ?? insight.summary)

        if !insight.suggestedTags.isEmpty {
            Divider()
            tagSuggestionsBlock(insight.suggestedTags, vm: vm)
        }

        if let tagError = vm.tagErrorMessage {
            errorBanner(message: "推荐标签解析失败：\(tagError)")
        }

        footer(insight)
    }

    /// 推荐标签块。视觉上比对话气泡克制：
    /// "tag name + reason + 置信度 + 应用按钮"，与旧详情页 AI Tab 的样式对齐。
    private func tagSuggestionsBlock(_ tags: [AITagSuggestion], vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("推荐标签")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("全部应用") {
                    Task { await vm.applyAllTags(repo: repo) }
                }
                .controlSize(.small)
                .disabled(tags.allSatisfy { vm.appliedTagNames.contains($0.name.trimmingNormalized) })
            }

            ForEach(tags) { tag in
                let isApplied = vm.appliedTagNames.contains(tag.name.trimmingNormalized)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name)
                            .font(.body.weight(.medium))
                        Text(tag.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int((max(0, min(tag.confidence, 1)) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(isApplied ? "已应用" : "应用") {
                        Task { await vm.applyTag(tag, repo: repo) }
                    }
                    .controlSize(.small)
                    .disabled(isApplied)
                }
            }
        }
    }

    private func footer(_ insight: RepoAIInsight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
            Text("由 \(insight.model) 生成 · \(formattedDate(insight.generatedAt))")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter.shared.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - 对话段

    @ViewBuilder
    private var chatSection: some View {
        if let chat = chatVM {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            chatEmptyState
                                .padding(.top, 60)
                        } else {
                            ForEach(chat.messages) { message in
                                AIChatBubble(message: message)
                                    .id(message.id)
                            }
                            // 锚点：scrollTo 用，让"新消息追加后自动滚到最底部"。
                            // 单独留一个 0 高度 anchor 比 scrollTo 最后一条 message.id
                            // 更稳：流式中助手 message 不断改 content，scrollTo 同一个
                            // id 在某些版本 SwiftUI 下不重新触发滚动，0 高度 anchor 不会。
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: chat.messages.last?.content ?? "") { _, _ in
                    // 流式 token 进来时也滚一下，否则长回答会被滚动条卡在中间。
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }

                if let err = chat.errorMessage {
                    chatErrorBanner(message: err) {
                        chat.dismissError()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        } else {
            Color.clear
        }
    }

    private static let bottomAnchorID = "chat-bottom-anchor"

    private var chatEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("开始与 AI 聊聊这个仓库")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("AI 已带上仓库元数据与 README 上下文；你可以追问适用场景、对比方案、读源码线索等。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var chatInputBinding: Binding<String> {
        Binding(
            get: { chatVM?.inputText ?? "" },
            set: { chatVM?.inputText = $0 }
        )
    }

    private func sendChatMessage() {
        guard let chatVM else { return }
        let repoSnapshot = repo
        Task { await chatVM.sendMessage(repo: repoSnapshot) }
    }

    // MARK: - 错误条

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chatErrorBanner(message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - String helpers

private extension String {
    /// 与 RepoAIInsightViewModel.normalizedTagName 行为一致——
    /// 那个 extension 是 private，本文件需要同等规则匹配 `appliedTagNames`
    /// 集合时复制一份逻辑，避免破开既有 VM 的访问控制。
    var trimmingNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
