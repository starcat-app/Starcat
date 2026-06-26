//
//  SmartSearchField.swift
//  Starcat
//
//  可折叠的智能搜索框组件。
//
//  模块职责：
//  - 在一个 toolbar 组件内承载关键词搜索 / AI 语义搜索两种模式；
//  - 折叠态只占一个图标宽度，避免挤压 macOS toolbar；
//  - 展开态内嵌模式切换、输入框、清空按钮和 AI 向量索引刷新入口；
//  - AI 模式提供克制的彩色光晕，但仍保持桌面应用的原生工具栏比例。
//
//  关键约束：
//  - 搜索业务状态由调用方传入的 Binding 管理，组件不直接依赖 HomeViewModel；
//  - 所有 plain button 必须禁用 focus ring，遵守 Starcat 的 toolbar 视觉约束；
//  - Reduce Motion 开启时不做动态光晕，只保留静态渐变边框。
//

import SwiftUI

/// Starcat 主 toolbar 使用的智能搜索输入框。
///
/// 折叠、聚焦和输入草稿属于局部 UI 状态，因此留在组件内部；提交后的搜索词、搜索模式和
/// 索引状态来自调用方，保证业务逻辑仍集中在 `HomeViewModel` / `AppSettings`。
struct SmartSearchField: View {
    /// 已提交的搜索词。
    ///
    /// 组件内部 `draftText` 随键盘输入实时变化，但不会直接写入这里；只有用户按 Return
    /// 或点击清空时才提交，避免每个字符都触发 FTS5 / AI 语义搜索。
    @Binding var text: String
    @Binding var mode: SmartSearchMode

    let isIndexing: Bool
    let onSubmitSearch: (String) -> Void
    let onRefreshSemanticIndex: () -> Void
    var onOpenGlobalSearch: (() -> Void)?

    /// W12 toolbar 专项 PR-2：禁用态。
    ///
    /// 设计动机：搜索框已扩到所有页面常驻显示，但 `.keyword` / `.semantic` 模式只对
    /// Manage 页面有意义（Trending / Activity / Weekly 没有本地 FTS5 / 向量索引）。
    /// 非 Manage 页面调用方传 `isDisabled = true`：
    /// - 折叠态图标变灰；
    /// - 展开后的 TextField + 提交按钮 / 刷新索引按钮全部 disabled；
    /// - 整个组件挂 `.help(disabledHelpKey)` 解释为何不能用（未来 GitHub 搜索模式
    ///   上线后调用方按 mode 灵活决定 isDisabled）。
    /// 默认 `false`，沿用原行为。
    var isDisabled: Bool = false

    /// 禁用态的 tooltip 文案 key。仅 `isDisabled == true` 时生效。
    var disabledHelpKey: LocalizedStringKey = "search.disabledInPage"

    /// 外部折叠信号。
    ///
    /// 搜索词已提交后，组件默认会保持展开，避免用户忘记当前列表仍被搜索过滤。
    /// 但点击 repo 行时，中栏 toolbar 空间应回到紧凑态，同时不能清掉搜索条件；
    /// 调用方每次切换 repo 时传入变化的 token，本组件只收起 UI，不改 `text`。
    var collapseToken: Int64?
    var expandToken: Int = 0
    var historyEntries: [SearchHistory] = []
    var onRefreshHistory: (() -> Void)?
    var onRemoveHistory: ((SearchHistory) -> Void)?

    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var draftText = ""
    @State private var isExpanded = false
    @State private var isCollapsedByExternalRequest = false
    @State private var isHistoryPanelPresented = false
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var isCollapsedIconFocused: Bool

    private let collapsedWidth: CGFloat = 42
    private let expandedWidth: CGFloat = 300
    private let height: CGFloat = 38

    private var isSemantic: Bool { mode == .semantic }

    private var hasDraftText: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasCommittedText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveControlWidth: CGFloat? {
        if shouldExpand { return expandedWidth }
        return onOpenGlobalSearch == nil ? collapsedWidth : nil
    }

    private var effectiveControlHeight: CGFloat? {
        if shouldExpand { return height }
        return onOpenGlobalSearch == nil ? height : nil
    }

    /// 空输入但仍聚焦时保持展开；有输入时默认保持展开，避免用户看不见当前筛选条件。
    /// 外部折叠请求是唯一例外：切 repo 只收起 toolbar UI，不清除已提交的搜索条件。
    private var shouldExpand: Bool {
        isExpanded || isTextFieldFocused || (!isCollapsedByExternalRequest && (hasDraftText || hasCommittedText))
    }

