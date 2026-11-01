//
//  GitHubNotificationIssueSummaryButton.swift
//  Starcat
//
//  详情页右下角客服式总结入口与悬浮面板布局。面板只覆盖详情内容，不改变正文
//  或评论框的尺寸；展示开关与应用级生成会话分离，收起、离开详情都不会取消任务。
//

import SwiftUI

/// 覆盖在详情 body 上的总结控件；父视图以账号、Issue 和语言设 identity，切帖默认收起。
struct GitHubNotificationIssueSummaryButton: View {
    let title: String
    let payload: ActivityNotificationPayload
    let timeline: [GitHubNotificationIssueTimelineItem]
    /// 可见评论卡片的真实边界，不包含光晕 gutter 与外边距。
    let composerAnchor: Anchor<CGRect>
    /// 会话正文与输入区之间的真实分割线，按钮必须完整停在该线之上。
    let dividerAnchor: Anchor<CGRect>

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var isPresented = false
    @State private var isHovered = false
    @State private var preparationError: String?
    @State private var preparationNeedsSettings = false
    @State private var paywallContext: ProPaywallContext?

    private var language: String { RepoAIInsightService.outputLanguageDescriptor() }

    private var session: GitHubNotificationIssueSummarySession {
        dependencies.githubIssueSummaryStore.session(
            threadId: payload.threadId,
            scopeRevision: dependencies.databaseScopeRevision,
            language: language
        )
    }

    var body: some View {
        let session = session
        GeometryReader { proxy in
            let composerFrame = proxy[composerAnchor]
            let dividerFrame = proxy[dividerAnchor]
            let trailingInset = max(16, proxy.size.width - composerFrame.maxX)
            // 按钮右边缘与面板右边缘对齐，底边紧贴真实分割线上缘，不再用输入框推测线的位置。
            let launcherBottomInset = max(0, proxy.size.height - dividerFrame.minY)
            // 面板底边固定在入口上方：32pt 按钮高 + 8pt 面板与按钮的间距。
            let panelBottomInset = max(0, proxy.size.height - dividerFrame.minY + 40)
            ZStack(alignment: .bottomTrailing) {
                // ESC 关闭面板：keyboardShortcut 走 window 命令层，不要求面板持有焦点
                // （正文 WebView 通常是 first responder，onExitCommand 收不到）。
                // 面板未打开时禁用，ESC 落回详情页 handleEscape 的 composer 收起语义。
                Button(action: dismiss) { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!isPresented)
                    .accessibilityHidden(true)
                GitHubNotificationIssueSummaryResizablePanel(
                    isPresented: isPresented,
                    width: min(420, max(0, proxy.size.width - 32)),
                    maximumHeight: max(0, proxy.size.height - panelBottomInset - 16),
                    transition: panelTransition,
                    content: GitHubNotificationIssueSummaryPanel(
                        title: title,
                        payload: payload,
                        timeline: timeline,
                        language: language,
                        session: session,
                        preparationError: preparationError,
                        preparationNeedsSettings: preparationNeedsSettings,
                        onRegenerate: startGeneration,
                        onDismiss: dismiss
                    )
                    .onExitCommand(perform: dismiss)
                )
                .padding(.trailing, trailingInset)
                .padding(.bottom, panelBottomInset)
                launcher(session: session)
                    .padding(.trailing, trailingInset)
                    .padding(.bottom, launcherBottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // 不能加全屏背景或 contentShape：面板外的正文、评论仍需正常点击和滚动。
        }
        // 挂载即异步回放磁盘快照，赶在用户点开面板之前；restore 内部带「会话仍为空」
        // 守卫，与点击触发的生成竞态时晚到的恢复自动让位，不会覆盖进行中的任务。
        .task(id: "\(payload.threadId)|\(language)") {
            let session = session
            guard !session.hasStarted, !session.isGenerating, !session.hasContent else { return }
            guard let snapshot = DiskIssueSummaryCache.shared.load(payload: payload, language: language) else { return }
            session.restore(from: snapshot)
        }
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
                .appLocaleEnvironment()
        }
        // 不注册外部点击或失焦关闭，也不在 onDisappear 取消 session；切帖只销毁这层展示。
    }

    /// 缩放只作用于面板表面，不能把 Markdown 的每次增量更新也包进布局动画。
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
    }

    private var hasLoadedContent: Bool {
        payload.excerpt != nil || payload.authorLogin != nil || payload.authorCreatedAt != nil
            || !payload.comments.isEmpty || !timeline.isEmpty
    }

    private func launcher(session: GitHubNotificationIssueSummarySession) -> some View {
        Button {
            if isPresented {
                dismiss()
            } else {
                withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.2)) {
                    isPresented = true
                }
                if !session.hasStarted { startGeneration() }
            }
        } label: {
            // 中断后的半截正文也算「已有总结」：面板确实展示了可读内容。
            let hasSummary = session.hasContent
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hasSummary || isHovered || isPresented ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 32)
                // macOS 26 的 glassEffect 会忽略 legacyMaterial 参数，纯玻璃叠在正文上几乎隐形。
                // 底色同时承担状态标识：中性玻璃 = 尚无总结；accent 淡底 = 已有总结
                // （生成完成或磁盘恢复回放），两种底色都随明暗主题自适应。
                .background(
                    hasSummary
                        ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                        : AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.9)),
                    in: Circle()
                )
                .starcatInteractiveGlassSurface(.thinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if session.isGenerating {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .clickablePointer()
        .disabled(!hasLoadedContent)
        .help(hasLoadedContent ? "activity.issueSummary.action" : "activity.issueSummary.unavailable")
        .accessibilityLabel(Text("activity.issueSummary.action"))
        .accessibilityValue(Text(session.isGenerating ? "activity.issueSummary.loading" : ""))
        .onHover { isHovered = $0 }
    }

    /// 权益和配置预检在请求前完成，已有结果重开时不再创建客户端或重复扣费。
    private func startGeneration() {
        let session = session
        guard hasLoadedContent, !session.isGenerating else { return }
        do {
            try dependencies.repoAIInsightService.ensureGitHubIssueSummaryReady()
        } catch let error as EntitlementGateError {
            dismiss()
            paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
            return
        } catch {
            let friendly = UserFacingError.map(error, operation: String.l10n("activity.issueSummary.action"), service: "AI")
            friendly.record(category: "ai", operation: "notification.issue.summary", service: "ai-provider")
            preparationError = friendly.message
            preparationNeedsSettings = notificationAIErrorNeedsSettings(error)
            return
        }
        preparationError = nil
        preparationNeedsSettings = false
        let service = dependencies.repoAIInsightService
        let requestedLanguage = language
        session.start(title: title, payload: payload, timeline: timeline, language: requestedLanguage) { context, onDelta in
            try await service.generateGitHubIssueSummary(context: context, outputLanguage: requestedLanguage, onDelta: onDelta)
        }
    }

    /// 收起、关闭都只隐藏面板。真正取消只由正文状态栏的“停止生成”触发。
    private func dismiss() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeOut(duration: 0.16)) {
            isPresented = false
        }
    }
}
