//
//  RepoSkillSheet.swift
//  Starcat
//
//  真实 Skill 阅读与浮动安装工作区，窗口尺寸由 AppKit 持有，内容只消费共享会话。
//

import SwiftUI

/// 窗口持有固定画布；安装配置按需覆盖阅读区，主操作根据批次阶段切换。
struct RepoSkillSheet: View {
    let session: RepoSkillSession
    let onClose: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AppDependencies.self) private var dependencies
    @State private var previewID = ""
    @State private var isPreviewExpanded = false
    @State private var isInspectorPresented = false

    private var preview: RepoSkill? {
        session.skills.first { $0.id == previewID } ?? session.skills.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if !isPreviewExpanded {
                        RepoSkillSelectionPane(session: session, previewID: $previewID)
                            .frame(width: min(280, geometry.size.width * 0.25))
                        Divider()
                    }
                    // 阅读器始终留在同一个结构位置；安装面板不参与分栏，避免正文随开关重新排版。
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = session.error {
                            Text(verbatim: error).foregroundStyle(.secondary).padding(16)
                        }
                        if session.isLoading && preview == nil {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let preview {
                            if let issue = preview.installationIssue {
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .font(interfaceScale.font(.caption)).padding(.horizontal, 18)
                            }
                            RepoSkillDetailPane(
                                skill: preview, session: session, isPreviewExpanded: $isPreviewExpanded,
                                isInspectorPresented: $isInspectorPresented
                            )
                        } else {
                            ContentUnavailableView(
                                "repo.skills.list.empty", systemImage: "shippingbox",
                                description: Text(session.scan?.complete == true ? "repo.skills.scan.absent" : "repo.skills.scan.incomplete")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .topTrailing) {
                    if isInspectorPresented {
                        installationPanel
                            .frame(width: min(420, geometry.size.width * 0.5))
                            // 顶部避开内容 Tab，底部留出字号、回顶与下载按钮的完整点击区。
                            .padding(.top, 44)
                            .padding(.trailing, 26)
                            .padding(.bottom, 142)
                    }
                }
            }
            if !isPreviewExpanded {
                Divider()
                footer
            }
        }
        .foregroundStyle(.primary)
        // macOS 新版 regular/large 按钮可能默认采用胶囊，任务窗口明确遵循 6pt 矩形圆角。
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await session.load() }
        .onDisappear { session.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await session.refreshDestination() }
        }
        .onChange(of: session.skills.map(\.id)) { _, ids in
            if !ids.contains(previewID) { previewID = ids.first ?? "" }
            if ids.isEmpty { isPreviewExpanded = false }
        }
        .onExitCommand {
            if isInspectorPresented {
                isInspectorPresented = false
            } else if isPreviewExpanded {
                isPreviewExpanded = false
            } else {
                onClose()
            }
        }
        .onChange(of: dependencies.databaseScopeRevision) { _, _ in
            session.close()
            onClose()
        }
    }

    /// 浮层只持有展示状态；目录选择、冲突与进度仍由窗口会话持有，收起不会取消安装。
    private var installationPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("repo.files.inspector.download", systemImage: "arrow.down.to.line")
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                Spacer(minLength: 8)
                SheetCloseButton { isInspectorPresented = false }
            }
            .padding(12)
            Divider()
            RepoSkillInspector(session: session)
            // 放大阅读时窗口底栏隐藏，操作随浮层显示，仍可直接确认安装。
            if isPreviewExpanded {
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: session.repo.owner), size: 28, showBorder: false)
                .accessibilityHidden(true)
            Text(verbatim: session.repo.fullName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(session.repo.fullName)
            Spacer(minLength: 12)
            RepoSkillScanNotice(session: session)
            if let progress = session.scanProgressText {
                Text(verbatim: progress)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(Text(verbatim: progress))
            }
            SyncIconButton(isRefreshing: session.isLoading, disabled: session.isInstalling,
                           tooltip: String.l10n("repo.skills.scan.refresh")) {
                Task { await session.load(force: true) }
            }
            SheetCloseButton(action: onClose)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(footerText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: session.phase == .finished && !session.hasFailures ? "checkmark.circle" : "info.circle")
                        .help("repo.skills.install.safety")
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                if session.phase == .finished || session.phase == .cancelled {
                    Text(LocalizedStringKey(session.isExport ? "repo.skills.install.exportNotice" : "repo.skills.install.reload"))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(LocalizedStringKey(session.isInstalling ? "common.close" : "common.cancel"), action: onClose)
                .buttonStyle(.bordered)
                .keyboardShortcut(isInspectorPresented ? nil : .cancelAction)

            Button(action: primaryAction) {
                Text(LocalizedStringKey(primaryKey))
                    .frame(minWidth: 84)
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(primaryDisabled)
        }
        .controlSize(.regular)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footerText: String {
        let items = session.displayedQueue
        let selected = Set(items.map { $0.skill.id })
        let directories = Set(items.map { $0.destination.id })
        if session.hasDuplicateNames { return String.l10n("repo.skills.selection.duplicate") }
        if session.scan?.complete == false { return String.l10n("repo.skills.scan.incomplete") }
        return String(format: String.l10n("repo.skills.install.multiSummary"),
                      selected.count, directories.count, items.reduce(0) { $0 + $1.skill.sizeKB })
    }

    private var primaryKey: String {
        if session.isInstalling { return "repo.skills.install.cancel" }
        if !session.conflicts.isEmpty { return "repo.skills.install.resolve" }
        if session.phase == .finished {
            return session.hasFailures ? "repo.skills.install.retry" : "repo.skills.install.done"
        }
        if session.isExport { return "repo.skills.install.export" }
        return session.phase == .cancelled ? "repo.skills.install.resume" : "repo.skills.install.start"
    }

    private var primaryDisabled: Bool {
        if session.isInstalling || (session.phase == .finished && !session.hasFailures) { return false }
        return !session.canStart
    }

    /// 主按钮按阶段分派，不能在正在运行或存在冲突时再创建一个安装批次。
    private func primaryAction() {
        if session.isInstalling {
            session.cancel()
        } else if session.phase == .finished && !session.hasFailures {
            onClose()
        } else {
            isInspectorPresented = true
            session.start()
        }
    }
}
