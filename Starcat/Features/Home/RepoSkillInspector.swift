//
//  RepoSkillInspector.swift
//  Starcat
//
//  安装工作区右栏：目录多选、逐目录覆盖状态与逐 Skill 的安装队列。
//

import SwiftUI

/// 右栏与左栏共享同一份会话状态；安装期间目录与选择全部锁定，只保留阅读能力。
struct RepoSkillInspector: View {
    let session: RepoSkillSession

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                configuration
                progress
                if !session.conflicts.isEmpty { conflict }
            }
            .padding(14)
        }
        .background(Color.primary.opacity(0.02))
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sectionTitle(session.isExport ? "repo.skills.install.export" : "repo.skills.config.title", symbol: "gearshape")
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    Button("repo.skills.selection.all") { session.selectAllDestinations(true) }
                    Button("repo.skills.selection.clear") { session.selectAllDestinations(false) }
                }
                .font(interfaceScale.font(.caption))
                .disabled(session.isInstalling)
                .padding(.trailing, 12)
            }
            Divider()
            VStack(spacing: 0) {
                ForEach(session.destinations) { destination in
                    destinationRow(destination)
                    if destination.id != session.destinations.last?.id {
                        Divider().padding(.leading, 30)
                    }
                }
                if session.destinations.isEmpty {
                    Text("repo.skills.destination.choose")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            HStack {
                Spacer()
                Button("repo.skills.destination.choose") { session.chooseDirectory() }
                    .controlSize(.small)
            }
            .padding(10)
            .disabled(session.isInstalling)
            if session.isExport {
                Text("repo.skills.install.exportNotice")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .background(RepoSkillPanelStyle.panelColor(colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.11)) }
    }

    /// 两行主信息加一条通用目录说明；整个 Toggle 标签均可点击，删除独立放在行尾。
    private func destinationRow(_ destination: RepoSkillDestination) -> some View {
        let isSelected = session.selectedDestinationIDs.contains(destination.id)
        let isPreset = destination.preset != nil
        let check = session.checks[destination.id]
        return HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in session.toggleDestination(destination.id) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(destinationTitle(destination)))
                            .font(interfaceScale.font(.body, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        destinationStatus(check)
                    }
                    Text(verbatim: destination.displayPath)
                        .font(interfaceScale.font(.code))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination.url.path)
                    if destination.preset == .agents {
                        Text("repo.skills.target.agentsNote")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            }
            .toggleStyle(.checkbox)
            .disabled(session.isInstalling)
            if !isPreset {
                Button {
                    session.removeDirectory(destination.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("repo.skills.target.remove")
                .accessibilityLabel(Text("repo.skills.target.remove"))
                .disabled(session.isInstalling)
            }
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    private func destinationTitle(_ destination: RepoSkillDestination) -> String {
        switch destination.preset {
        case .agents: "repo.skills.target.agents"
        case .claudeCode: "repo.skills.target.claude"
        case nil: "repo.skills.target.custom"
        }
    }

    /// 每个目录只显示它自己的覆盖状态：未选目录仍可核对，帮助决定是否勾选。
    @ViewBuilder
    private func destinationStatus(_ check: RepoSkillSession.DestinationCheck?) -> some View {
        if let error = check?.error {
            Label(String.l10n("repo.skills.error.authorization"), systemImage: "exclamationmark.circle.fill")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.red)
                .help(error)
        } else if let check {
            let installed = check.installed.count
            if !check.conflicts.isEmpty {
                Text("repo.skills.target.conflict")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.orange)
            } else if installed > 0, installed < session.skills.count {
                Text(String(format: String.l10n("repo.skills.target.partial"), installed, session.skills.count))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if installed > 0 {
                Label(String.l10n("repo.skills.install.installed"), systemImage: "checkmark.circle.fill")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.green)
            } else if session.isCheckingDestination {
                ProgressView().controlSize(.small)
            } else {
                Text("repo.skills.list.pending")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionTitle("repo.skills.progress.title", symbol: "arrow.down.to.line")
                Spacer(minLength: 2)
                Text(verbatim: "\(session.displayedQueue.filter { $0.status == .succeeded }.count) / \(session.displayedQueue.count)")
                    .font(interfaceScale.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
            Divider()
            LazyVStack(spacing: 12) {
                ForEach(session.displayedGroups) { group in
                    let items = group.items
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(verbatim: group.skill.name)
                                .font(interfaceScale.font(.body, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: "\(items.filter { $0.status == .succeeded }.count)/\(items.count)")
                                .font(interfaceScale.font(.captionSmall))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        ForEach(items) { progressRow($0) }
                    }
                }
                if session.displayedQueue.isEmpty {
                    Text("repo.skills.progress.empty")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            .padding(12)
        }
        .background(RepoSkillPanelStyle.panelColor(colorScheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.11)) }
    }

    /// 状态图例不再是圆形底，只保留系统符号与语义色，弱化装饰感。
    private func progressRow(_ item: RepoSkillSession.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol(item.status))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(statusColor(item.status))
                .frame(width: 22, height: 20, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: item.destination.displayPath)
                        .font(interfaceScale.font(.code))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.destination.url.path)
                    Spacer(minLength: 0)
                    if item.status == .copying {
                        RepoSkillItemProgress(item: item, showsBar: false)
                    }
                }
                if item.status == .copying {
                    RepoSkillItemProgress(item: item, showsBar: true)
                } else if let error = item.error {
                    Text(verbatim: error)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(LocalizedStringKey(session.conflicts.contains { $0.id == item.id }
                                             ? "repo.skills.status.blocked" : statusKey(item.status)))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 决策卡按「Skill × 目录」展示，跳过与替换只影响当前目录。
    private var conflict: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("repo.skills.conflict.title", systemImage: "exclamationmark.circle.fill")
                .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
            Text("repo.skills.conflict.message")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(session.conflicts) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.skill.name)
                        .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: item.destination.displayPath)
                        .font(interfaceScale.font(.code))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Spacer()
                        Button("repo.skills.conflict.skip") { session.resolveConflict(item.id, replacing: false) }
                        Button("repo.skills.conflict.replace") { session.resolveConflict(item.id, replacing: true) }
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.5)) }
    }

    private func sectionTitle(_ key: LocalizedStringKey, symbol: String) -> some View {
        Label(key, systemImage: symbol)
            .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
            .lineLimit(1)
            .padding(12)
    }

    private func statusKey(_ status: RepoSkillSession.Status) -> String {
        switch status {
        case .waiting: "repo.skills.status.waiting"
        case .copying: "repo.skills.install.running"
        case .succeeded: session.isExport ? "repo.skills.install.exported" : "repo.skills.install.succeeded"
        case .failed: "repo.skills.install.failed"
        case .cancelled: "repo.files.cancelled"
        }
    }

    private func statusSymbol(_ status: RepoSkillSession.Status) -> String {
        switch status {
        case .waiting: "clock"
        case .copying: "arrow.down.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "stop.circle"
        }
    }

    private func statusColor(_ status: RepoSkillSession.Status) -> Color {
        switch status {
        case .waiting: .secondary
        case .copying: .accentColor
        case .succeeded: .green
        case .failed, .cancelled: .orange
        }
    }
}

/// 逐字节进度只使这段视图失效，不把整份安装队列重新布局。
private struct RepoSkillItemProgress: View {
    let item: RepoSkillSession.Item
    let showsBar: Bool
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        if showsBar {
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        } else {
            Text(verbatim: "\(Int(item.progress * 100))%")
                .font(interfaceScale.font(.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
