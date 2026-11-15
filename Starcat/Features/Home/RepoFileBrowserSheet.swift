//
//  RepoFileBrowserSheet.swift
//  Starcat
//
//  详情页「下载文件」Sheet：按原型做成顶栏身份 + 三张抬起卡片（左树 / 中预览 / 右详情）。
//
//  从 RepoListView 的实际宿主窗口交给共用 AppKit 画布，避免工具栏菜单的 sheet 尺寸协商。
//  左栏 checkbox 与展开是两个独立 Button；点文件名只拉预览，不改勾选。
//  原型没有 checkbox，但批量下载需要勾选，所以树行左侧保留。
//  Sheet 规范仍要求右上角 `SheetCloseButton`；原型窗口红绿灯在 AppKit chrome 上，这里补关闭钮。
//  打开时只展示文件树；点文件后左树收窄，预览 + 详情从右侧滑入。
//  切分支会清空预览，三栏收回，避免对着旧文件发呆。
//

import SwiftUI
import AppKit

struct RepoFileBrowserSheet: View {
    let target: RepoFileBrowserTarget
    let apiClient: any GitHubAPIClientProtocol
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: RepoFileBrowserViewModel
    @State private var readingLayout = RepoFileReadingLayout()
    @State private var expandedPaths: Set<String> = []
    @State private var presentedPreview: RepoFileBrowserViewModel.PreviewPhase = .idle
    @State private var presentedMarkdown: RepoFileBrowserViewModel.MarkdownPhase = .idle
    @State private var presentedRevision: UInt64 = 0
    @State private var isContentVisible = false
    @Namespace private var selectionNamespace
    @FocusState private var searchFocused: Bool

