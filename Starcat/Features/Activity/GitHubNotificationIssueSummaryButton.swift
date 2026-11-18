//
//  GitHubNotificationIssueSummaryButton.swift
//  Starcat
//
//  Issue 详情工具栏中的总结入口。Popover 的展示状态与应用级生成会话分离，
//  关闭弹层或离开详情都不会取消任务。
//

import SwiftUI

/// 两处 Issue 详情共用；父视图按账号范围、Issue 和语言设定 identity，切帖默认收起。
struct GitHubNotificationIssueSummaryButton: View {
    nonisolated static let toolbarCoordinateSpace = "issueSummaryToolbar"
    private nonisolated static let preferredPopoverWidth: CGFloat = 320

    let title: String
    let payload: ActivityNotificationPayload
    let timeline: [GitHubNotificationIssueTimelineItem]

    @Environment(AppDependencies.self) private var dependencies

    @State private var isPresented = false
    @State private var popoverWidth = Self.preferredPopoverWidth
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
        Button {
            isPresented.toggle()
            if isPresented, !session.hasStarted { startGeneration() }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(session.hasContent ? Color.accentColor : Color.primary)
                .squareLogoActionChrome(side: 22)
                .overlay(alignment: .topTrailing) {
                    if session.isGenerating {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!hasLoadedContent)
        .toolbarIconHover()
        .help(hasLoadedContent ? "activity.issueSummary.action" : "activity.issueSummary.unavailable")
        .accessibilityLabel(Text("activity.issueSummary.action"))
        .accessibilityValue(Text(session.isGenerating ? "activity.issueSummary.loading" : ""))
        .onGeometryChange(for: CGFloat.self) { proxy in
            guard let toolbar = proxy.bounds(of: .named(Self.toolbarCoordinateSpace)) else {
                return Self.preferredPopoverWidth
            }
            // 原生 popover 横向以按钮为锚点居中，按较近的工具栏边缘限宽并给边框预留余量。
            let anchorX = proxy.size.width / 2
            let availableHalfWidth = min(anchorX - toolbar.minX, toolbar.maxX - anchorX) - 8
            return min(Self.preferredPopoverWidth, max(0, 2 * availableHalfWidth))
        } action: { width in
            popoverWidth = width
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            GitHubNotificationIssueSummaryPopover(
                title: title,
                payload: payload,
                timeline: timeline,
                language: language,
                session: session,
                preparationError: preparationError,
                preparationNeedsSettings: preparationNeedsSettings,
                onRegenerate: startGeneration
            )
            .frame(width: popoverWidth, height: 400)
            .appLocaleEnvironment()
            .onExitCommand(perform: dismiss)
        }
        // 按钮挂载时回放磁盘快照，赶在用户点开弹层之前；restore 内部带「会话仍为空」
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
    }

    private var hasLoadedContent: Bool {
        payload.excerpt != nil || payload.authorLogin != nil || payload.authorCreatedAt != nil
            || !payload.comments.isEmpty || !timeline.isEmpty
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

    /// 只关闭弹层，生成会话仍由 Store 持有。
    private func dismiss() {
        isPresented = false
    }
}
