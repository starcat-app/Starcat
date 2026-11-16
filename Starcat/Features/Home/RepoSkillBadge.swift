//
//  RepoSkillBadge.swift
//  Starcat
//
//  许可证同行的真实 Skill 入口。完整扫描无结果后隐藏，失败保留重试入口。
//

import SwiftUI

/// 胶囊消费缓存中的数量，数字动画的状态与仓库检测任务分离。
struct RepoSkillBadge: View {
    let repo: Repo
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var workspaceWindow = WorkspaceSceneWindowReference()

    var body: some View {
        let store = dependencies.repoSkillStore
        let presence = store.presence(for: repo)
        // 只有拿到识别结果才允许点开；检测失败保留点开重试，避免胶囊变成死入口。
        let canOpen = presence == .contains || store.errors[repo.id] != nil
        Group {
            if presence != .absent {
                Button {
                    RepoSkillWindowController.present(repo: repo, dependencies: dependencies, parent: workspaceWindow.window)
                } label: {
                    HStack(spacing: 4) {
                        // 复用现有拼图模板表示可安装的能力模块，不再使用发行包图形。
                        BusinessIcon(.browserExtensions, pointSize: interfaceScale.scaled(13))
                        if store.scanningIDs.contains(repo.id) {
                            ProgressView().controlSize(.mini)
                        }
                        label
                    }
                    .foregroundStyle(.primary)
                    .modifier(RepoMetadataCapsuleStyle(
                        background: Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                        border: Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.18)
                    ))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover(opacity: 0.8, scale: 1.0)
                .clickablePointer()
                .disabled(!canOpen)
                .opacity(canOpen ? 1 : 0.6)
                .help(store.errors[repo.id] ?? String.l10n("repo.skills.preview.title"))
            }
        }
        .background(WorkspaceSceneWindowReader(reference: workspaceWindow, minimumContentSize: nil))
        .task(id: "\(dependencies.databaseScopeRevision):\(repo.id):\(repo.pushedAt ?? "")") {
            _ = try? await store.detect(repo)
        }
    }

    @ViewBuilder
    private var label: some View {
        let store = dependencies.repoSkillStore
        if store.presence(for: repo) == .contains, let scan = store.scans[repo.id] {
            HStack(spacing: 0) {
                Text(verbatim: "Skills · ")
                RepoMetadataCountLabel(count: scan.skills.count, complete: scan.complete)
                    .id("\(dependencies.databaseScopeRevision):\(repo.id)")
            }
        } else {
            Text(verbatim: "Skill · " + String.l10n("repo.skills.filter.unknown"))
        }
    }
}