    init(target: RepoFileBrowserTarget, apiClient: any GitHubAPIClientProtocol, onClose: (() -> Void)? = nil) {
        self.target = target
        self.apiClient = apiClient
        self.onClose = onClose
        _viewModel = State(initialValue: RepoFileBrowserViewModel(target: target, apiClient: apiClient))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            header
            columns
            if !readingLayout.isExpanded || viewModel.isDownloading { footer }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.loadTree()
            await viewModel.loadBranches()
        }
        .onDisappear {
            viewModel.stop()
        }
        .onChange(of: dependencies.databaseScopeRevision) { _, _ in closeWorkspace() }
        .onChange(of: viewModel.currentRef) { _, _ in
            readingLayout.isExpanded = false
            expandedPaths = []
        }
        .onChange(of: viewModel.previewedPath) { _, path in
            if path == nil { readingLayout.isExpanded = false }
        }
        .onExitCommand {
            if !readingLayout.handleEscape() { closeWorkspace() }
        }
        .task(id: viewModel.previewRevision) {
            // 保留旧快照直到退场完成；数据请求已在点击时立即开始，不能被动画串行拖慢。
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12), completionCriteria: .removed) {
                    isContentVisible = false
                } completion: { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            presentedRevision = viewModel.previewRevision
            publishPreview()
        }
        .onChange(of: viewModel.preview) { _, _ in
            if presentedRevision == viewModel.previewRevision { publishPreview() }
        }
        .onChange(of: viewModel.markdown) { _, _ in
            if presentedRevision == viewModel.previewRevision { publishPreview() }
        }
        .toast(
            message: $viewModel.toastMessage,
            icon: viewModel.toastFileURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            duration: 4,
            iconColor: viewModel.toastFileURL == nil ? Color.orange : Color.green,
            bottomPadding: 24,
            actionLabel: viewModel.toastFileURL == nil ? nil : "repo.files.openFolder",
            onAction: {
                if let url = viewModel.toastFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        )
    }

    private var header: some View {
        RepoWorkspaceHeader(target: target) {
            RepoFileBranchPicker(
                branches: viewModel.branchPickerNames,
                selection: viewModel.currentRef,
                isDisabled: {
                    if viewModel.isRefreshing { return true }
                    switch viewModel.phase {
                    case .loading, .downloading: return true
                    default: return false
                    }
                }()
            ) { name in
                Task { await viewModel.selectBranch(name) }
            }
            searchField
            SheetCloseButton(action: closeWorkspace)
        }
    }

    /// 点过文件才展开预览栏。打开页、切分支清空预览后都只留文件树。
    private var isPreviewPresented: Bool {
        viewModel.previewedPath != nil
    }

    /// 未选文件时树占满内容区；选中后树收到 240，预览+详情从右侧滑入。
    /// 动画跟 RAG / Agent 收起 Inspector 同一档：短 easeInOut，减少动态效果时直接切。
    private var columns: some View {
        GeometryReader { geometry in
            let expanded = readingLayout.isExpanded && isPreviewPresented
            let overlay = readingLayout.usesInspectorOverlay(availableWidth: geometry.size.width)
            HStack(spacing: expanded ? 0 : 12) {
                // 不移除树，放大还原后目录展开、勾选及滚动位置继续保留。
                sidebar
                    .frame(width: isPreviewPresented ? 240 : nil)
                    .frame(maxWidth: isPreviewPresented ? nil : .infinity, maxHeight: .infinity)
                    .fileBrowserCard()
                    .frame(width: expanded ? 0 : nil)
                    .opacity(expanded ? 0 : 1)
                    .clipped()
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)
                if isPreviewPresented {
                    previewColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .fileBrowserCard()
                        .overlay(alignment: .trailing) {
                            if !expanded && overlay && readingLayout.showsInspector {
                                inspectorPanel
                                    .padding(8)
                                    .padding(.top, 106)
                                    .shadow(color: .black.opacity(0.12), radius: 8)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                    if !expanded && !overlay && readingLayout.showsInspector { inspectorPanel }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPreviewPresented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: readingLayout)
    }

    private var inspectorPanel: some View {
        ScrollView { inspector }
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .fileBrowserCard()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("repo.files.search.placeholder", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .disabled(viewModel.nodes.isEmpty)
            Text("⌘F")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 220)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            Button("repo.files.search.placeholder") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("repo.files.tab.files", selection: $viewModel.sidebarTab) {
                    Text("repo.files.tab.files").tag(RepoFileBrowserViewModel.SidebarTab.files)
                    Text("repo.files.tab.folders").tag(RepoFileBrowserViewModel.SidebarTab.folders)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                SyncIconButton(
                    isRefreshing: viewModel.isRefreshing,
                    disabled: viewModel.isRefreshing || viewModel.isDownloading || {
                        if case .loading = viewModel.phase { return true }
                        return false
                    }(),
                    tooltip: String.l10n("repo.files.refresh")
                ) {
                    Task { await viewModel.refreshTree() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            treeArea
        }
    }

    @ViewBuilder
    private var treeArea: some View {
        switch viewModel.phase {
        case .loading:
            treeSkeleton
        case .failed(let message):
            VStack(spacing: 12) {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Button("action.retry") {
                    Task { await viewModel.loadTree() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .downloading, .finished:
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.isTruncated {
                    Label("repo.files.truncated", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                if viewModel.displayedNodes.isEmpty {
                    Text(viewModel.isSearchActive ? "repo.files.search.empty" : "repo.files.empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(visibleTreeRows.enumerated()), id: \.element.node.path) { index, row in
                                RepoFileTreeRow(
                                    node: row.node,
                                    viewModel: viewModel,
                                    isExpanded: Binding(
                                        get: { viewModel.isSearchActive || expandedPaths.contains(row.node.path) },
                                        set: { expanded in
                                            if expanded { expandedPaths.insert(row.node.path) }
                                            else { expandedPaths.remove(row.node.path) }
                                        }
                                    ),
                                    rowIndex: index, depth: row.depth, selectionNamespace: selectionNamespace
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82),
                               value: viewModel.previewedPath)
                }
            }
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.previewedFile != nil {
                breadcrumb
                Divider()
                previewHeader
                Divider()
            }
            previewBody
                .blur(radius: reduceMotion || isContentVisible ? 0 : 10)
                .opacity(isContentVisible ? 1 : 0)
                .allowsHitTesting(isContentVisible && presentedRevision == viewModel.previewRevision)
                .accessibilityHidden(!isContentVisible)
                .overlay {
                    if !isContentVisible {
                        ReadmeSkeletonView()
                            .transition(.opacity)
                    }
                }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Text(verbatim: target.owner)
            breadcrumbChevron
            Text(verbatim: target.name)
            if let path = viewModel.previewedPath {
                ForEach(Array(path.split(separator: "/").map(String.init).enumerated()), id: \.offset) { _, part in
                    breadcrumbChevron
                    Text(verbatim: part)
                }
            }
            Spacer(minLength: 0)
            if let path = viewModel.previewedPath {
                CopyFeedbackButton(providesContent: { path }, tooltip: "repo.files.preview.copy") { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "square.on.square")
                        .font(.caption)
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var breadcrumbChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var previewHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            RepoFileIcon(name: viewModel.previewedFile?.name ?? "", size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: viewModel.previewedFile?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.previewedFile?.name ?? "")
                Text(verbatim: previewMetaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            if let text = viewModel.previewText {
                CopyFeedbackButton(
                    providesContent: { text },
                    tooltip: "repo.files.preview.copy",
                    style: .bordered
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "square.on.square")
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
            } else if let data = viewModel.previewImageData, let image = NSImage(data: data) {
                CopyFeedbackButton(
                    performCopy: {
                        NSPasteboard.general.clearContents()
                        return NSPasteboard.general.writeObjects([image])
                    },
                    tooltip: "repo.files.preview.copy",
                    style: .bordered
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "square.on.square")
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
            }
            if viewModel.isMarkdownPreview {
                Picker("repo.files.markdown.mode", selection: $viewModel.previewMode) {
                    Text("repo.files.markdown.rendered").tag(RepoFileBrowserViewModel.PreviewMode.rendered)
                    Text("repo.files.markdown.source").tag(RepoFileBrowserViewModel.PreviewMode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let rawURL = viewModel.githubRawURL {
                Button("repo.files.preview.raw") {
                    NSWorkspace.shared.open(rawURL)
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
            }
            previewLayoutButtons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var previewMetaLine: String {
        var parts: [String] = []
        if let size = viewModel.previewedFile?.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let date = commitDate {
            parts.append(RelativeTimeText.pastEvent(date, locale: locale, unitsStyle: .full))
        }
        if let lines = viewModel.previewLineCount {
            parts.append(String(format: String.l10n("repo.files.preview.linesFormat"), lines))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var previewBody: some View {
        switch presentedPreview {
        case .idle:
            Text("repo.files.preview.empty")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ReadmeSkeletonView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let content):
            RepoFileTextPreview(
                text: content, markdown: presentedMarkdown,
                mode: viewModel.previewMode, onFailure: viewModel.markdownFailed
            )
        case .image(let data):
            imagePreview(data)
        case .binary:
            Text("repo.files.preview.binary")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooLarge(let byteCount):
            Text(verbatim: String(
                format: String.l10n("repo.files.preview.tooLargeFormat"),
                ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gitLFS(let byteCount):
            Text(verbatim: String(
                format: String.l10n("repo.files.preview.lfsFormat"),
                ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func imagePreview(_ data: Data) -> some View {
        Group {
            if let image = NSImage(data: data), image.isValid {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                Text("repo.files.preview.binary")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 16) {
            if let file = viewModel.previewedFile {
                VStack(spacing: 8) {
                    RepoFileIcon(name: file.name, size: 48)
                    Text(verbatim: file.name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let size = file.size {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 10) {
                    inspectorRow("repo.files.inspector.type", systemImage: "doc.text", value: inspectorType)
                    if let date = commitDate {
                        inspectorRow(
                            "repo.files.inspector.lastUpdated",
                            systemImage: "clock",
                            value: RelativeTimeText.pastEvent(date, locale: locale, unitsStyle: .full)
                        )
                    }
                    if let sha = viewModel.previewCommit?.sha {
                        inspectorRow(
                            "repo.files.inspector.lastCommit",
                            systemImage: "clock.arrow.circlepath",
                            value: String(sha.prefix(7))
                        )
                    }
                    inspectorRow("repo.files.inspector.path", systemImage: "folder", value: "/" + file.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewModel.startDownloadPreviewed()
                } label: {
                    Label("repo.files.inspector.download", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isDownloading || file.blobSHA == nil)
                .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    inspectorLink(
                        title: "repo.files.inspector.copyRawURL",
                        systemImage: "link",
                        copy: viewModel.githubRawURL?.absoluteString
                    )
                    inspectorOpenButton(
                        title: "repo.files.inspector.viewOnGitHub",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        url: viewModel.githubBlobURL
                    )
                    inspectorOpenButton(
                        title: "repo.files.inspector.openInBrowser",
                        systemImage: "arrow.up.right.square",
                        url: viewModel.githubBlobURL
                    )
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                Text("repo.files.preview.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var inspectorType: String {
        switch viewModel.preview {
        case .binary:
            return String.l10n("repo.files.inspector.type.binary")
        case .image:
            return String.l10n("repo.files.inspector.type.image")
        case .gitLFS:
            return String.l10n("repo.files.inspector.type.lfs")
        default:
            return String.l10n("repo.files.inspector.type.text")
        }
    }

    private var commitDate: Date? {
        ISO8601DateFormatter.githubDate(
            from: viewModel.previewCommit?.commit.committer?.date
                ?? viewModel.previewCommit?.commit.author?.date
        )
    }

    private func inspectorRow(_ key: LocalizedStringKey, systemImage: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(key)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func inspectorLink(title: LocalizedStringKey, systemImage: String, copy: String?) -> some View {
        CopyFeedbackButton(providesContent: { copy ?? "" }, tooltip: title) { didCopy in
            inspectorActionLabel(
                title: title,
                systemImage: didCopy ? "checkmark.circle.fill" : systemImage,
                copied: didCopy
            )
        }
        .disabled(copy == nil)
        .frame(maxWidth: .infinity)
    }

    private func inspectorOpenButton(title: LocalizedStringKey, systemImage: String, url: URL?) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            inspectorActionLabel(title: title, systemImage: systemImage, copied: false)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(url == nil)
        .frame(maxWidth: .infinity)
    }

    private func inspectorActionLabel(title: LocalizedStringKey, systemImage: String, copied: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 16)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(verbatim: String(format: String.l10n("repo.files.selectedCountFormat"), viewModel.selectedCount))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.isDownloading {
                if case .downloading(let completed, let total) = viewModel.phase {
                    Text(verbatim: String(format: String.l10n("repo.files.downloadingFormat"), completed, total))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("repo.files.cancelDownload", role: .destructive) {
                    viewModel.cancelDownload()
                }
            } else {
                Button("common.cancel", action: closeWorkspace)
                Button("repo.files.downloadSelected") {
                    viewModel.startDownload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canDownload)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 更新当前快照时不重建阅读器，模式与尺寸变更不会触发文件下载。
    private func publishPreview() {
        presentedPreview = viewModel.preview
        presentedMarkdown = viewModel.markdown
        withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12)) { isContentVisible = true }
    }

    private func closeWorkspace() {
        viewModel.stop()
        if let onClose { onClose() } else { dismiss() }
    }

    private var previewLayoutButtons: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.startDownloadPreviewed()
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("repo.files.inspector.download")
            .accessibilityLabel(Text("repo.files.inspector.download"))
            .disabled(viewModel.isDownloading || viewModel.previewedFile?.blobSHA == nil)
            previewMoreMenu
            if !readingLayout.isExpanded {
                Button {
                    readingLayout.showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(readingLayout.showsInspector ? "repo.files.inspector.hide" : "repo.files.inspector.show")
                .accessibilityLabel(Text(readingLayout.showsInspector ? "repo.files.inspector.hide" : "repo.files.inspector.show"))
                .accessibilityValue(Text(readingLayout.showsInspector ? "repo.skills.content.expanded" : "repo.skills.content.collapsed"))
            }
            Button {
                readingLayout.isExpanded.toggle()
            } label: {
                Image(systemName: readingLayout.isExpanded
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(readingLayout.isExpanded ? "repo.files.preview.restore" : "repo.files.preview.expand")
            .accessibilityLabel(Text(readingLayout.isExpanded ? "repo.files.preview.restore" : "repo.files.preview.expand"))
            .disabled(!readingLayout.isExpanded && viewModel.previewText == nil && viewModel.previewImageData == nil)
        }
    }

    /// 右栏收起或放大时仍能访问当前文件操作；批量勾选状态不会被这些操作改变。
    private var previewMoreMenu: some View {
        Menu {
            if let rawURL = viewModel.githubRawURL {
                CopyFeedbackButton(
                    providesContent: { rawURL.absoluteString },
                    tooltip: "repo.files.inspector.copyRawURL"
                ) { didCopy in
                    Label("repo.files.inspector.copyRawURL",
                          systemImage: didCopy ? "checkmark.circle.fill" : "link")
                }
            }
            if let url = viewModel.githubBlobURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("repo.files.inspector.viewOnGitHub", systemImage: "arrow.up.right.square")
                }
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("repo.files.inspector.openInBrowser", systemImage: "globe")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("repo.files.preview.more")
        .accessibilityLabel(Text("repo.files.preview.more"))
        .disabled(viewModel.githubBlobURL == nil && viewModel.githubRawURL == nil)
    }

    /// 按真正可见的树顺序分配条纹；折叠与筛选后索引重新连续，不改原树数据。
    private var visibleTreeRows: [(node: RepoFileNode, depth: Int)] {
        func flatten(_ nodes: [RepoFileNode], depth: Int) -> [(node: RepoFileNode, depth: Int)] {
            nodes.flatMap { node in
                [(node: node, depth: depth)] + (
                    node.isDirectory && (viewModel.isSearchActive || expandedPaths.contains(node.path))
                        ? flatten(node.children ?? [], depth: depth + 1) : []
                )
            }
        }
        return flatten(viewModel.displayedNodes, depth: 0)
    }

    private var treeSkeleton: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<10) { index in
                    HStack(spacing: 8) {
                        SkeletonBlock(width: 14, height: 14, phase: phase, palette: palette)
                        SkeletonBlock(width: index.isMultiple(of: 2) ? 150 : 110, height: 12,
                                      phase: phase, palette: palette)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 单个树节点。checkbox 与展开是两个独立 Button，满足整行折叠规范。
private struct RepoFileTreeRow: View {
    let node: RepoFileNode
    var viewModel: RepoFileBrowserViewModel
    @Binding var isExpanded: Bool
    let rowIndex: Int
    let depth: Int
    let selectionNamespace: Namespace.ID
    @State private var isHovered = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                checkboxButton
                if node.isDirectory {
                    expandButton
                } else {
                    fileLabel
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background {
                if viewModel.previewedPath == node.path {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.3)))
                        .matchedGeometryEffect(id: "file-selection", in: selectionNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHovered ? 0.07 : (rowIndex.isMultiple(of: 2) ? 0 : 0.025)))
                }
            }
            .onHover { hovered in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovered = hovered }
            }
        }
    }

    private var showsChildren: Bool { isExpanded }

    private var checkboxButton: some View {
        let state = RepoFileTreeBuilder.checkState(of: node, selected: viewModel.selectedPaths)
        let hasFiles = !RepoFileTreeBuilder.descendantFilePaths(of: node).isEmpty
        return Button {
            viewModel.toggle(node)
        } label: {
            Image(systemName: checkboxSymbol(state))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hasFiles ? Color.primary : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!hasFiles || viewModel.isDownloading)
        .accessibilityLabel(Text(node.isDirectory ? "repo.files.folder" : "repo.files.file"))
    }

    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showsChildren ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var fileLabel: some View {
        Button {
            viewModel.reveal(node)
        } label: {
            HStack(spacing: 6) {
                RepoFileIcon(name: node.name)
                Text(verbatim: node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func checkboxSymbol(_ state: RepoFileCheckState) -> String {
        switch state {
        case .off: return "square"
        case .mixed: return "minus.square.fill"
        case .on: return "checkmark.square.fill"
        }
    }
}

private struct RepoFileBranchPicker: View {
    let branches: [String]
    let selection: String
    let isDisabled: Bool
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var query = ""

    private var filtered: [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(verbatim: selection).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                TextField("repo.files.branch.searchPlaceholder", text: $query)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element) { index, name in
                            Button {
                                onSelect(name)
                                isPresented = false
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark")
                                        .opacity(name == selection ? 1 : 0)
                                        .frame(width: 14)
                                    Text(verbatim: name).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .listRowSurface(index: index, isSelected: name == selection)
                        }
                    }
                }
                .frame(width: 260, height: 220)
            }
            .padding(10)
            .appLocaleEnvironment()
        }
    }
}

private extension View {
    /// 原型三栏都是抬起的圆角面板。浅色用 textBackground 白卡叠窗口灰底；深色同色时靠描边分区。
    func fileBrowserCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