    var body: some View {
        Group {
            if shouldExpand {
                expandedField
            } else {
                collapsedButton
            }
        }
        .frame(width: effectiveControlWidth, height: effectiveControlHeight)
        .opacity(isDisabled ? 0.55 : 1.0)
        .help(isDisabled ? disabledHelpKey : (mode == .semantic ? "search.semantic.placeholder" : "search.repoPlaceholder"))
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86), value: shouldExpand)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: mode)
        .onChange(of: isTextFieldFocused) { _, focused in
            // PR-2：禁用态不参与展开/折叠状态切换，避免点击造成意外展开。
            guard !isDisabled else { return }
            if focused {
                isExpanded = true
                openHistoryPanel()
            } else {
                collapseIfPossible()
            }
        }
        .onChange(of: isCollapsedIconFocused) { _, focused in
            guard !isDisabled else { return }
            if focused {
                expandAndFocusInput()
            }
        }
        .onChange(of: mode) { _, _ in
            guard !isDisabled else { return }
            expandAndFocusInput()
        }
        .onChange(of: collapseToken) { _, _ in
            collapseFromExternalRequest()
        }
        .onChange(of: expandToken) { _, _ in
            guard !isDisabled else { return }
            expandAndFocusInput()
        }
        .onAppear {
            draftText = text
            isExpanded = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: text) { _, newValue in
            guard draftText != newValue else { return }
            draftText = newValue
            isCollapsedByExternalRequest = false
            isExpanded = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTextFieldFocused
        }
    }

    /// 折叠态只露出当前模式图标。
    ///
    /// 点击时不直接弹模式菜单，而是先展开搜索框；展开后左侧的图标 + chevron 再负责模式切换。
    /// 这样可以避免一次点击同时触发“展开”和“打开菜单”的歧义。
    private var collapsedButton: some View {
        Group {
            if onOpenGlobalSearch != nil {
                Menu {
                    Button {
                        mode = .keyword
                        expandAndFocusInput()
                    } label: {
                        Label("search.mode.keyword", systemImage: SmartSearchMode.keyword.systemImage)
                    }

                    Button {
                        mode = .semantic
                        expandAndFocusInput()
                    } label: {
                        Label("search.mode.semantic", systemImage: SmartSearchMode.semantic.systemImage)
                    }
                } label: {
                    ToolbarIcon("sparkle.magnifyingglass")
                        .accessibilityLabel(Text("toolbar.globalSearch"))
                } primaryAction: {
                    onOpenGlobalSearch?()
                }
                .help("toolbar.globalSearchHelp")
            } else {
                Button {
                    // PR-2 禁用态：点击 no-op；外层 `.help(disabledHelpKey)` 已说明原因。
                    guard !isDisabled else { return }
                    expandAndFocusInput()
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isSemantic ? .purple : .secondary)
                        .frame(width: collapsedWidth, height: height)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($isCollapsedIconFocused)
                .disabled(isDisabled)
                .background(searchBackground)
                .overlay(searchBorder)
                .overlay(aiGlow)
            }
        }
    }

    /// 展开态：模式菜单、输入框和右侧操作都收进同一个胶囊里。
    private var expandedField: some View {
        HStack(spacing: 8) {
            modeMenu

            TextField(promptKey, text: $draftText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .focused($isTextFieldFocused)
                .submitLabel(.search)
                .onSubmit {
                    commitSearch()
                }
                .disabled(isDisabled)

            if isSemantic {
                Divider()
                    .frame(height: 18)
                    .opacity(0.38)
                semanticRefreshButton
            }

            if !draftText.isEmpty || hasCommittedText {
                clearButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, draftText.isEmpty ? 10 : 7)
        .frame(height: height)
        .background(searchBackground)
        .overlay(searchBorder)
        .overlay(aiGlow)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            guard !isDisabled else { return }
            expandAndFocusInput()
        }
        .popover(isPresented: $isHistoryPanelPresented, arrowEdge: .bottom) {
            SmartSearchHistoryPanel(
                entries: historyEntries,
                onUse: { entry in
                    draftText = entry.query
                    isHistoryPanelPresented = false
                    commitSearch()
                },
                onRemove: { entry in
                    onRemoveHistory?(entry)
                }
            )
            .appLocaleEnvironment()
        }
    }

    private var modeMenu: some View {
        Menu {
            if onOpenGlobalSearch != nil {
                Button {
                    isHistoryPanelPresented = false
                    onOpenGlobalSearch?()
                } label: {
                    Label("toolbar.globalSearch", systemImage: "sparkle.magnifyingglass")
                }

                Divider()
            }

            Picker("search.mode.title", selection: $mode) {
                ForEach(SmartSearchMode.allCases) { option in
                    Label {
                        Text(option.displayName)
                    } icon: {
                        Image(systemName: option.systemImage)
                    }
                    .tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.72)
            }
            .foregroundStyle(isSemantic ? .purple : .secondary)
            .frame(width: 44, height: 26)
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .help("search.mode.hint")
    }

    private var semanticRefreshButton: some View {
        Button {
            onRefreshSemanticIndex()
        } label: {
            Group {
                if isIndexing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isIndexing || isDisabled)
        .foregroundStyle(isIndexing ? Color.secondary : Color.green)
        .help(isIndexing ? Text("search.semantic.indexing") : Text("search.semantic.refreshIndex"))
    }

    private var clearButton: some View {
        Button {
            draftText = ""
            onSubmitSearch("")
            expandAndFocusInput()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("search.clear")
    }

    private var promptKey: LocalizedStringKey {
        isSemantic ? "search.semantic.placeholder" : "search.repoPlaceholder"
    }

    private var searchBackground: some View {
        Capsule(style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                if isSemantic {
                    Capsule(style: .continuous)
                        .fill(Color.purple.opacity(0.055))
                }
            }
    }

    private var searchBorder: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                isSemantic ? Color.purple.opacity(0.36) : Color.secondary.opacity(0.22),
                lineWidth: 1
            )
    }

    @ViewBuilder
    private var aiGlow: some View {
        if isSemantic {
            SmartSearchAIGlow(isActive: isTextFieldFocused || hasDraftText || hasCommittedText || isIndexing)
                .allowsHitTesting(false)
        }
    }

    private func commitSearch() {
        let submitted = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        draftText = submitted
        onSubmitSearch(submitted)
        isCollapsedByExternalRequest = false
        isExpanded = true
        isHistoryPanelPresented = false
    }

    private func expandAndFocusInput() {
        isCollapsedByExternalRequest = false
        isExpanded = true
        openHistoryPanel()
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
    }

    private func collapseFromExternalRequest() {
        isTextFieldFocused = false
        isCollapsedIconFocused = false
        isExpanded = false
        isCollapsedByExternalRequest = true
        isHistoryPanelPresented = false
    }

    private func openHistoryPanel() {
        onRefreshHistory?()
        isHistoryPanelPresented = true
    }

    private func collapseIfPossible() {
        guard !hasDraftText, !hasCommittedText else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if !isTextFieldFocused && !hasDraftText && !hasCommittedText {
                isExpanded = false
            }
        }
    }
}

