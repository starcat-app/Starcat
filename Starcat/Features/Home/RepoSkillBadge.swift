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
                        // 复用现有拼图模板表示可安装的能力模块，不再使用发行包图形。
                        BusinessIcon(.browserExtensions, pointSize: 13)
                        if store.scanningIDs.contains(repo.id) {
                            ProgressView().controlSize(.mini)
                        }
                        label
                    }
                    .foregroundStyle(.primary)
                    .modifier(RepoMetadataCapsuleStyle(
                        background: Color.accentColor.opacity(0.12),
                        border: Color.accentColor.opacity(0.25)
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
                RepoSkillCountLabel(count: scan.skills.count, complete: scan.complete)
                    .id("\(dependencies.databaseScopeRevision):\(repo.id)")
            }
        } else {
            Text(verbatim: "Skill · " + String.l10n("repo.skills.filter.unknown"))
        }
    }
}

/// 原生数字过渡只更新这个小视图，不逐个递增计数，也不回写扫描 Store。
private struct RepoSkillCountLabel: View {
    let count: Int
    let complete: Bool

    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var displayedCount = 0

    var body: some View {
        HStack(spacing: 0) {
            // 用实际数量预留宽度，动画帧不改变胶囊和详情元信息行的布局。
            Text(verbatim: count.formatted(.number.locale(locale)))
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: displayedCount.formatted(.number.locale(locale)))
                        .contentTransition(.numericText(value: Double(displayedCount)))
                }
            if !complete {
                Text(verbatim: "+")
            }
        }
        .monospacedDigit()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: displayedCount)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: count.formatted(.number.locale(locale)) + (complete ? "" : "+")))
        .task(id: count) {
            // 首次让 0 先进入视图事务；后续数量变化直接从当前值过渡，离页自动取消。
            if !reduceMotion { await Task.yield() }
            guard !Task.isCancelled else { return }
            displayedCount = count
        }
    }
}
