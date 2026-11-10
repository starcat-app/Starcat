//
//  RepoSkillSheet.swift
//  Starcat
//
//  真实 Skill 三栏安装工作区，窗口尺寸由 AppKit 持有，内容只消费共享会话。
//

import SwiftUI

/// 窗口持有固定画布；选择、阅读、安装配置独立分栏，主操作根据批次阶段切换。
struct RepoSkillSheet: View {
    let session: RepoSkillSession
    let onClose: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AppDependencies.self) private var dependencies
    @State private var previewID = ""

    private var preview: RepoSkill? {
        session.skills.first { $0.id == previewID } ?? session.skills.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    RepoSkillSelectionPane(session: session, previewID: $previewID)
                        .frame(width: min(280, geometry.size.width * 0.25))
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = session.error {
                            Text(verbatim: error).foregroundStyle(.secondary).padding(16)
                        }
                        if session.isLoading && preview == nil {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let preview {
                            if let progress = session.scanProgressText {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(verbatim: progress)
                                }
                                .font(interfaceScale.font(.caption))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 8)
                            }
                            if let issue = preview.installationIssue {
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .font(interfaceScale.font(.caption)).padding(.horizontal, 18)
                            }
                            RepoSkillDetailPane(skill: preview, session: session)
                        } else {
                            ContentUnavailableView(
                                "repo.skills.list.empty", systemImage: "shippingbox",
                                description: Text(session.scan?.complete == true ? "repo.skills.scan.absent" : "repo.skills.scan.incomplete")
                            )
                        }
                        if let scan = session.scan, !scan.complete {
                            DisclosureGroup("repo.skills.scan.incomplete") {
                                ForEach(Array(scan.diagnostics.enumerated()), id: \.offset) { _, message in
                                    Text(verbatim: message).textSelection(.enabled)
                                }
                            }
                            .font(interfaceScale.font(.caption))
                            .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    RepoSkillInspector(session: session)
                        .frame(width: max(310, geometry.size.width * 0.29))
                }
            }
            Divider()
            footer
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
        }
        .onExitCommand(perform: onClose)
        .onChange(of: dependencies.databaseScopeRevision) { _, _ in
            session.close()
            onClose()
        }
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
                .keyboardShortcut(.cancelAction)

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
            session.start()
        }
    }
}
