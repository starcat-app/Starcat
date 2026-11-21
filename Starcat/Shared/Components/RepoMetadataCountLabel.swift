//
//  RepoMetadataCountLabel.swift
//  Starcat
//
//  详情统计与元信息胶囊共用的数字过渡，按目标数字预留宽度。
//

import SwiftUI

/// 列表快照的仓库 ID 有时为 0，按完整仓库名识别同一份详情，补全 ID 后仍沿用首播记录。
struct RepoStatCountKey: Hashable {
    enum Metric: Hashable { case stars, forks, subscribers }

    let fullName: String
    let metric: Metric

    init(_ fullName: String, _ metric: Metric) {
        self.fullName = fullName.lowercased()
        self.metric = metric
    }
}

/// 会话内每个已展示的指标只记一个标记，数值刷新和视图重建均不增加记录。
struct RepoStatCountHistory {
    @MainActor static var session = Self()
    private var presented: Set<RepoStatCountKey> = []

    func initialValue(for key: RepoStatCountKey, count: Int) -> Int {
        presented.contains(key) ? count : 0
    }

    mutating func claimIntroduction(for key: RepoStatCountKey) -> Bool {
        presented.insert(key).inserted
    }
}

/// 未知值保留占位。只给数字绑定仓库身份，让切换仓库时菜单和加载任务维持各自的生命周期。
struct RepoMetadataCountLabel: View {
    let count: Int?
    var complete = true
    var introductionKey: RepoStatCountKey?

    var body: some View {
        if let count {
            RepoRollingCount(count: count, complete: complete, introductionKey: introductionKey)
                .id(introductionKey)
        } else {
            Text(verbatim: "-").monospacedDigit()
        }
    }
}

private struct RepoRollingCount: View {
    let count: Int
    let complete: Bool
    let introductionKey: RepoStatCountKey?

    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var displayedCount: Int

    init(count: Int, complete: Bool, introductionKey: RepoStatCountKey?) {
        self.count = count
        self.complete = complete
        self.introductionKey = introductionKey
        let initialCount = introductionKey.map { RepoStatCountHistory.session.initialValue(for: $0, count: count) } ?? 0
        _displayedCount = State(initialValue: initialCount)
    }

    /// 与智能集合右上角同用 180ms 原生滚动。只提交目标数，位数变化时按真实数字占位。
    var body: some View {
        let visibleCount = reduceMotion ? count : displayedCount
        HStack(spacing: 0) {
            Text(verbatim: count.formatted(.number.locale(locale)))
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: visibleCount.formatted(.number.locale(locale)))
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(visibleCount)))
                }
            if !complete {
                Text(verbatim: "+")
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: count.formatted(.number.locale(locale)) + (complete ? "" : "+")))
        .onAppear {
            // 在真正显示时认领首播。两个窗口同时构造同一指标时，后来出现的直接显示真值。
            if let introductionKey, !RepoStatCountHistory.session.claimIntroduction(for: introductionKey),
               displayedCount != count {
                displayedCount = count
            }
        }
        .task(id: count) {
            guard displayedCount != count else { return }
            if !reduceMotion { await Task.yield() }
            guard !Task.isCancelled, displayedCount != count else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                displayedCount = count
            }
        }
    }
}
