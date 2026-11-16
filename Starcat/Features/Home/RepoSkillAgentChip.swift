//
//  RepoSkillAgentChip.swift
//  Starcat
//
//  Agent 安装胶囊：单击立即安装或卸载，实际安装勾号与批量目标描边分别呈现。
//

import SwiftUI

/// 图标优先使用随包品牌资源，缺少素材时读取本地应用图标，最后使用明确的通用终端符号。
struct RepoSkillAgentChip: View {
    let session: RepoSkillSession
    let target: RepoSkillAgentTarget

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var applicationIcon: NSImage?

    private var isInstalled: Bool { session.isInstalled(at: target.destinationID) }
    private var isSelected: Bool { session.selectedDestinationIDs.contains(target.destinationID) }
    private var isBusy: Bool {
        session.isInstalling && session.queue.contains {
            $0.destination.id == target.destinationID && ($0.status == .copying || $0.status == .waiting)
        }
    }
    private var hasConflict: Bool {
        !(session.checks[target.destinationID]?.conflicts.isDisjoint(with: session.activeSkillIDs) ?? true)
    }
    private var title: String {
        target.preset == .agents ? String.l10n("repo.skills.target.agents") : target.preset.agent.name
    }

    var body: some View {
        Button {
            session.toggleAgent(target.destinationID)
        } label: {
            HStack(spacing: 6) {
                logo
                    // Command Code 的轮廓铺满画布，留出光学校正，避免比其他品牌标识显大。
                    .padding(target.preset == .commandCode ? interfaceScale.scaled(1) : 0)
                    .frame(width: interfaceScale.scaled(17), height: interfaceScale.scaled(17))
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Group {
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: hasConflict ? "exclamationmark.circle" : isInstalled ? "checkmark.circle.fill" : "plus")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(!hasConflict && isInstalled ? Color.green : .primary)
                    }
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isInstalled ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isSelected || isInstalled ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1, dash: isSelected && !isInstalled ? [3, 2] : [])
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!session.canToggleAgent(target.destinationID))
        .help(tooltip)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(LocalizedStringKey(isInstalled ? "repo.skills.install.installed" : "repo.skills.list.pending")))
        .task(id: target.applicationPath) {
            if let path = target.applicationPath { applicationIcon = NSWorkspace.shared.icon(forFile: path) }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let name = target.preset.agent.logo, let image = NSImage(named: "SkillAgent-\(name)") {
            // 彩色资源按原色显示；品牌本身的单色标识才随 primary 适配明暗主题。
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
        } else if target.preset == .iFlow {
            Image("iflow").renderingMode(.original).resizable().scaledToFit()
        } else if let applicationIcon {
            Image(nsImage: applicationIcon).renderingMode(.original).resizable().scaledToFit()
        } else {
            Image(systemName: target.preset == .agents ? "folder" : "terminal")
                .resizable().scaledToFit().padding(1)
        }
    }

    /// 使用实际安装路径解释共用目录；批量选择不会被误读成已经安装成功。
    private var tooltip: String {
        let action = String(format: String.l10n(isInstalled ? "repo.skills.agents.uninstall" : "repo.skills.agents.install"), title)
        let path = session.destinations.first { $0.id == target.destinationID }?.displayPath ?? ""
        let selection = isSelected ? String.l10n("repo.skills.agents.batchSelected") : ""
        return [action, path, selection].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
