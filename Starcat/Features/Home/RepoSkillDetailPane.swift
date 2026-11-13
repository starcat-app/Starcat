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

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab = Tab.manifest
    @State private var expandedFolders: Set<String> = ["references", "templates", "assets", "scripts"]
    @State private var previewedFile: RepoSkillFile?
    @State private var document: RepoSkillReadingCache.Document?

    private enum Tab: CaseIterable { case manifest, files, tree }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 3) {
                tabButton(.manifest, title: "SKILL.md", symbol: "doc.text")
                tabButton(
                    .files,
                    title: String.l10n("repo.files.tab.files") + " (\(skill.files.count))",
                    symbol: "doc.on.doc"
                )
                tabButton(.tree, title: String.l10n("repo.skills.content.tree"), symbol: "folder")
            }
            .padding(4)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))

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
            .background(RepoSkillPanelStyle.panelColor(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.09))
            }
        }
        .padding(16)
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

    private func tabButton(_ value: Tab, title: String, symbol: String) -> some View {
        Button {
            tab = value
        } label: {
            Label(title, systemImage: symbol)
                .font(interfaceScale.font(.caption, weight: tab == value ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
                .foregroundStyle(tab == value ? .primary : .secondary)
                .background(
                    tab == value ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(title)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    /// 只渲染仓库原文，不生成示例命令，也不执行 Markdown 中的安装指令。
    @ViewBuilder
    private var manifest: some View {
        if let document {
            ReadmeWebView(
                htmlFragment: document.html, documentID: document.skillID, baseURL: document.baseURL
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
