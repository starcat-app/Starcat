//
//  ShareCardSheet.swift
//  Starcat
//
//  HOM-173 用户分享卡片：sheet 容器视图。
//
//  这是用户点击 sidebar 头像左侧分享按钮后看到的整个面板，包含：
//  - 顶部标题栏（标题 + 关闭按钮）
//  - 主题选择 segmented Picker（极简黑白 / 热力橙 / GitHub Green）
//  - 卡片预览区（实时跟随主题切换）
//  - 三个动作按钮：保存为图片 / 分享到 X / 关闭
//  - 底部品牌注脚（"由 Starcat 生成"，可点击跳到 starcat.app）
//
//  设计权衡：
//  - 把"主题选择 + 预览 + 动作"放在 sheet 而不是 popover：
//    分享卡需要 ~520pt 高度做完整预览，popover 在 sidebar 旁会被裁切；
//    sheet 居中浮在主窗口上层，体验更接近"导出图前最后确认"的语义。
//  - 主题切换不持久化：每次打开默认 `.githubGreen`（最贴合 GitHub 用户群体），
//    避免引入额外 AppSettings 字段；用户 365 天里调整一次主题的概率远低于
//    "每次都按当前心情选"。
//  - "分享到 X" 按钮触发后**保留 sheet 不关闭**：因为该路径会唤起浏览器，
//    用户可能想回来再点"保存为图片"备份；显式让用户点关闭。
//

import SwiftUI

/// 分享卡 sheet 主视图。
struct ShareCardSheet: View {

    /// 当前登录用户。从 sidebar 调用方传入（已确保 authenticated）。
    let user: GitHubUserDTO

    /// 本地 starred 数量（与 sidebar 同源）。
    let starredCount: Int

    /// 贡献草坪 payload（可能为 nil；nil 时分享卡显示空网格但仍可分享）。
    let contribution: ContributionCalendarPayload?

    /// 当前用户是否为 Pro 用户。Pro 用户头像显示 Pro 标识。
    let isProUser: Bool

    /// 关闭回调。由调用方持有 `@State var showShareSheet`，这里只负责发信号。
    let onClose: () -> Void

    /// HOM-174：导出 Starred 记录需要访问 RepoRepository。
    /// 通过 `@Environment(AppDependencies.self)` 注入（root 在 StarcatApp 已挂上 dependencies）。
    @Environment(AppDependencies.self) private var dependencies

    /// 当前选中的主题。默认 GitHub Green（最贴合 GitHub 用户群体）。
    @State private var theme: ShareCardTheme = .githubGreen

    /// 最近一次操作的反馈文案（"已保存到 …" / "已复制到剪贴板…"）。
    /// 不弹系统 alert，仅在 sheet 内顶部 toast-like 提示，3 秒后自动隐藏。
    @State private var lastActionFeedback: String?

