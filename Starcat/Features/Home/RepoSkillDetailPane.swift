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
    @Environment(\.locale) private var locale
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @State private var tab = Tab.manifest
    @State private var expandedFolders: Set<String> = ["references", "templates", "assets", "scripts"]
    @State private var previewedFile: RepoSkillFile?
    @State private var document: RepoSkillReadingCache.Document?
    @State private var renderedDocumentID: String?
    @State private var translationVM: ReadmeTranslationViewModel
    @State private var translationSourceDocumentID: String?
    @State private var translationSourceSnapshot: ReadmeTranslationSourceSnapshot = .empty
    @State private var translationToast: String?
    @State private var translationNoticeToast: String?

    /// 只共享翻译服务与设置；窗口拥有自己的 VM，翻译 Skill 不会打断主窗口的 README。
    init(
        skill: RepoSkill, session: RepoSkillSession,
        translationService: any ReadmeTranslationServiceProtocol,
        isPreviewExpanded: Binding<Bool>, isInspectorPresented: Binding<Bool>
    ) {
        self.skill = skill
        self.session = session
        _isPreviewExpanded = isPreviewExpanded
        _isInspectorPresented = isInspectorPresented
        _translationVM = State(initialValue: ReadmeTranslationViewModel(service: translationService))
    }

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
                    ReadmeTranslationFooterButton(
                        control: translationControl,
                        sourceHtml: document?.skillID == skill.id ? document?.html ?? "" : "",
                        sourceSnapshot: translationSourceDocumentID == skill.id && renderedDocumentID == skill.id
                            ? translationSourceSnapshot : .empty
                    )
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
            RepoSkillFilePreview(skill: skill, file: file, session: session) { previewedFile = nil }
                .appLocaleEnvironment()
        }
        .sheet(item: translationPaywallBinding) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .toast(
            message: $translationToast, icon: "exclamationmark.triangle.fill",
            duration: 5, iconColor: .orange, bottomPadding: 30,
            actionLabel: translationVM.translationErrorKind == .aiConfiguration
                ? "readme.translate.error.goToAISettings" : nil,
            onAction: translationToastOnAction
        )
        .toast(
            message: $translationNoticeToast, icon: "checkmark.circle.fill",
            duration: 5, bottomPadding: 30
        )
        .onChange(of: translationVM.errorMessage) { _, message in
            translationToast = message
        }
        .onChange(of: translationToast) { _, message in
            if message == nil { translationVM.dismissError() }
        }
        .onChange(of: translationVM.showsAlreadyInTargetNotice) { _, shown in
            if shown { translationNoticeToast = "readme.translate.notice.alreadyInTarget" }
        }
        .onChange(of: translationNoticeToast) { _, message in
            if message == nil { translationVM.dismissAlreadyInTargetNotice() }
        }
        .onChange(of: skill.id) { _, _ in
            previewedFile = nil
            translationSourceDocumentID = nil
            translationSourceSnapshot = .empty
        }
        .onChange(of: tab) { _, _ in renderedDocumentID = nil }
        .onChange(of: translationSyncKey, initial: true) { _, _ in prepareTranslation() }
        .onDisappear {
            // prepare(nil) 同时取消缓存读取和翻译任务，关窗后不能再发布部分译文或付费提示。
            translationVM.prepare(
                repo: nil, sourceHtml: nil,
                targetLanguage: settings.effectiveReadmeTranslationLanguage,
                mode: settings.readmeTranslationMode, engine: settings.readmeTranslationEngine
            )
        }
        .task(id: skill.id) {
            do {
                let prepared = try await session.readingCache.prepare(
                    skill, imageBaseURL: contentBaseURL(raw: true), contentBaseURL: contentBaseURL(raw: false)
                )
                try Task.checkCancellation()
                // 实际换文档才清除就绪身份；快速切回仍在 WebView 中的缓存页不会再触发导航完成。
                if document?.skillID != prepared.skillID {
                    renderedDocumentID = nil
                }
                // 文件和目录准备后直接淡入；Markdown 仍等待 WebKit 完成本次导航，避免淡入旧 DOM。
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    document = prepared
                }
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

    /// 原始 DOM 保持稳定，翻译只更新阅读层；扫描与安装始终使用仓库原文件。
    @ViewBuilder
    private var manifest: some View {
        if let document {
            let isReady = document.skillID == skill.id && renderedDocumentID == skill.id
            ReadmeWebView(
                htmlFragment: document.html, documentID: document.skillID, baseURL: document.baseURL,
                floatingToolbarBottomInset: 40,
                translationRenderState: document.skillID == skill.id
                    ? translationVM.visibleRenderState(matching: translationControl.identity) : .hidden,
                onTranslationSourceChange: { snapshot in
                    receiveTranslationSource(snapshot, documentID: document.skillID)
                },
                onDocumentReady: revealManifest
            )
            // 保持渲染器身份稳定；准备新文档时隐藏旧内容，不能销毁并重建 WKWebView。
            .opacity(isReady ? 1 : 0)
            .allowsHitTesting(isReady)
            .overlay {
                if !isReady { ProgressView() }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var translationControl: ReadmeTranslationControl {
        ReadmeTranslationControl(
            repo: session.repo, translationVM: translationVM, settings: settings,
            documentPath: skill.manifestPath
        )
    }

    /// 仅比较轻量身份；字号、放大状态与翻译进度不能触发整份正文重新准备。
    private var translationSyncKey: String {
        // 自动语言从偏好解析，额外观察环境 locale，才能在应用切换语言后重绑缓存。
        let automaticLocale = settings.readmeTranslationLanguage == .auto ? locale.identifier : ""
        return "\(skill.id)|\(document?.skillID ?? "")|\(settings.effectiveReadmeTranslationLanguage.rawValue)"
            + "|\(settings.readmeTranslationMode.rawValue)|\(settings.readmeTranslationEngine.rawValue)"
            + "|\(automaticLocale)"
    }

    /// 真实正文到达、Skill 或翻译设置改变时重新绑定；不拿上一份 HTML 查询新 Skill 的缓存。
    private func prepareTranslation() {
        translationToast = nil
        translationNoticeToast = nil
        translationVM.dismissPaywall()
        let control = translationControl
        translationVM.prepare(
            identity: control.identity, cacheOwner: control.cacheOwner, cacheRepo: control.cacheRepo,
            sourceHtml: document?.skillID == skill.id ? document?.html : nil,
            targetLanguage: settings.effectiveReadmeTranslationLanguage,
            mode: settings.readmeTranslationMode, engine: settings.readmeTranslationEngine
        )
    }

    /// DOM 提取结果必须属于当前已准备文档，迟到回调不能让新标题使用旧 Skill 的翻译输入。
    private func receiveTranslationSource(_ snapshot: ReadmeTranslationSourceSnapshot, documentID: String) {
        guard documentID == skill.id, document?.skillID == documentID else { return }
        translationSourceDocumentID = documentID
        translationSourceSnapshot = snapshot
    }

    private var translationToastOnAction: (() -> Void)? {
        guard translationVM.translationErrorKind == .aiConfiguration else { return nil }
        return { AppDelegate.openSettingsWindow(target: "ai") }
    }

    private var translationPaywallBinding: Binding<ProPaywallContext?> {
        Binding(
            get: { translationVM.paywallContext },
            set: { if $0 == nil { translationVM.dismissPaywall() } }
        )
    }

    /// 只让当前 Skill 的已加载正文淡入；快速切换后到达的旧文档回调不能显示过期内容。
    private func revealManifest(_ documentID: String) {
        guard documentID == skill.id, document?.skillID == documentID else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            renderedDocumentID = documentID
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
