//
//  NoteEditorSheet.swift
//  Starcat
//
//  Repo 私有笔记大窗口编辑 Sheet（2026-06-13 新增）。
//
//  使用场景：
//  - inline `RepoNotesSection.notesEditor` 固定 3 行高，长笔记 / 想看 markdown 渲染时点击
//    右下角 `arrow.up.left.and.arrow.down.right` overlay 按钮 → 弹起本 Sheet。
//
//  设计取舍（grill-me 决策表，2026-06-13）：
//  - **数据共享**：通过 `@Binding var content` 与 inline 共享同一份 `editingContent`，
//    用户在 sheet 内的输入实时反映到 inline buffer（即便 sheet 期间 inline 被遮挡，关闭后立即可见）。
//  - **保存策略**：复用 inline 的 800ms debounce → flush 链路（inline 的 `.task(id: editingContent)`
//    在 sheet 弹起期间仍然存活、仍然会跑），无独立 sheet 内 timer；为了避免"关闭瞬间 timer 未到点
//    就 dismiss 导致丢失"，sheet 关闭前主动 `await onFlush()` 兜底一次。无"取消改动"语义。
//  - **关闭路径**：Esc / 点"完成"按钮 / 系统 sheet dismiss 都走同一个 `close()` 异步流程。
//    Cmd+W 由系统接管（NSWindow 标准响应链会调 dismiss），同样会走 close 兜底。
//  - **键盘快捷键最小化**：除 Esc 关闭外不绑其它快捷键（dong4j A7 决策：minimal）。
//  - **布局**：顶部 toolbar 行（Picker 编辑/预览 + 标题 + 完成按钮）/ Divider / 内容区
//    （编辑 = TextEditor 大窗 / 预览 = ScrollView + Markdown 渲染）。
//  - **Markdown 渲染**：复用项目已有的 `MarkdownUI`（已在 `project.yml.packages`，`ReleaseTimelineView` /
//    `ActivityReleaseDetailContent` 是同款用法）。不引入新依赖。
//  - **空预览态**：content 全空白时 Preview tab 显示引导文案而非空白，避免"切到预览什么也没有"的困惑。
//
//  尺寸（v2，2026-06-13 真机验收后调整）：
//  - 默认 `idealWidth = 880 / idealHeight = 640`（v1 720×560 在 27" 显示器上偏小）。
//  - `minWidth = 560 / minHeight = 420` —— 用户可拖拽 sheet 边缘调整大小。
//  - 不提供"最大化"按钮（sheet 模态不支持，也无必要）。
//
//  ⚠️ macOS Sheet 可拖拽 + minSize 的关键 hack（v2 / v2.1 关键修正）：
//  -----------------------------------------------------------------------------
//  SwiftUI macOS Sheet 默认 `NSWindow.styleMask` **不含** `.resizable`,即便 content
//  的 frame 给了 `minWidth/maxWidth = .infinity` 范围,用户仍然看不到 resize cursor、拖不动
//  sheet 边缘。这是 SwiftUI 的限制（SwiftUI 不暴露 sheet host window 配置 API）。
//
//  此外（v2.1 增补）：SwiftUI 的 `.frame(minWidth: minHeight:)` **在 NSWindow 拖拽路径
//  上不被尊重** —— NSWindow 不知道 SwiftUI content 的 layout 约束，用户可以把 sheet
//  拖到极小尺寸（< 200×100）让按钮 / Picker 错位。必须从 AppKit 侧显式设
//  `NSWindow.minSize = NSSize(...)` 作为"硬阻挡"。
//
//  解决方案：用 `NSViewRepresentable` 在 sheet 渲染时拿到 underlying NSWindow,
//  同时 insert `.resizable` styleMask + 设 `minSize` —— 这种 trick 在 SwiftUI macOS
//  项目里很常见。实现见 `NoteEditorSheetWindowConfigurator`,通过 `.background(...)` 注入。
//  -----------------------------------------------------------------------------
//
//  关键约束（写入注释作为永久记录）：
//  - sheet 内 TextEditor **不**自己跑防抖任务 —— inline 那一份 `.task(id: editingContent)` 是单一信任源；
//    重复跑会产生竞态（两份 800ms timer 同时倒计时、各调一次 saveContent，repository 端 upsert 幂等但浪费 IO）。
//  - `onFlush` 必须是 idempotent —— 若 inline 防抖刚好同帧落库、sheet 关闭再 flush 一次，repository 层
//    `updateContent(repoId:content:)` 是 upsert 不会产生副作用。
//  - 关闭按钮用 `.borderedProminent` + `.keyboardShortcut(.escape, modifiers: [])`：dong4j A7 决策"只用 Esc"。
//    Esc 在 macOS 习惯里是「取消 / 不保存」，但本组件 A6 决策为「自动保存无取消」，所以 Esc = 「完成并关闭」语义一致。
//

