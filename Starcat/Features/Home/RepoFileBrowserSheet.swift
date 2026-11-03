//
//  RepoFileBrowserSheet.swift
//  Starcat
//
//  详情页「下载文件」Sheet：按原型做成顶栏身份 + 三张抬起卡片（左树 / 中预览 / 右详情）。
//
//  必须由 `RepoListView` 根节点 `.sheet(item:)` 呈现，不能挂在 toolbar 菜单子树上。
//  左栏 checkbox 与展开是两个独立 Button；点文件名只拉预览，不改勾选。
//  原型没有 checkbox，但批量下载需要勾选，所以树行左侧保留。
//  Sheet 规范仍要求右上角 `SheetCloseButton`；原型窗口红绿灯在 AppKit chrome 上，这里补关闭钮。
//  打开时只展示文件树；点文件后左树收窄，预览 + 详情从右侧滑入。
//  切分支会清空预览，三栏收回，避免对着旧文件发呆。
//

import SwiftUI
import AppKit

struct RepoFileBrowserSheetItem: Identifiable {
    let id = UUID()
    let target: RepoFileBrowserTarget
}

struct RepoFileBrowserSheet: View {
    let target: RepoFileBrowserTarget
    let apiClient: any GitHubAPIClientProtocol

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var viewModel: RepoFileBrowserViewModel
    @FocusState private var searchFocused: Bool

    init(target: RepoFileBrowserTarget, apiClient: any GitHubAPIClientProtocol) {
        self.target = target
        self.apiClient = apiClient
        _viewModel = State(initialValue: RepoFileBrowserViewModel(target: target, apiClient: apiClient))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            header
            columns
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 1020, height: 660)
        .task {
            await viewModel.loadTree()
            await viewModel.loadBranches()
        }
        .onDisappear {
            viewModel.stop()
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
        HStack(alignment: .center, spacing: 12) {
            // 顶栏身份用仓库 owner 头像；来源缺字段时兜底 `github.com/{owner}.png`
            // （GitHub 官方头像端点，RemoteAvatar 已按域名注入 size 参数并走 Kingfisher 缓存）。
            RemoteAvatar(
                urlString: target.ownerAvatar ?? "https://github.com/\(target.owner).png",
                size: 28,
                showBorder: false
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(verbatim: target.fullName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(target.isPrivate ? "repo.files.visibility.private" : "repo.files.visibility.public")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if let summary = target.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
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
            SheetCloseButton(action: { dismiss() })
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// 点过文件才展开预览栏。打开页、切分支清空预览后都只留文件树。
    private var isPreviewPresented: Bool {
        viewModel.previewedPath != nil
    }

    /// 未选文件时树占满内容区；选中后树收到 240，预览+详情从右侧滑入。
    /// 动画跟 RAG / Agent 收起 Inspector 同一档：短 easeInOut，减少动态效果时直接切。
    private var columns: some View {
        HStack(spacing: 12) {
            sidebar
                .frame(minWidth: 240)
                .frame(maxWidth: isPreviewPresented ? 240 : .infinity)
                .frame(maxHeight: .infinity)
                .fileBrowserCard()

            if isPreviewPresented {
                HStack(spacing: 12) {
                    previewColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .fileBrowserCard()
                    inspector
                        .frame(width: 260)
                        .fileBrowserCard()
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isPreviewPresented)
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
            ProgressView("repo.files.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            ForEach(viewModel.displayedNodes) { node in
                                RepoFileTreeRow(
                                    node: node,
                                    viewModel: viewModel,
                                    forceExpanded: viewModel.isSearchActive
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            BusinessIcon(source: previewedFileIcon, pointSize: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: viewModel.previewedFile?.name ?? "")
                    .font(.headline)
                Text(verbatim: previewMetaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            if let rawURL = viewModel.githubRawURL {
                Button("repo.files.preview.raw") {
                    NSWorkspace.shared.open(rawURL)
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
            }
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
        switch viewModel.preview {
        case .idle:
            Text("repo.files.preview.empty")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView("repo.files.preview.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let content):
            codeView(content)
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

    private func codeView(_ content: String) -> some View {
        RepoFileSourcePreview(text: content)
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
                    BusinessIcon(source: previewedFileIcon, pointSize: 48)
                        .foregroundStyle(.secondary)
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

    /// 预览 header 与右侧详情大图标共用：按文件名取类型图标，未选中时退回默认文档。
    private var previewedFileIcon: BusinessIcon.Source {
        guard let file = viewModel.previewedFile else { return .business(.file) }
        return RepoFileTypeIcon.iconSource(forFileName: file.name)
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
                Button("common.cancel") { dismiss() }
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
}

/// 单个树节点。checkbox 与展开是两个独立 Button，满足整行折叠规范。
private struct RepoFileTreeRow: View {
    let node: RepoFileNode
    var viewModel: RepoFileBrowserViewModel
    var forceExpanded: Bool
    @State private var isExpanded = false

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
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(
                viewModel.previewedPath == node.path
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )

            if node.isDirectory, showsChildren, let children = node.children, !children.isEmpty {
                ForEach(children) { child in
                    RepoFileTreeRow(node: child, viewModel: viewModel, forceExpanded: forceExpanded)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private var showsChildren: Bool { forceExpanded || isExpanded }

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
                BusinessIcon(source: RepoFileTypeIcon.iconSource(forFileName: node.name), pointSize: 15)
                    .foregroundStyle(.secondary)
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
                        ForEach(filtered, id: \.self) { name in
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
