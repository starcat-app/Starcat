//
//  RepoNoteDrawer.swift
//  Starcat
//
//  仓库笔记的右侧抽屉与独立窗口共享界面。在固定操作栏内替换唯一的正文视口。
//

import AppKit
import MarkdownUI
import SwiftUI

/// 编辑、Markdown 预览和 AI 审阅分别占用同一个正文位置。
struct RepoNoteDrawer: View {
    let workspace: RepoNotesWorkspace
    private let onCloseWindow: (() -> Void)?

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppSettings.self) private var settings
    @State private var mode: Mode
    @State private var showsDraft: Bool
    @State private var panelContentOpacity: Double = 1
    @State private var windowReference = WorkspaceSceneWindowReference()
    @State private var escapeMonitor: Any?

    enum Mode: Hashable { case edit, preview }

    init(
        workspace: RepoNotesWorkspace,
        mode: Mode? = nil,
        showsDraft: Bool = true,
        onCloseWindow: (() -> Void)? = nil
    ) {
        self.workspace = workspace
        self.onCloseWindow = onCloseWindow
        _mode = State(initialValue: mode ?? (workspace.hasContent ? .preview : .edit))
        _showsDraft = State(initialValue: showsDraft)
    }

    private var ai: RepoNoteAIGenerationViewModel { workspace.ai }
    private var showsAI: Bool { ai.shouldExpandNotesOnReturn }
    private var isReviewing: Bool { ai.phase == .awaitingConfirmation || ai.phase == .applying }
    private var isDetached: Bool { onCloseWindow != nil }
    private var isPresented: Bool { isDetached || workspace.isDrawerOpen }

    private var modeSelection: Binding<Mode> {
        Binding(get: { mode }, set: { newMode in
            guard mode != newMode else { return }
            Task {
                await RepoPanelContentTransition.replace(opacity: $panelContentOpacity, reduceMotion: reduceMotion) {
                    mode = newMode
                }
            }
        })
    }

    var body: some View {
        let panelShape = RoundedRectangle(cornerRadius: isDetached ? 0 : 16, style: .continuous)

        VStack(spacing: 0) {
            if !isDetached {
                titleBar
                Divider()
            }
            modeBar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(panelContentOpacity)
                .background(StarcatSurface.editor(colorScheme: colorScheme))
            Divider()
            footer
        }
        .background(StarcatSurface.panel(colorScheme: colorScheme))
        .clipShape(panelShape)
        .overlay {
            if !isDetached {
                panelShape
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .shadow(color: isDetached ? .clear : .black.opacity(colorScheme == .dark ? 0.3 : 0.16), radius: 10, y: 3)
        .background {
            WorkspaceSceneWindowReader(reference: windowReference, minimumContentSize: nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .onAppear(perform: installEscapeMonitor)
        .onDisappear(perform: removeEscapeMonitor)
        .onExitCommand(perform: close)
        .onChange(of: dependencies.databaseScopeRevision) { _, revision in
            // 账号切换后旧库已不可写，直接收回独立窗口中的私人内容。
            if isDetached, revision != workspace.scope.databaseRevision {
                windowReference.window?.close()
            }
        }
        .onChange(of: ai.phase) { _, phase in
            if phase == .running {
                showsDraft = true
            } else if phase == .completed {
                mode = .preview
            }
        }
    }

    private var titleBar: some View {
        RepoPanelHeader(repo: workspace.repo, title: "repo.notes.panelTitle") {
            RepoPanelHeaderActions(
                onClose: close,
                onOpenDetachedWindow: openDetachedWindow,
                onToggleExpanded: { workspace.isDrawerMaximized.toggle() },
                isExpanded: workspace.isDrawerMaximized,
                isDetachDisabled: !workspace.isLoaded
            )
            .disabled(workspace.isClosing || ai.phase == .applying)
        }
    }

    private var modeBar: some View {
        HStack(spacing: 8) {
            if isReviewing {
                Picker("repo.privateNotes", selection: $showsDraft) {
                    Text("repo.notes.ai.originalNote").tag(false)
                    Text("repo.notes.ai.draft").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                if ai.phase == .awaitingConfirmation {
                    Text("repo.notes.ai.step.awaitingConfirmation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                copyDraftButton
            } else if showsAI {
                Label("repo.notes.ai.progressTitle", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(ai.resolvedStepCount)/\(RepoNoteAIGenerationStep.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !ai.draftMarkdown.isEmpty {
                    copyDraftButton
                }
            } else {
                Picker("repo.privateNotes", selection: modeSelection) {
                    Text("repo.notes.editor.tabEdit").tag(Mode.edit)
                    Text("repo.notes.editor.tabPreview").tag(Mode.preview)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                RepoNoteAIGenerationHeaderControl(
                    viewModel: ai,
                    hasExistingNote: workspace.hasContent,
                    onGenerate: workspace.startGeneration
                )
                .disabled(!workspace.isLoaded || workspace.isClosing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .controlSize(.small)
    }

    private var copyDraftButton: some View {
        CopyFeedbackButton(
            providesContent: { ai.draftMarkdown },
            tooltip: "repo.notes.ai.copyDraft"
        ) { didCopy in
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(didCopy ? Color.green : .secondary)
                .frame(width: 24, height: 24)
                .accessibilityLabel(didCopy ? Text("common.copy.copied") : Text("repo.notes.ai.copyDraft"))
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let key = workspace.loadErrorKey {
            VStack(spacing: 8) {
                Text(LocalizedStringKey(key))
                    .foregroundStyle(.secondary)
                Button("action.retry") { Task { await workspace.loadIfNeeded() } }
            }
        } else if !workspace.isLoaded {
            ProgressView()
                .controlSize(.small)
        } else if showsAI || mode == .preview {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isReviewing {
                        noteMarkdown(
                            showsDraft ? ai.draftMarkdown : ai.sourceNoteSnapshot,
                            emptyKey: "repo.notes.empty"
                        )
                    } else if showsAI {
                        RepoNoteAIProgress(viewModel: ai)
                        if !ai.draftMarkdown.isEmpty {
                            Divider()
                            noteMarkdown(ai.draftMarkdown, emptyKey: "repo.notes.empty")
                        }
                    } else {
                        noteMarkdown(workspace.content, emptyKey: "repo.notes.editor.emptyPreview")
                    }
                }
                .padding(20)
            }
            .detailScrollViewStyle()
        } else {
            RepoNoteTextEditor(
                content: Binding(get: { workspace.content }, set: workspace.updateContent),
                placeholder: .l10n("repo.notesPlaceholder"),
                font: MarkdownTypography.nativeFont(
                    scale: scale, adjustment: settings.readmeFontSizeAdjustment, baseline: .repositoryPanel
                ),
                isEditable: !workspace.isClosing,
                onClose: close
            )
        }
    }

    private func noteMarkdown(_ content: String, emptyKey: LocalizedStringKey) -> some View {
        Group {
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(emptyKey)
                    .starcatMarkdownBodyFont(baseline: .repositoryPanel)
                    .foregroundStyle(.secondary)
            } else {
                Markdown(content)
                    .starcatMarkdownStyle(baseline: .repositoryPanel)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let key = ai.errorMessageKey {
                Label(LocalizedStringKey(key), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(ai.errorDetail ?? String.l10n(key))
            }
            if showsAI {
                if isReviewing {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            replacementNotice.fixedSize()
                            Spacer(minLength: 0)
                            reviewActions
                        }
                        VStack(alignment: .trailing, spacing: 8) {
                            replacementNotice.frame(maxWidth: .infinity, alignment: .leading)
                            reviewActions
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Spacer()
                        if ai.phase == .running {
                            Button("repo.notes.ai.cancel", action: ai.cancel)
                        } else {
                            Button("repo.notes.ai.discard", action: workspace.discardGeneration)
                            Button("repo.notes.ai.retry", action: workspace.startGeneration)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                saveIndicator
            }
        }
        .font(.caption2)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var replacementNotice: some View {
        if workspace.hasContent {
            Text("repo.notes.ai.replaceNotice")
                .foregroundStyle(.secondary)
        }
    }

    private var reviewActions: some View {
        HStack(spacing: 8) {
            if ai.phase == .applying {
                ProgressView().controlSize(.mini)
                Text("repo.notes.ai.saving")
            } else {
                Button("repo.notes.ai.discard", action: workspace.discardGeneration)
                Button("repo.notes.ai.regenerate", action: workspace.startGeneration)
                Button("repo.notes.ai.applyToNote") { Task { await workspace.applyDraft() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ai.canApplyDraft || workspace.isSaving)
            }
        }
        .disabled(workspace.isClosing)
    }

    @ViewBuilder
    private var saveIndicator: some View {
        if workspace.isSaving {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("repo.notes.saving")
            }
            .foregroundStyle(.secondary)
        } else if workspace.saveFailed {
            Button("repo.notes.saveContentFailed") { Task { await workspace.flush() } }
                .help("action.retry")
        } else if workspace.hasUnsavedChanges {
            Label("repo.notes.saveIdle", systemImage: "pencil.circle")
                .foregroundStyle(.secondary)
        } else if workspace.hasContent || workspace.noteViewModel.note?.editedAt != nil {
            Label {
                Text("repo.notes.saved")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private func openDetachedWindow() {
        RepoNoteWindowController.show(
            workspace: workspace,
            mode: mode,
            showsDraft: showsDraft,
            sourceWindow: windowReference.window,
            dependencies: dependencies
        )
        workspace.isDrawerOpen = false
    }

    private func close() {
        if let onCloseWindow {
            onCloseWindow()
        } else {
            Task { await workspace.closeDrawer() }
        }
    }

    /// 预览不抢焦点。Esc 只在浮层所在窗口接管，输入法组合文本仍交给原编辑器处理。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [workspace, windowReference, onCloseWindow] event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  (onCloseWindow != nil || workspace.isDrawerOpen),
                  let window = windowReference.window,
                  event.window === window,
                  (window.firstResponder as? NSTextView)?.hasMarkedText() != true
            else { return event }

            if let onCloseWindow {
                onCloseWindow()
            } else {
                Task { await workspace.closeDrawer() }
            }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }
}

/// 独立笔记使用普通可缩放窗口，持有原浮层的会话，切换详情仓库时继续可用。
@MainActor
final class RepoNoteWindowController: NSWindowController, NSWindowDelegate {
    private static var instances: [RepoNotesScope: RepoNoteWindowController] = [:]
    private let workspace: RepoNotesWorkspace

    static func workspace(for scope: RepoNotesScope) -> RepoNotesWorkspace? {
        instances[scope]?.workspace
    }

    static func focusIfOpen(for scope: RepoNotesScope) -> Bool {
        guard let window = instances[scope]?.window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// 按数据库作用域和仓库复用窗口，避免同一份草稿分到两个编辑器。
    static func show(
        workspace: RepoNotesWorkspace,
        mode: RepoNoteDrawer.Mode,
        showsDraft: Bool,
        sourceWindow: NSWindow?,
        dependencies: AppDependencies
    ) {
        guard !focusIfOpen(for: workspace.scope) else { return }
        let visibleFrame = sourceWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let size = RepoWorkspaceWindowController.contentSize(available: visibleFrame?.size)
        let contentSize = NSSize(width: min(760, size.width), height: size.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(String.l10n("repo.notes.panelTitle")) · \(workspace.repo.fullName)"
        window.contentMinSize = NSSize(width: min(420, size.width), height: min(300, size.height))
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        let controller = RepoNoteWindowController(window: window, workspace: workspace)
        let host = NSHostingController(rootView: RepoNoteDrawer(
            workspace: workspace,
            mode: mode,
            showsDraft: showsDraft,
            onCloseWindow: { [weak window] in window?.performClose(nil) }
        ).appHostEnvironment(dependencies))
        host.sizingOptions = []
        window.contentViewController = host
        // 挂载正文后再设窗口尺寸，避免初始大小随编辑器或预览的理想尺寸变化。
        window.setContentSize(contentSize)
        if let visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
        window.delegate = controller
        instances[workspace.scope] = controller
        window.makeKeyAndOrderFront(nil)
    }

    private init(window: NSWindow, workspace: RepoNotesWorkspace) {
        self.workspace = workspace
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepoNoteWindowController does not support storyboard initialization")
    }

    /// 系统关闭按钮、⌘W 和 Esc 都需要等待持久化。直接 close 避免再次派发关闭请求。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { await workspace.closeAfterSaving { sender.close() } }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        Self.instances[workspace.scope] = nil
    }
}

/// NSTextView 持有滚动、选区和撤销，空白提示使用同一个文字容器的原点和字体。
private struct RepoNoteTextEditor: NSViewRepresentable {
    @Binding var content: String
    let placeholder: String
    let font: NSFont
    let isEditable: Bool
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorScrollView()
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = TextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        MarkdownTypography.applyEditorFont(font, to: textView)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? TextView else { return }
        textView.isEditable = isEditable
        guard !textView.hasMarkedText() else { return }
        if textView.string != content {
            textView.string = content
            textView.needsDisplay = true
        }
        MarkdownTypography.applyEditorFont(font, to: textView)
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.setAccessibilityLabel(placeholder)
            textView.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RepoNoteTextEditor

        init(parent: RepoNoteTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? TextView else { return }
            if !textView.hasMarkedText() { parent.content = textView.string }
            textView.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  !textView.hasMarkedText() else { return false }
            parent.onClose()
            return true
        }
    }

    /// 让空笔记也铺满可点击的正文区，长文仍由原生滚动视图承载。
    private final class EditorScrollView: NSScrollView {
        override func layout() {
            super.layout()
            guard let textView = documentView as? NSTextView else { return }
            let minimumSize = NSSize(width: 0, height: contentSize.height)
            guard textView.minSize != minimumSize else { return }
            textView.minSize = minimumSize
            textView.sizeToFit()
        }
    }

    private final class TextView: NSTextView {
        var placeholder = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, isEditable { window.makeFirstResponder(self) }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText(), let font, let textContainer else { return }
            let padding = textContainer.lineFragmentPadding
            let origin = textContainerOrigin
            (placeholder as NSString).draw(
                with: NSRect(
                    x: origin.x + padding, y: origin.y,
                    width: max(0, textContainer.containerSize.width - 2 * padding),
                    height: max(0, bounds.height - origin.y)
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.placeholderTextColor,
                    .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default
                ]
            )
        }
    }
}