import AppKit
import MarkdownUI
import SwiftUI

struct NoteEditorSheet: View {

    /// 用于 sheet 标题展示的 repo full name（如 `owner/repo`）。
    let repoName: String

    /// 与 inline 共享的笔记内容 binding。
    /// 用户在 sheet 内的输入实时同步到 inline 的 `editingContent` `@State`。
    @Binding var content: String

    /// 关闭前的 flush 闭包 —— 由父 view 提供（`RepoNotesSection.flushContent`）。
    /// async 设计：让父 view 有机会在 await DB 写入完成后再 dismiss。
    let onFlush: () async -> Void

    @Environment(\.dismiss) private var dismiss

    /// 当前 Tab：编辑 or 预览。默认进入"编辑"。
    @State private var mode: Mode = .edit

    enum Mode: Hashable {
        case edit
        case preview
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contentArea
        }
        .frame(
            minWidth: 560,
            idealWidth: 880,
            maxWidth: .infinity,
            minHeight: 420,
            idealHeight: 640,
            maxHeight: .infinity
        )
        // v2：通过 background NSViewRepresentable 拿到 sheet host NSWindow，给它加 .resizable
        // styleMask，让用户能拖拽 sheet 边缘改大小。详见文件头「macOS Sheet 可拖拽的关键 hack」。
        .background(NoteEditorSheetWindowConfigurator())
    }

    // MARK: - Toolbar

    /// 顶部工具栏（v2.2 重排，2026-06-13 真机验收后单行紧凑布局）。
    ///
    /// 设计要点（修复 v2.1 "乱"问题）：
    /// - **单行 toolbar 高度**：从 v2.1 双行小字（caption2 "私有笔记" + caption repoName）收缩为单行
    ///   `note.text icon + repoName(headline)`,标题视觉权重显著提升;
    /// - **去掉 "私有笔记" 二级标题**：sheet 是从私有笔记 inline 输入框右下角"展开"按钮进来的,
    ///   上下文已经表明这是私有笔记编辑场景,toolbar 再写一遍 "私有笔记" 是冗余信息;
    /// - **化解蓝色视觉竞争**：Picker(.segmented) 选中态蓝色 + 右侧"完成" borderedProminent 蓝色
    ///   两块蓝色视觉打架是 v2.1 反馈"乱"的根因之一。本期处理：
    ///   ① Picker 宽度 200 → 160（减少蓝色填充面积，segmented 2 个 option 不需要那么宽）;
    ///   ② 中央 headline repoName 视觉权重显著提升,作为 hierarchy 第一焦点,Picker / 完成按钮
    ///     退到次焦点；
    /// - **Picker 用 `.segmented` 样式**：macOS 上"编辑/预览"切换的标准控件;
    /// - **"完成"按钮 borderedProminent**：主操作 + Esc 快捷键(A7 minimal)。
    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                Text("repo.notes.editor.tabEdit").tag(Mode.edit)
                Text("repo.notes.editor.tabPreview").tag(Mode.preview)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(repoName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                Task { await close() }
            } label: {
                Text("repo.notes.editor.done")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.escape, modifiers: [])
            .focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content Area

    /// 内容区：编辑 = TextEditor / 预览 = MarkdownUI 渲染。
    @ViewBuilder
    private var contentArea: some View {
        switch mode {
        case .edit:
            editArea
        case .preview:
            previewArea
        }
    }

    /// 编辑模式：纯 TextEditor 填满剩余空间。
    ///
    /// `.scrollContentBackground(.hidden)` 让 macOS 系统默认的 NSTextView 背景透出（去掉那层灰），
    /// 再用 `Color(nsColor: .textBackgroundColor)` 作为统一可视背景，与 inline 视觉一致。
    private var editArea: some View {
        TextEditor(text: $content)
            .font(.system(.body, design: .default))
            .scrollContentBackground(.hidden)
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .topLeading) {
                if content.isEmpty {
                    // v2.2（2026-06-17）与 inline RepoNotesSection 同款：首行光标 Y 不再叠加
                    // textContainerInset.height，实际位置 = (16+5, 16) = (21, 16)。
                    Text("repo.notesPlaceholder")
                        .font(.system(.body, design: .default))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 21)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
    }

    /// 预览模式：MarkdownUI 渲染。
    ///
    /// 空内容时显示引导文案；非空时渲染 markdown。
    /// `textSelection(.enabled)` 让预览文本可选中复制（与项目其它 Markdown 用法对齐）。
    @ViewBuilder
    private var previewArea: some View {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollView {
            if trimmed.isEmpty {
                HStack {
                    Text("repo.notes.editor.emptyPreview")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(20)
            } else {
                Markdown(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Close

    /// 统一关闭流程：先 flush 落库，再 dismiss。
    ///
    /// 防御性 await：即使 inline 的 800ms 防抖 timer 还在跑（未到点），
    /// onFlush 会直接同步调 repository.updateContent，确保最新内容落库。
    /// repository 的 upsert 是 idempotent，与 inline timer 落库不会产生副作用。
    private func close() async {
        await onFlush()
        dismiss()
    }
}

// MARK: - Window Configurator (v2)

/// 给 SwiftUI macOS Sheet host NSWindow 注入 `.resizable` styleMask，让用户能拖拽 sheet 边缘改大小。
///
/// **为什么需要它**：
/// SwiftUI 的 `.sheet(...)` 在 macOS 上默认生成的 NSWindow `styleMask` 不含 `.resizable`,
/// 即使 content 的 frame 用了 `minWidth/maxWidth: .infinity` 也无法拖拽。SwiftUI 没暴露
/// 让用户配置 sheet host window 的 API，所以必须借助 AppKit。
///
/// **实现细节**：
/// 1. `NSViewRepresentable` 返回一个空 NSView，靠它"寄生"到 sheet view hierarchy；
/// 2. `viewDidMoveToWindow` 第一次回调时（NSView 已被加入 NSWindow 的 view tree）拿到 `view.window`；
/// 3. 给该 window 的 styleMask insert `.resizable`,效果立即生效。
///
/// **为什么不在 makeNSView 里直接 DispatchQueue.main.async 拿 window**：
/// 那是常见但脆弱的 timing 写法 —— `makeNSView` 调用时 view 还没加入 window，async 闭包跑时
/// 可能 view 已加入也可能没加入，取决于 SwiftUI 内部实现。子类化 NSView 重写 `viewDidMoveToWindow`
/// 是 AppKit 推荐的方式，时机精确且不依赖 dispatch 延迟。
///
/// **副作用**：仅修改 styleMask，不持有 window，不监听其它事件。
private struct NoteEditorSheetWindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        WindowProbeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // no-op
    }

    /// NSView 子类，借 `viewDidMoveToWindow` 精确捕获"加入 sheet host window 的瞬间"。
    ///
    /// v2.1（2026-06-13）增补：除了 insert `.resizable`,还要显式设 `NSWindow.minSize`。
    ///
    /// v2.2（2026-06-13 真机验收后）：dong4j 反馈 v2.1 minSize 仍不生效。根因：SwiftUI macOS
    /// sheet 的 NSWindow sizing 会被 SwiftUI 后续 layout pass 重新计算覆盖。修法**三重保险**：
    /// 1. **同时设 `minSize` + `contentMinSize`**：前者管整窗口（含标题栏）的最小尺寸，后者管 content
    ///    view 区域的最小尺寸,sheet 没有标题栏所以二者数值一致,但 SwiftUI 在不同 layout pass 阶段
    ///    可能优先使用哪一个不确定，两个都设最稳;
    /// 2. **`viewDidMoveToWindow` 第一次设**：sheet attach 到 host window 的同帧立即设;
    /// 3. **`DispatchQueue.main.asyncAfter(0.1s)` 兜底再设一次**：等 SwiftUI 完成所有初始 layout pass、
    ///    body frame 的 `minWidth/minHeight` 把 window sizing 重算之后,我们再覆盖一遍。0.1s 是
    ///    经验值（SwiftUI sheet 的初始 layout 通常 1-2 个 RunLoop tick 完成,100ms 足够覆盖）。
    private final class WindowProbeView: NSView {
        private static let editorMinSize = NSSize(width: 560, height: 420)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            applyWindowConfiguration(to: window)

            // 兜底：SwiftUI 后续 layout pass 可能重置 sizing,延迟一帧 + 一帧再设一次。
            // 不能保证一次 async 就够（SwiftUI 内部 hosting pass 数量不固定）,asyncAfter 0.1s 经验上足够。
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.applyWindowConfiguration(to: window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let window = self.window else { return }
                self.applyWindowConfiguration(to: window)
            }
        }

        /// 把 styleMask / minSize / contentMinSize 三件套统一应用到 sheet host window。
        ///
        /// insert / set 都是幂等操作，多次调用无副作用。
        private func applyWindowConfiguration(to window: NSWindow) {
            window.styleMask.insert(.resizable)
            window.minSize = Self.editorMinSize
            window.contentMinSize = Self.editorMinSize
        }
    }
}
