//
//  AIChatInputView.swift
//  Starcat
//
//  AI 助手窗口底部固定的输入条（HOM-150 / Y9 增强 / 2026-06-15 多行毛玻璃重写）。
//
//  设计要点：
//  - 多行 TextField + 圆角毛玻璃容器：默认 1 行高、自动撑到 4 行、超出内部滚动；
//  - Return 直接发送 / Shift+Return 换行（主流 ChatGPT / Claude 行为）；
//  - 发送过程禁用 TextField，避免并发触发 stream；
//  - 输入为空或正在发送时按钮 disabled，按钮的颜色 / 透明度由 SwiftUI 系统行为提供
//    视觉反馈，不需要手写额外样式。
//
//  2026-06-15 重写（dong4j 反馈参考 chat 输入框样式）：
//  - 由「单行 HStack」改为「文本区在上 + 控件行在下」的圆角毛玻璃容器；
//  - TextField 用 `axis: .vertical` + `lineLimit(1...4)` 实现软上限自动撑高
//    （macOS 13+ 原生能力，项目最低 macOS 15 直接可用）；
//  - Return / Shift+Return 用 `.onKeyPress(.return)` 显式分流。
//    **关键**：macOS 上 `axis: .vertical` 模式下 SwiftUI **不再触发 `.onSubmit`**
//    （与 iOS 行为不同），Enter 默认走"换行"语义，所以必须 onKeyPress 拦截：
//      · 无 modifier 的 Return → trySend() + return `.handled`（吞掉，不换行）；
//      · Shift+Return → return `.ignored`（放行 SwiftUI 默认换行行为）。
//    `.onKeyPress` 是 macOS 14+ API，本项目最低 macOS 15 满足。
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
//  - 输入草稿用本子组件的 `@State private var text`，**不放进窗口根级
//    `RepoAIChatViewModel`**——否则每个按键都会让摘要和聊天 Markdown 子树重新
//    参与依赖检查（实测 M1 Pro 都能感觉到键入卡顿）。
//  - 历史问题「修改」通过 `pendingReplacement: Binding<String?>` 单向通道回填：
//    上层只需 `pendingChatDraftReplacement = oldContent`，子组件 `.onChange`
//    捕获后写回内部 `text` 并把 binding 置 nil（一次性，避免重复覆盖）。
//

import SwiftUI

struct AIChatInputView: View {

    /// 输入草稿属于输入组件自己的瞬时 UI 状态。不能放进窗口根级 ViewModel，
    /// 否则每个按键都会让摘要和聊天 Markdown 子树重新参与依赖检查。
    @State private var text: String = ""

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
        // 2026-06-15 13:31 dong4j 反馈"和下方上下文行之间空白太多"：原 `.vertical 10`
        // 让卡片下方有 10pt + chatContextStatusRow 顶部 6pt = 16pt 空白。把**底部**
        // 收到 4pt（与上下文行顶部 2pt 合计 6pt 紧凑间距）；顶部保持 10pt 让卡片
        // 与上方 Divider 有呼吸感。
        .padding(.top, 10)
        .padding(.bottom, 4)
        .onChange(of: pendingReplacement) { _, replacement in
            guard let replacement else { return }
            text = replacement
            pendingReplacement = nil
        }
    }

    // MARK: - 文本编辑区

    /// 多行 TextField，软上限 1-4 行。
    ///
    /// 关键技术点：
    /// - `axis: .vertical` + `lineLimit(1...4)`：单行起步，自动撑到 4 行，超出后
    ///   TextField 内部出现滚动（SwiftUI 自带，无需 ScrollView 包装）。
    /// - `.onKeyPress(.return)` 处理 Return 分流——见文件头注释关于
    ///   macOS `axis: .vertical` 下 `.onSubmit` 不触发的说明。
    private var textEditor: some View {
        TextField(
            "ai.assistant.input.placeholder",
            text: $text,
            axis: .vertical
        )
        .focused(focus)
        .textFieldStyle(.plain)
        .font(.body)
        .lineLimit(1...4)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .disabled(isSending)
        // `.onKeyPress(keys:action:)` 是带 1 参 `KeyPress` 的重载（macOS 14+），
        // 与 0 参的 `.onKeyPress(_:action:)` 区分；用前者才能拿到 modifier 判 Shift。
        .onKeyPress(keys: [.return]) { keyPress in
            // Shift+Return → 让 TextField 自己处理换行（`.vertical` 模式默认行为）。
            if keyPress.modifiers.contains(.shift) {
                return .ignored
            }
            // 无 modifier 的 Return → 触发发送，吞掉换行事件。
            trySend()
            return .handled
        }
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
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 空闲态：输入为空 → 禁用；流式态：永远可点（"停止"是主操作，必须可点）。
        .disabled(!isSending && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        onSend(trimmed)
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
