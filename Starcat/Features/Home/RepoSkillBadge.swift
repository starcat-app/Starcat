//
//  RepoSkillBadge.swift
//  Starcat
//
//  许可证同行的真实 Skill 入口。完整扫描无结果后隐藏，失败保留重试入口。
//

import SwiftUI

struct RepoSkillBadge: View {
    let repo: Repo
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let store = dependencies.repoSkillStore
        let presence = store.presence(for: repo)
        // 只有拿到识别结果才允许点开；检测失败保留点开重试，避免胶囊变成死入口。
        let canOpen = presence == .contains || store.errors[repo.id] != nil
        Group {
            if presence != .absent {
                Button {
                    RepoSkillWindowController.present(repo: repo, dependencies: dependencies)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox")
                        if store.scanningIDs.contains(repo.id) {
                            ProgressView().controlSize(.mini)
                        }
                        Text(verbatim: label)
                    }
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover()
                .disabled(!canOpen)
                .opacity(canOpen ? 1 : 0.6)
                .help(store.errors[repo.id] ?? String.l10n("repo.skills.preview.title"))
            }
        }
        .task(id: "\(dependencies.databaseScopeRevision):\(repo.id):\(repo.pushedAt ?? "")") {
            _ = try? await store.detect(repo)
        }
    }

    private var label: String {
        let store = dependencies.repoSkillStore
        guard store.presence(for: repo) == .contains, let scan = store.scans[repo.id] else {
            return "Skill · " + String.l10n("repo.skills.filter.unknown")
        }
        return "Skills · \(scan.skills.count)" + (scan.complete ? "" : "+")
    }
}
