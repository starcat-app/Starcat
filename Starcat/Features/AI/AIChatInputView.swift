//
//  AIChatInputView.swift
//  Starcat
//
//  AI 助手窗口底部固定的输入条（HOM-150 / Y9 增强 / 2026-06-15 多行毛玻璃重写）。
//
//  设计要点：
//  - AppKit NSTextView + 圆角毛玻璃容器：默认 2 行高、自动撑到 4 行、超出内部滚动；
//  - Return 直接发送 / Shift+Return 换行（主流 ChatGPT / Claude 行为）；
//  - 发送过程禁用编辑器，避免并发触发 stream；
//  - 输入为空或正在发送时按钮 disabled，按钮的颜色 / 透明度由 SwiftUI 系统行为提供
//    视觉反馈，不需要手写额外样式。
//
//  2026-06-15 重写（dong4j 反馈参考 chat 输入框样式）：
//  - 由「单行 HStack」改为「文本区在上 + 控件行在下」的圆角毛玻璃容器；
//  - 2026-06-15 二次性能修复：SwiftUI 多行 TextField 的高度测量会向上传播，chat
//    面板挂载 Markdown 历史时，每个按键都可能带动整列重新布局。改为 NSTextView，
//    文本留在 AppKit 内，仅跨行、空状态变化、发送和历史回填时通知 SwiftUI；
//  - Return / Shift+Return 由 NSTextViewDelegate command 路径分流：普通 Return 发送，
//    Shift+Return 插入换行，保持既有键盘交互不变；
//  - 上下文菜单（Y9 决议）保留在**左下角**，与右下角发送按钮**等大 28×28**，
//    遵循「左下=辅助操作 / 右下=主操作」的 Mac 原生 idiom（参考 Mail compose
//    / Messages）；
//  - 整体用 `.regularMaterial` 毛玻璃 + 1pt 描边 + 16pt 圆角，与 AI 窗口的
//    `NSVisualEffectView(.popover)` 玻璃态背景层次区分，但不抢戏。
//
//  Y9（2026-06-14，决议 C=c3+disabled）：上下文快捷菜单暴露「代码上下文」/
//  「外部材料 (AnySearch)」两个 Toggle 直接绑 settings 的 `aiRepoContextEnabled`
//  / `aiExternalContextEnabled`。Settings 是 `@MainActor @Observable`，菜单与
//  Settings 页面双向同步零 race。AnySearch Toggle 在 `anySearchEnabled = false`
//  时 disabled + 副标题引导去 Settings 启用——避免在快捷菜单诱导用户配置 API Key
//  这种带成本的能力（详见 grill-me 决议 C 节点）。
//
//  卡顿修复（2026-06-15 12:47 已落地，本次重写延续）：
//  - 输入草稿由非 Observable 的 `AIChatTextEditorState + NSTextView` 持有，**不放进
//    SwiftUI @State 或窗口根级 RepoAIChatViewModel**——否则每个按键都会让摘要和
//    聊天 Markdown 子树重新参与依赖检查与布局。
//  - 历史问题「修改」通过 `pendingReplacement: Binding<String?>` 单向通道回填：
//    上层只需 `pendingChatDraftReplacement = oldContent`，子组件 `.onChange`
//    捕获后写进原生编辑器并把 binding 置 nil（一次性，避免重复覆盖）。
//

import AppKit
import SwiftUI

