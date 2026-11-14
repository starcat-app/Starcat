//
//  RepoSkillDetailPane.swift
//  Starcat
//
//  中栏展示固定提交中的 Markdown、完整文件清单与可折叠目录。
//

import SwiftUI

/// 阅读区独立滚动，切换 Skill 只重置阅读位置，不影响安装选择或右侧队列。
struct RepoSkillDetailPane: View {
    let skill: RepoSkill
    let session: RepoSkillSession
    @Binding var isPreviewExpanded: Bool
    @Binding var isInspectorPresented: Bool

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var tab = Tab.manifest
    @State private var expandedFolders: Set<String> = ["references", "templates", "assets", "scripts"]
    @State private var previewedFile: RepoSkillFile?
    @State private var document: RepoSkillReadingCache.Document?
    @State private var renderedDocumentID: String?
    @State private var presentedSkill: RepoSkill?
    @State private var isContentVisible = false
    @State private var isSkeletonVisible = true

    private var contentAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.06 : 0.12)
    }

    private var isContentReady: Bool {
        document?.skillID == skill.id && (tab != .manifest || renderedDocumentID == skill.id)
    }

    /// 文件清单与正文保留同一份展示快照，避免旧页尚未退场时先换成新 Skill 的附件。
    private var contentSkill: RepoSkill { presentedSkill ?? skill }

    private enum Tab: CaseIterable {
        case manifest, files, tree

        var title: LocalizedStringKey {
            switch self {
            case .manifest: "SKILL.md"
            case .files: "repo.files.tab.files"
            case .tree: "repo.skills.content.tree"
            }
        }

        var symbol: String {
            switch self {
            case .manifest: "doc.text"
            case .files: "doc.on.doc"
            case .tree: "folder"
            }
        }

        var tint: Color {
            switch self {
            case .manifest: .blue
            case .files: .orange
            case .tree: .purple
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isPreviewExpanded {
                    Text(verbatim: "SKILL.md")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                } else {
                    CountedSegmentedControl(
                        items: Tab.allCases, selection: $tab, totalCount: skill.files.count,
                        title: { $0.title },
                        count: { $0 == .files ? skill.files.count : nil },
                        accessibilityLabel: "repo.skills.preview.selection",
                        symbol: { $0.symbol },
                        tint: { $0.tint }
                    )
                }
                Spacer(minLength: 0)
                if tab == .manifest {
                    previewSizeButton
                }
            }
            // 放大按钮固定在这行，不因切换到文件或目录而让正文上下跳动。
            .frame(minHeight: 28)

            Group {
                if tab == .manifest {
                    manifest
                } else if document == nil {
                    Color.clear
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            switch tab {
                            case .manifest: EmptyView()
                            case .files: fileList
                            case .tree: fileTree
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                    .id("\(contentSkill.id)-\(tab)")
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: reduceMotion || isContentVisible ? 0 : 10)
            .opacity(isContentVisible ? 1 : 0)
            .clipped()
            .allowsHitTesting(isContentReady && isContentVisible)
            .accessibilityHidden(!isContentReady || !isContentVisible)
            .overlay {
                if isSkeletonVisible {
                    RepoSkillSkeletonView(layout: skeletonLayout)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                downloadButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 14)
            }
            .background(RepoSkillPanelStyle.panelColor(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .popover(item: $previewedFile) { file in
            RepoSkillFilePreview(skill: contentSkill, file: file, session: session) { previewedFile = nil }
                .appLocaleEnvironment()
        }
        .onChange(of: skill.id) { _, _ in previewedFile = nil }
        .onChange(of: tab) { _, _ in
            renderedDocumentID = nil
            updateContentVisibility()
        }
        .task(id: skill.id) {
            do {
                try Task.checkCancellation()
                let requestedSkill = skill
                let readingCache = session.readingCache
                let imageBaseURL = contentBaseURL(raw: true)
                let baseURL = contentBaseURL(raw: false)
                // 缓存准备与退场并行；等动画完成才更新 HTML，防止复用的 WebView 提前换掉旧 DOM。
                async let preparation = readingCache.prepare(
                    requestedSkill, imageBaseURL: imageBaseURL, contentBaseURL: baseURL
                )
                await fadeOutContent()
                try Task.checkCancellation()
                // 旧页退场完成才让骨架入场；缓存已就绪时不强制插入等待或最短展示时间。
                withAnimation(contentAnimation) {
                    isSkeletonVisible = !isContentReady
                }
                let prepared = try await preparation
                try Task.checkCancellation()
                // 实际换文档才清除就绪身份；快速切回仍在 WebView 中的缓存页不会再触发导航完成。
                if document?.skillID != prepared.skillID {
                    renderedDocumentID = nil
                }
                presentedSkill = requestedSkill
                document = prepared
                // 文件和目录已就绪；Markdown 继续等待当前文档的 WebKit 回调。
                updateContentVisibility()
            } catch {
                // 快速点选会取消旧任务；旧正文不能在新标题下回填。
            }
        }
    }

    /// 占位布局跟随当前 Tab，文件与目录不会在等待期间显示成正文段落。
    private var skeletonLayout: RepoSkillSkeletonView.Layout {
        switch tab {
        case .manifest: .manifest
        case .files: .files
        case .tree: .tree
        }
    }

    /// 骨架和内容共用一次淡化事务；正文仍须等当前 WebView 的就绪回调，不能以 HTML 准备完成代替。
    private func updateContentVisibility() {
        withAnimation(contentAnimation) {
            isContentVisible = isContentReady
            isSkeletonVisible = !isContentReady
        }
    }

    /// 使用动画完成回调安排换页，不猜测渲染时间；读取任务恢复后仍需检查取消，防止旧页回填。
    private func fadeOutContent() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(contentAnimation, completionCriteria: .removed) {
                isContentVisible = false
            } completion: {
                continuation.resume()
            }
        }
    }

    /// 入口位于正文外，避让 WebView 滚动条；切换尺寸不会改变正文身份或触发读取任务。
    private var previewSizeButton: some View {
        let helpKey: LocalizedStringKey = isPreviewExpanded
            ? "repo.skills.preview.restoreLayout" : "repo.skills.preview.expand"
        return Button {
            isPreviewExpanded.toggle()
        } label: {
            Image(systemName: isPreviewExpanded
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpKey)
        .accessibilityLabel(Text(helpKey))
    }

    /// 下载入口常驻三个内容 Tab；这里只切换浮层，实际写入仍需用户确认开始安装。
    private var downloadButton: some View {
        Button {
            isInspectorPresented.toggle()
        } label: {
            Label("repo.files.inspector.download", systemImage: "arrow.down.to.line")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .starcatInteractiveGlassSurface(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isInspectorPresented ? 0.5 : 0.2))
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("repo.files.inspector.download")
        .accessibilityValue(Text(LocalizedStringKey(
            isInspectorPresented ? "repo.skills.content.expanded" : "repo.skills.content.collapsed"
        )))
        .shadow(color: .black.opacity(0.09), radius: 8, x: 0, y: 4)
    }

    /// 只渲染仓库原文，不生成示例命令，也不执行 Markdown 中的安装指令。
    @ViewBuilder
    private var manifest: some View {
        if let document {
            ReadmeWebView(
                htmlFragment: document.html, documentID: document.skillID, baseURL: document.baseURL,
                floatingToolbarBottomInset: 40,
                onDocumentReady: revealManifest
            )
            // 由外层统一淡化，保持 WKWebView 身份稳定，不能用 Skill 的 .id 重建阅读器。
        } else {
            Color.clear
        }
    }

    /// 只让当前 Skill 的已加载正文淡入；快速切换后到达的旧文档回调不能显示过期内容。
    private func revealManifest(_ documentID: String) {
        guard documentID == skill.id, document?.skillID == documentID else { return }
        renderedDocumentID = documentID
        updateContentVisibility()
    }

    /// 相对链接指向扫描时的提交与目录，分支后续更新不会改变预览中的附件版本。
    private func contentBaseURL(raw: Bool) -> URL? {
        let host = raw ? "https://raw.githubusercontent.com" : "https://github.com"
        guard var url = URL(string: host) else { return nil }
        url.appendPathComponent(session.repo.owner)
        url.appendPathComponent(session.repo.name)
        if !raw { url.appendPathComponent("blob") }
        url.appendPathComponent(skill.commitSHA)
        for component in skill.directory.split(separator: "/") { url.appendPathComponent(String(component)) }
        return url.appendingPathComponent("", isDirectory: true)
    }

    private var fileList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(contentSkill.files) { file in
                Button {
                    previewedFile = file
                } label: {
                    HStack(spacing: 10) {
                    Image(systemName: file.path == "SKILL.md" ? "doc.text" : "doc")
                        .foregroundStyle(.secondary)
                    Text(verbatim: file.path)
                        .font(interfaceScale.font(.code))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(file.sizeKB) KB")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(file.path)
                .padding(.vertical, 10)
                Divider()
            }
            Label("repo.skills.content.complete", systemImage: "shippingbox")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
    }

    /// 标题整行是折叠触发区，目录只表达完整复制范围，不支持把 Skill 拆散安装。
    private var fileTree: some View {
        return LazyVStack(alignment: .leading, spacing: 10) {
            Label(contentSkill.directory.isEmpty ? "/" : contentSkill.directory, systemImage: "folder")
                .font(interfaceScale.font(.code, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(document?.rootFiles ?? []) { file in
                treeFile(file)
                    .padding(.leading, 20)
            }
            ForEach(document?.folders ?? []) { group in
                let folder = group.id
                LazyVStack(alignment: .leading, spacing: 10) {
                    Button {
                        if expandedFolders.contains(folder) {
                            expandedFolders.remove(folder)
                        } else {
                            expandedFolders.insert(folder)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: expandedFolders.contains(folder) ? "chevron.down" : "chevron.right")
                                .font(interfaceScale.font(.captionSmall))
                                .frame(width: 10)
                            Label(folder, systemImage: "folder")
                                .font(interfaceScale.font(.code))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityValue(Text(LocalizedStringKey(
                        expandedFolders.contains(folder) ? "repo.skills.content.expanded" : "repo.skills.content.collapsed"
                    )))
                    if expandedFolders.contains(folder) {
                        ForEach(group.files) { file in
                            treeFile(file)
                                .padding(.leading, 36)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    private func treeFile(_ file: RepoSkillFile) -> some View {
        Button {
            previewedFile = file
        } label: {
            Label(file.path, systemImage: "doc.text")
                .font(interfaceScale.font(.code))
                .lineLimit(1)
                .help(file.path)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