    /// 当前正在执行的动作（"保存中…" / "导出中…"），用于禁用按钮防止重复点击。
    @State private var isExporting: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 12) {
                    themePicker

                    cardPreview

                    if let feedback = lastActionFeedback {
                        feedbackPill(text: feedback)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    actionButtons
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 480, height: 820)
    }

    // MARK: - 顶部标题栏

    /// 顶部标题栏：标题 + 关闭按钮。
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            Text("sharecard.title")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("sharecard.close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 主题选择

    /// 主题选择 Picker：gacha 风格的卡片式选择器。
    /// HOM-174 follow-up：只显示主题卡片，移除标签文字。
    @ViewBuilder
    private var themePicker: some View {
        HStack(spacing: 10) {
            ForEach(ShareCardTheme.allCases) { t in
                ThemeCardButton(
                    theme: t,
                    isSelected: theme == t
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        theme = t
                    }
                }
            }
        }
    }

    /// 单个主题卡片按钮。
    /// 只包含主题预览色块，无文字。
    private struct ThemeCardButton: View {
        let theme: ShareCardTheme
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                // 主题预览色块
                themePreview
                    .frame(width: 36, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }

        /// 主题预览色块：显示主题的主要配色。
        private var themePreview: some View {
            HStack(spacing: 1) {
                Rectangle()
                    .fill(theme.palette.cardBackground)
                Rectangle()
                    .fill(theme.palette.accent)
            }
        }
    }

    // MARK: - 卡片预览

    /// 卡片预览区。直接渲染 `ShareCardContent`（与导出图同源），缩放后嵌在 sheet 里。
    /// sheet 宽 480 - 24×2 padding = 432pt 可用，卡片本体 400pt，自然居中。
    @ViewBuilder
    private var cardPreview: some View {
        ShareCardContent(
            user: user,
            starredCount: starredCount,
            contribution: contribution,
            theme: theme,
            isProUser: isProUser
        )
        // 主题切换时给一点淡入淡出动画，让预览过渡不生硬
        .animation(.easeInOut(duration: 0.18), value: theme)
        // 卡片下方加柔和阴影区分 sheet material
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    // MARK: - 动作按钮

    /// HOM-174 follow-up：底部按钮与卡片宽度一致。
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            // 第一行：保存 + 导出 Starred
            HStack(spacing: 10) {
                Button {
                    Task { await performSave() }
                } label: {
                    Label("sharecard.action.save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isExporting)
                .keyboardShortcut("s", modifiers: .command)

                exportStarredButton
            }
            .frame(width: 400)

            // 第二行：分享到 X（独占一行）
            shareToXButton
                .frame(width: 400)
        }
    }

    /// 导出 Starred 记录按钮（下拉菜单）。
    /// HOM-174 新增：支持导出 Markdown 和 HTML 格式。
    @ViewBuilder
    private var exportStarredButton: some View {
        Menu {
            Button {
                Task { await performExportStarred(format: .markdown) }
            } label: {
                Label("sharecard.action.export.markdown", systemImage: "doc.text")
            }

            Button {
                Task { await performExportStarred(format: .html) }
            } label: {
                Label("sharecard.action.export.html", systemImage: "doc.richtext")
            }
        } label: {
            Label("sharecard.action.exportStarred", systemImage: "square.and.arrow.up.on.square")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isExporting)
    }

    /// "分享到 X"按钮。
    @ViewBuilder
    private var shareToXButton: some View {
        Button {
            Task { await performShareToX() }
        } label: {
            HStack(spacing: 12) {
                xLogo

                Text("sharecard.action.shareToX")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isExporting)
        .help(Text("sharecard.action.shareToX.help"))
    }

    /// X 品牌 logo 的本地拼写。20pt 黑色加粗 X，包在白底圆角方框里。
    /// 自适应深色模式：底色用 primary 反转（`.primary` 在亮色 = 黑、深色 = 白）。
    @ViewBuilder
    private var xLogo: some View {
        Text("𝕏")
            .font(.system(size: 18, weight: .black, design: .default))
            .foregroundStyle(.primary)
            .frame(width: 26, height: 26)
            .accessibilityLabel(Text("X"))
    }

    /// 反馈提示气泡（"已保存到 …" / "已复制图片到剪贴板…"）。
    /// 浅胶囊，带绿色对勾——3 秒后自动消失。
    @ViewBuilder
    private func feedbackPill(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.tertiary)
        )
        .frame(width: 400)
    }

    // MARK: - 动作执行

    /// 执行保存。
    /// 主线程同步走 NSSavePanel；用户取消时静默返回，不显示反馈。
    @MainActor
    private func performSave() async {
        isExporting = true
        defer { isExporting = false }
        let content = currentContent
        if let url = ShareCardExporter.saveImage(
            content: content,
            userLogin: user.login,
            theme: theme
        ) {
            showFeedback(String(format: String(localized: "sharecard.feedback.saved"), url.lastPathComponent))
        }
    }

    /// 执行分享到 X。
    /// 复制到剪贴板 + 打开 X 推文撰写页（用户在浏览器里 Cmd+V）。
    @MainActor
    private func performShareToX() async {
        isExporting = true
        defer { isExporting = false }
        let content = currentContent
        let ok = ShareCardExporter.shareToX(content: content, userLogin: user.login)
        if ok {
            showFeedback(String(localized: "sharecard.feedback.sharedToX"))
        }
    }

    /// 执行导出 Starred 记录。
    /// HOM-174 新增：支持 Markdown 和 HTML 两种格式。
    ///
    /// 流程：
    /// 1. fetch 全部 isStarred = true 的 repos（按 starred_at desc）
    /// 2. 走 `StarredExporter.export` 渲染 + NSSavePanel + 写文件
    /// 3. 成功 → 显示反馈；失败 / 用户取消 → 沉默（不打扰）
    ///
    /// 失败原因（DB 读异常）映射为 `sharecard.feedback.exportFailed` 提示，
    /// 而不是 alert——分享卡 sheet 体验上沿用 toast-like feedback。
    @MainActor
    private func performExportStarred(format: StarredExportFormat) async {
        isExporting = true
        defer { isExporting = false }

        let repos: [Repo]
        do {
            repos = try await dependencies.repoRepository.fetchAllStarred()
        } catch {
            AppLog.ui.error("performExportStarred: fetchAllStarred failed: \(error.localizedDescription, privacy: .public)")
            showFeedback(String(localized: "sharecard.feedback.exportFailed"))
            return
        }

        guard !repos.isEmpty else {
            showFeedback(String(localized: "sharecard.feedback.exportEmpty"))
            return
        }

        if let url = StarredExporter.export(repos: repos, user: user, format: format) {
            showFeedback(String(format: String(localized: "sharecard.feedback.exported"), url.lastPathComponent))
        }
        // 用户取消保存面板 → 不弹反馈，保持沉默体验，对齐 `performSave` 的同款行为
    }

    /// 当前要渲染的卡片内容（主题切换不重新构造卡片实例，但导出时要用最新值）。
    private var currentContent: ShareCardContent {
        ShareCardContent(
            user: user,
            starredCount: starredCount,
            contribution: contribution,
            theme: theme,
            isProUser: isProUser
        )
    }

    /// 显示反馈提示，3 秒后自动隐藏。
    /// 用 Task.sleep 在主线程异步隐藏；多次调用以最近一次为准（旧 task 自动 cancel
    /// 不会发生，因为我们没存它——但反馈语义本就是"显示最新"，覆盖即可）。
    private func showFeedback(_ text: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            lastActionFeedback = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                lastActionFeedback = nil
            }
        }
    }
}

// MARK: - Preview

// 注：此 preview 不注入 AppDependencies；导出 Starred 按钮在 preview 中点击会触发 @Environment
// 未注入 fatal——这是有意的，preview 用于 UI 排版调试，导出路径要在 app 实际运行时才验证。
#Preview {
    let mockUser = GitHubUserDTO(
        id: 1, login: "dong4j", name: "DONG Jianjun",
        avatarUrl: "https://avatars.githubusercontent.com/u/3380083?v=4",
        publicRepos: 48, followers: 236, following: 100,
        bio: "用代码解决真正的问题。", company: nil,
        location: "Shanghai", email: nil, blog: nil,
        twitterUsername: nil, htmlUrl: "https://github.com/dong4j"
    )
    return ShareCardSheet(
        user: mockUser,
        starredCount: 4823,
        contribution: nil,
        isProUser: false,
        onClose: {}
    )
    .environment(AppDependencies())
}