struct AIChatInputView: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 原生编辑器持有实际草稿，SwiftUI 只保留“是否为空”这个低频状态。
    /// 普通字符输入不会再让窗口根视图执行属性图更新；只有空/非空切换才刷新发送按钮。
    @State private var editorState = AIChatTextEditorState()
    @State private var hasText = false
    /// `NSScrollView` 的 intrinsic height 在 SwiftUI 弹性 VStack 中不是强约束，必须
    /// 显式锁定 frame。默认值按系统正文 2 行计算，避免首帧先撑满再回缩。
    @State private var editorHeight = AIChatEditorMetrics.defaultHeight

    /// 外部"草稿回填"通道（如点击"编辑历史问题"把旧内容塞回输入框）。
    /// 子组件捕获后写回内部 `text` 并把 binding 置 nil，单次生效不会重复覆盖。
    @Binding var pendingReplacement: String?

    let focus: FocusState<Bool>.Binding
    let isSending: Bool
    let onSend: (String) -> Void

    /// 2026-06-15 13:12 dong4j 反馈"AI 输出时发送按钮要变成终止按钮"：流式期间
    /// 整颗按钮的语义切换为"停止生成"，点击调用 `onCancel`,vm 内 cancelStreaming()
    /// 中断 sendTask,把已经累积的 partial 当作正常完成的消息保存（ChatGPT / Claude 风格）。
    let onCancel: () -> Void

    /// Y9：上下文快捷菜单需要直接读写 settings 的开关字段。
    /// 用 `@Environment(AppSettings.self)` + body 内 `@Bindable` 提取 binding，是
    /// `@Observable` 模式下 SwiftUI 标准做法（Swift 5.9+）。
    @Environment(AppSettings.self) private var settings

    var body: some View {
        // 把 @Observable settings 转成可 binding 的形式，让 Menu 内 Toggle 能直接
        // `$settings.aiRepoContextEnabled` 写回 settings.didSet 持久化。
        @Bindable var settings = settings

        VStack(spacing: 0) {
            textEditor
            controlsRow(settings: $settings)
        }
        // 2026-06-15 13:05 dong4j 反馈：`.regularMaterial` 在 popover 玻璃态外层
        // 几乎透明，看着没有"独立卡片"感。换成 `.controlBackgroundColor` —— 浅色
        // 主题渲染为纯白、暗色主题渲染为深灰，跟随系统主题；Y9.2 注释明确这是
        // "在玻璃态背景上会渲染成不透明纯白 / 纯黑"的系统色，正好与外层 popover
        // 玻璃材质对比鲜明，输入框作为"独立卡片"视觉清晰。
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            // 描边跟随系统主题切深浅，避免在浅色背景上贴边看不见容器边界。
            // 0.12 是从项目其它卡片描边浓度复用的经验值（`Color.primary.opacity(0.12)`
            // 与外层窗口 0.14 圆角描边形成层次）。
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        // 2026-06-23 dong4j 反馈：输入框顶边到上方 Divider、底边到窗口底边应对称。
        // 统一 8pt；对话模式下 chatContextStatusRow 另有自己的上下 padding。
        .padding(.vertical, 8)
        .onChange(of: pendingReplacement) { _, replacement in
            guard let replacement else { return }
            editorState.replaceText(replacement)
            hasText = !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            pendingReplacement = nil
        }
    }

    // MARK: - 文本编辑区

    /// AppKit 多行文本编辑器，默认 2 行、软上限 4 行。
    ///
    /// 关键技术点：
    /// - 文本和 selection 全部留在 `NSTextView`，每个按键不写 SwiftUI `@State`；
    /// - 文本实际跨行时才 invalid intrinsic size，让外层重新布局；
    /// - Return / Shift+Return 在 delegate command 路径分流，不依赖 SwiftUI key handler。
    private var textEditor: some View {
        AIChatNativeTextEditor(
            state: editorState,
            placeholder: String.l10n("ai.assistant.input.placeholder"),
            isEnabled: !isSending,
            isFocused: focus,
            requiresCommandReturn: settings.aiChatRequiresCommandReturn,
            onEmptyStateChange: { isEmpty in
                hasText = !isEmpty
            },
            onHeightChange: { height in
                guard abs(editorHeight - height) >= 0.5 else { return }
                editorHeight = height
            },
            onSubmit: trySend
        )
        // NSViewRepresentable 放在可扩展 VStack 中时，AppKit intrinsicContentSize 只
        // 参与优先级协商，不能阻止父容器把 NSScrollView 拉满。显式高度才是边界。
        .frame(height: editorHeight)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 控件行

    /// 左下：上下文菜单（辅助操作） / 右下：发送按钮（主操作）。
    ///
    /// 两个按钮容器统一 28×28，遵循「左下=辅助操作 / 右下=主操作」的 Mac 原生 idiom
    /// （参考 Mail compose 工具行）。
    @ViewBuilder
    private func controlsRow(settings: Bindable<AppSettings>) -> some View {
        HStack(spacing: 0) {
            contextMenu(settings: settings)
            Spacer()
            sendButton
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// Y9（2026-06-14）：上下文配置快捷菜单（决议 C=c3+disabled）。
    ///
    /// 两个 Toggle：
    ///   1. **代码上下文** → `aiRepoContextEnabled`（默认 ON）
    ///      影响 RepoContextPacker 是否被调用 + Code XML 是否进 AI prompt。
    ///   2. **外部材料 (AnySearch)** → `aiExternalContextEnabled`（默认 OFF）
    ///      影响 AnySearch markdown 是否注入摘要 / 对话 prompt。
    ///      当 `anySearchEnabled = false` 时整项 disabled，菜单内追加 caption 引导
    ///      用户去 Settings 启用 AnySearch（带 API Key 配置成本，不在此快捷翻转）。
    ///
    /// 私仓开关 `aiExternalContextAllowPrivateRepos` 不进本菜单——它是边界条件，
    /// 不是日常切换的诉求。
    ///
    /// Settings 字段同时被 Settings 页面用同一份绑定方式编辑，本菜单与 Settings 页面
    /// 双向同步无需额外通信（@Observable didSet 自然驱动 UI 刷新）。
    @ViewBuilder
    private func contextMenu(settings: Bindable<AppSettings>) -> some View {
        Menu {
            Toggle(isOn: settings.aiRepoContextEnabled) {
                Label(
                    "ai.assistant.input.contextMenu.codeContext",
                    systemImage: "doc.text.magnifyingglass"
                )
            }

            Toggle(isOn: settings.aiExternalContextEnabled) {
                Label(
                    "ai.assistant.input.contextMenu.anySearch",
                    systemImage: "globe"
                )
            }
            .disabled(!settings.wrappedValue.anySearchEnabled)

            // AnySearch 总开关关闭时追加 caption 引导用户：菜单里的 Text 在 macOS
            // SwiftUI 上以 secondary 字色 + 较小字号呈现，刚好作为"为什么禁用"的提示。
            if !settings.wrappedValue.anySearchEnabled {
                Divider()
                Text("ai.assistant.input.contextMenu.anySearch.disabledHint")
            }
        } label: {
            // 2026-06-15 13:05 dong4j 反馈"图标比发送按钮小"——根因不是字号不够大，
            // 而是 SF Symbol `ellipsis.circle` 的圆形只占字号的 ~85%（描边圆，不是
            // 实心填充），与右边 28pt 实心渐变圆视觉差了 ~11pt。字号加大会撑出容器，
            // 加粗又让 ellipsis 三点过粗。
            // **正确做法**：与右边 sendButton 做**完全镜像** —— `Circle().fill` 实心
            // 28×28 + 内嵌 12pt `ellipsis` 三点。颜色一灰一彩（次级 vs 主级）区分操作
            // 层级，形状视觉对称。浅灰底色用 `Color.secondary.opacity(0.12)` 在明暗
            // 主题下都能与白底 / 深灰底区分出来。
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)

                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .focusEffectDisabled()
        .help("ai.assistant.input.contextMenu.help")
    }

    /// 右下角渐变发送按钮 / 流式期间的终止按钮。
    ///
    /// 28×28 圆形紫蓝渐变，两种状态切换：
    /// - 空闲：内嵌 12pt bold ↑，点击 `trySend()` 触发发送；输入为空 disabled。
    /// - 流式中：内嵌 10pt 实心方块（stop.fill 风格，ChatGPT / Claude 同款），点击
    ///   `onCancel()` 中断 AI 输出，**按钮不再 disabled**（"停止"是流式期间的主操作）。
    ///
    /// 2026-06-15 13:12 dong4j 反馈"AI 输出时发送按钮要变成终止按钮"。原方案在
    /// `isSending` 时显示 ProgressView + 整体 disabled,用户没有取消通道。改造后保留
    /// 渐变圆做"主操作锚点",图标 / 行为按状态切换,无需新增第二个按钮位。
    ///
    /// 实现细节：
    /// - 用 `stop.fill` SF Symbol（10pt）作为停止图标,与 ↑ 在视觉重量上对齐；
    ///   不用 ProgressView 是因为它不可点击,与"按钮可被点"的视觉语义矛盾。
    /// - `.contentTransition(.symbolEffect(.replace))` 让两个 symbol 切换有柔性
    ///   过渡（macOS 14+ 标准 SF Symbol 动效）。
    /// - disabled 规则：空闲态 + 输入为空 → disabled；流式态 → 永不 disabled。
    private var sendButton: some View {
        Button(action: trySendOrCancel) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.85), .blue.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: isSending ? "stop.fill" : "arrow.up")
                    .font(.system(size: isSending ? 10 : 12, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 空闲态：输入为空 → 禁用；流式态：永远可点（"停止"是主操作，必须可点）。
        .disabled(!isSending && !hasText)
        .help(isSending ? "ai.assistant.input.stop.help" : "ai.assistant.input.send.help")
    }

    // MARK: - Actions

    /// 按钮点击入口：根据当前是否流式中,分流到发送 / 取消。
    ///
    /// 2026-06-15 13:12 新增的双语义入口（与 onKeyPress Return 共用 trySend()）。
    /// Return 键在流式期间保持发送语义（实际被 `trySend()` 内的 guard 拦截不会发送），
    /// 不绑取消语义 —— 取消是显式破坏性操作,要求用户主动点击,不让键盘误触。
    private func trySendOrCancel() {
        if isSending {
            onCancel()
        } else {
            trySend()
        }
    }

    private func trySend() {
        guard !isSending else { return }
        guard let trimmed = editorState.consumeTrimmedText() else { return }
        hasText = false
        onSend(trimmed)
    }
}

/// SwiftUI 与原生编辑器之间的窄桥梁。
///
/// 它故意不使用 `@Observable`：每个按键只更新这个普通引用对象，不应传播到 SwiftUI
/// 属性图。SwiftUI 侧只有发送动作和历史问题回填需要读写它。
@MainActor
private final class AIChatTextEditorState {
    fileprivate weak var textView: NSTextView?
    fileprivate var pendingText: String?

    func replaceText(_ text: String) {
        pendingText = text
        applyPendingTextIfPossible()
    }

    func consumeTrimmedText() -> String? {
        let source = textView?.string ?? pendingText ?? ""
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        replaceText("")
        return trimmed
    }

    fileprivate func connect(_ textView: NSTextView) {
        self.textView = textView
        applyPendingTextIfPossible()
    }

    private func applyPendingTextIfPossible() {
        guard let textView, let pendingText else { return }
        textView.string = pendingText
        textView.setSelectedRange(NSRange(location: pendingText.utf16.count, length: 0))
        self.pendingText = nil
        // 直接赋值不会自动走 delegate；显式发送 change notification，让空状态、
        // placeholder 和高度缓存与用户键入路径保持一致。
        textView.didChangeText()
    }
}

/// `NSTextView` 输入桥接。
///
/// 关键约束：delegate 的 `textDidChange` 不把完整文本写回 SwiftUI，只上报空状态边界；
/// 因而对话区即使挂载多条 Markdown，普通输入也不会触发整棵 SwiftUI 子树失效。
private struct AIChatNativeTextEditor: NSViewRepresentable {
    let state: AIChatTextEditorState
    let placeholder: String
    let isEnabled: Bool
    let isFocused: FocusState<Bool>.Binding
    let requiresCommandReturn: Bool
    let onEmptyStateChange: (Bool) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AIChatIntrinsicScrollView {
        let scrollView = AIChatIntrinsicScrollView()
        let textView = AIChatTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(placeholder)
        textView.placeholder = placeholder

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.onHeightChange = onHeightChange
        scrollView.connect(textView: textView)
        state.connect(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: AIChatIntrinsicScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        scrollView.onHeightChange = onHeightChange
        state.connect(textView)

        // FocusState 在 NSViewRepresentable 更新周期里可能比 AppKit first responder
        // 慢一拍：首字符让发送按钮 enabled、或输入跨行改变高度时都会触发这里重跑。
        // 若把瞬时 false 解释为“主动失焦”，就会中断英文连续输入和中文 marked text。
        // 因此该 binding 只承担外部“请求聚焦”；真实失焦由 textDidEndEditing 反向同步。
        if isFocused.wrappedValue, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                guard isFocused.wrappedValue else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatNativeTextEditor
        private var wasEmpty = true

        init(parent: AIChatNativeTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused.wrappedValue {
                parent.isFocused.wrappedValue = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused.wrappedValue {
                parent.isFocused.wrappedValue = false
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let isEmpty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isEmpty != wasEmpty {
                wasEmpty = isEmpty
                parent.onEmptyStateChange(isEmpty)
            }
            textView.needsDisplay = true
            (textView.enclosingScrollView as? AIChatIntrinsicScrollView)?.textDidChange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if parent.requiresCommandReturn {
                if modifiers.contains(.command) {
                    parent.onSubmit()
                } else {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                }
            } else if modifiers.contains(.shift) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}

/// 输入框高度常量集中在这里，SwiftUI 首帧与 AppKit 后续测量必须使用同一公式。
private enum AIChatEditorMetrics {
    static let minimumLines: CGFloat = 2
    static let maximumLines: CGFloat = 4
    static let verticalInset: CGFloat = 4

    static var defaultHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil(NSLayoutManager().defaultLineHeight(for: font) * minimumLines + verticalInset)
    }
}

/// 默认 2 行，只在文本真实跨行时改变高度；4 行之外由内部滚动承接。
private final class AIChatIntrinsicScrollView: NSScrollView {
    private weak var managedTextView: NSTextView?
    private var measuredHeight = AIChatEditorMetrics.defaultHeight
    var onHeightChange: ((CGFloat) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        guard let textView = managedTextView else { return }
        let availableWidth = contentSize.width
        if abs(textView.frame.width - availableWidth) >= 0.5 {
            textView.setFrameSize(NSSize(width: availableWidth, height: max(textView.frame.height, measuredHeight)))
            textDidChange()
        }
    }

    func connect(textView: NSTextView) {
        managedTextView = textView
        textDidChange()
    }

    func textDidChange() {
        guard let textView = managedTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 13))
        let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2)
        let minimumHeight = lineHeight * AIChatEditorMetrics.minimumLines + AIChatEditorMetrics.verticalInset
        let maximumHeight = lineHeight * AIChatEditorMetrics.maximumLines + AIChatEditorMetrics.verticalInset
        let nextHeight = min(max(contentHeight, minimumHeight), maximumHeight)
        let documentHeight = max(contentHeight, nextHeight)
        if abs(textView.frame.height - documentHeight) >= 0.5 {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: documentHeight))
        }
        guard abs(nextHeight - measuredHeight) >= 0.5 else { return }
        measuredHeight = nextHeight
        invalidateIntrinsicContentSize()
        // 避免在 AppKit layout 栈内同步写 SwiftUI State；回到下一主线程周期提交低频高度档位。
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(nextHeight)
        }
    }
}

/// `NSTextView` 没有公开 placeholder API，这个轻量子类只在空内容且未输入时绘制提示。
private final class AIChatTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}

#Preview("AIChatInputView") {
    StatefulPreview()
        .frame(width: 540)
        .environment(AppSettings.shared)
}

/// 预览容器：把 `@State` 包一层，避免 #Preview 里写 binding 样板。
private struct StatefulPreview: View {
    @State private var pendingReplacement: String?
    @State private var sending: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack {
            AIChatInputView(
                pendingReplacement: $pendingReplacement,
                focus: $isFocused,
                isSending: sending,
                onSend: { _ in
                    sending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        sending = false
                    }
                },
                onCancel: {
                    sending = false
                }
            )
        }
    }
}
