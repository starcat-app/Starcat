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
    @State private var tab = Tab.manifest
    @State private var expandedFolders: Set<String> = ["references", "templates", "assets", "scripts"]
    @State private var previewedFile: RepoSkillFile?
    @State private var document: RepoSkillReadingCache.Document?

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
                } else if document?.skillID != skill.id {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .id("\(skill.id)-\(tab)")
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
            RepoSkillFilePreview(skill: skill, file: file, session: session) { previewedFile = nil }
                .appLocaleEnvironment()
        }
        .onChange(of: skill.id) { _, _ in previewedFile = nil }
        .task(id: skill.id) {
            do {
                let prepared = try await session.readingCache.prepare(
                    skill, imageBaseURL: contentBaseURL(raw: true), contentBaseURL: contentBaseURL(raw: false)
                )
                try Task.checkCancellation()
                document = prepared
            } catch {
                // 快速点选会取消旧任务；旧正文不能在新标题下回填。
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
                floatingToolbarBottomInset: 40
            )
            // 保持渲染器身份稳定；准备新文档时隐藏旧内容，不能销毁并重建 WKWebView。
            .opacity(document.skillID == skill.id ? 1 : 0)
            .allowsHitTesting(document.skillID == skill.id)
            .overlay {
                if document.skillID != skill.id { ProgressView() }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            ForEach(skill.files) { file in
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
            Label(skill.directory.isEmpty ? "/" : skill.directory, systemImage: "folder")
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
