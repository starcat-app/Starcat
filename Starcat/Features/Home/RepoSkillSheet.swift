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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.openWindow) private var openWindow
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
                        if preview == nil, session.isLoading || (session.scan == nil && session.error == nil) {
                            RepoSkillSkeletonView(layout: .manifest)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .background(RepoSkillPanelStyle.panelColor(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.09))
                                }
                                // 预留与详情工具栏一致的高度，首个 Skill 到达时正文起点保持稳定。
                                .padding(.top, 44)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        } else if let preview {
                            if let issue = preview.installationIssue {
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .font(interfaceScale.font(.caption)).padding(.horizontal, 18)
                            }
                            RepoSkillDetailPane(
                                skill: preview, session: session,
                                translationService: dependencies.readmeTranslationService,
                                isPreviewExpanded: $isPreviewExpanded,
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
                .overlay(alignment: .trailing) {
                    if isInspectorPresented {
                        installationPanel
                            // 浮层覆盖内容区全高，包含阅读工具栏，不改变正文或底栏的可用尺寸。
                            .frame(width: min(420, geometry.size.width * 0.5), height: geometry.size.height)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .clipped()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isInspectorPresented)
            }
            if !isPreviewExpanded {
                Divider()
                footer
            }
        }
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await session.load() }
        .onChange(of: preview?.id, initial: true) { _, id in session.focusSkill(id) }
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
        .overlay(alignment: .leading) {
            Divider()
        }
    }

    private var header: some View {
        RepoWorkspaceHeader(target: RepoFileBrowserTarget(repo: session.repo)) {
            if DistributionChannel.current.isDirect, let preview {
                Button("skills.import.addToLibrary") {
                    try? SkillWorkspaceSceneCoordinator.shared.openRepositoryImport(.init(repo: session.repo, skill: preview)) { sceneID in
                        openWindow(id: sceneID)
                    }
                }
                .disabled(session.isInstalling || preview.installationIssue != nil)
                .controlSize(.small)
            }
            RepoSkillScanNotice(session: session)
            if let progress = session.scanProgressText {
                Text(verbatim: progress)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                    .accessibilityLabel(Text(verbatim: progress))
            }
            SyncIconButton(isRefreshing: session.isLoading, disabled: session.isInstalling,
                           tooltip: String.l10n("repo.skills.scan.refresh")) {
                Task { await session.load(force: true) }
            }
            SheetCloseButton(action: onClose)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label {
                Text(verbatim: footerText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(footerText)
            } icon: {
                Image(systemName: footerStatus.symbol)
                    .foregroundStyle(footerStatus.color)
                    .help("repo.skills.install.safety")
                    .accessibilityHidden(true)
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(LocalizedStringKey(session.isInstalling ? "common.close" : "common.cancel"), action: onClose)
                .lineLimit(1)
                .help(LocalizedStringKey(session.isInstalling ? "common.close" : "common.cancel"))
                .keyboardShortcut(isInspectorPresented ? nil : .cancelAction)

            Button(LocalizedStringKey(primaryKey), action: primaryAction)
                .lineLimit(1)
                .help(LocalizedStringKey(primaryKey))
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
        .buttonStyle(.automatic)
        // 只固定底栏高度以避免正文跳动；按钮尺寸、内边距和外形交给系统决定。
        .frame(height: max(32, interfaceScale.scaled(28)))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// 图标同时使用形状与状态色区分结果，品牌图标和正文不随此状态染色。
    private var footerStatus: (symbol: String, color: Color) {
        if session.isInstalling {
            return (session.isUninstalling ? "trash.circle" : "arrow.down.circle", .accentColor)
        }
        if session.hasFailures { return ("exclamationmark.circle.fill", .red) }
        if session.phase == .cancelled { return ("stop.circle.fill", .orange) }
        if session.phase == .finished { return ("checkmark.circle.fill", .green) }
        if session.hasDuplicateNames || session.scan?.complete == false {
            return ("exclamationmark.triangle.fill", .orange)
        }
        return ("info.circle.fill", .accentColor)
    }

    private var footerText: String {
        if session.isInstalling {
            return String.l10n(session.isUninstalling ? "repo.skills.uninstall.running" : "repo.skills.install.running")
        }
        if session.hasFailures {
            return String.l10n(session.isUninstalling ? "repo.skills.uninstall.failed" : "repo.skills.install.failed")
        }
        if session.phase == .cancelled { return String.l10n("repo.skills.install.cancelled") }
        if session.phase == .finished {
            let status = session.isUninstalling ? "repo.skills.uninstall.succeeded"
                : session.isExport ? "repo.skills.install.exported" : "repo.skills.install.installed"
            let notice = session.isExport ? "repo.skills.install.exportNotice" : "repo.skills.install.reloadHint"
            return [String.l10n(status), String.l10n(notice)].joined(separator: " · ")
        }
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
        if session.isUninstalling && session.hasFailures { return "repo.skills.install.retry" }
        if session.isUninstalling && session.phase == .cancelled { return "repo.skills.install.resume" }
        if !session.conflicts.isEmpty { return "repo.skills.install.resolve" }
        if session.phase == .finished {
            if session.hasFailures { return "repo.skills.install.retry" }
            if session.plannedItems.isEmpty { return "repo.skills.install.done" }
        }
        if session.isExport { return "repo.skills.install.export" }
        return session.phase == .cancelled ? "repo.skills.install.resume" : "repo.skills.install.start"
    }

    private var primaryDisabled: Bool {
        if session.isInstalling || (session.phase == .finished && !session.hasFailures && session.plannedItems.isEmpty) { return false }
        return !session.canStart
    }

    /// 主按钮按阶段分派，不能在正在运行或存在冲突时再创建一个安装批次。
    private func primaryAction() {
        if session.isInstalling {
            session.cancel()
        } else if session.phase == .finished && !session.hasFailures && session.plannedItems.isEmpty {
            onClose()
        } else {
            isInspectorPresented = true
            session.start()
        }
    }
}