/// Toolbar 搜索框的轻量历史面板。
///
/// 全局 Search Center 已有完整历史页；toolbar 只承载"快速复用最近关键词"，
/// 因此用紧凑列表而不是复制 Search Center 的大面积 FlowLayout，避免 toolbar popover 过重。
private struct SmartSearchHistoryPanel: View {
    let entries: [SearchHistory]
    let onUse: (SearchHistory) -> Void
    let onRemove: (SearchHistory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("search.history.recent")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            if entries.isEmpty {
                ContentUnavailableView(
                    "search.history.empty.title",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("search.history.empty.description")
                )
                .frame(width: 260, height: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(entries.prefix(8), id: \.id) { entry in
                        historyRow(entry)
                    }
                }
                .frame(width: 280, alignment: .leading)
            }
        }
        .padding(10)
    }

    private func historyRow(_ entry: SearchHistory) -> some View {
        HStack(spacing: 6) {
            Button {
                onUse(entry)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(entry.query)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.useCount >= 3 {
                        Text(entry.useCount.formatted())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(String(format: String.l10n("search.history.tooltip.useCountFormat"), entry.query, entry.useCount))

            Button {
                onRemove(entry)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("search.history.removeOne.help")
        }
    }
}

/// AI 语义搜索模式下的彩色光晕。
///
/// 光晕只作为状态提示，不承担布局边界；因此用 overlay 绘制在胶囊边缘，避免影响 toolbar
/// 高度。动态 hue rotation 只在未开启 Reduce Motion 时运行。
private struct SmartSearchAIGlow: View {
    let isActive: Bool

    @Environment(\.starcatReduceMotion) private var reduceMotion

    private let gradient = AngularGradient(
        colors: [
            .cyan.opacity(0.72),
            .purple.opacity(0.78),
            .pink.opacity(0.72),
            .orange.opacity(0.58),
            .cyan.opacity(0.72)
        ],
        center: .center
    )

    var body: some View {
        Group {
            if reduceMotion || !isActive {
                glow(hue: 0)
            } else {
                // 光晕只在语义搜索正在交互/索引时流动；静置搜索框不应
                // 长期占用 display-link。色相 6 秒才转 42°，15 FPS 已足够平滑。
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                    let hue = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 6) / 6 * 42
                    glow(hue: hue)
                }
            }
        }
    }

    private func glow(hue: Double) -> some View {
        Capsule(style: .continuous)
            .strokeBorder(gradient, lineWidth: isActive ? 1.45 : 1.05)
            .hueRotation(.degrees(hue))
            .shadow(color: .cyan.opacity(isActive ? 0.24 : 0.13), radius: isActive ? 7 : 4)
            .shadow(color: .pink.opacity(isActive ? 0.18 : 0.10), radius: isActive ? 9 : 5)
            .padding(1)
    }
}
