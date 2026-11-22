//
//  RepoMetadataCountLabel.swift
//  Starcat
//
//  详情统计、元信息胶囊与智能集合卡片共用的数字过渡。
//

import SwiftUI

/// 列表快照的仓库 ID 有时为 0，按完整仓库名区分详情，补全 ID 时延续当前展示。
struct RepoStatCountKey: Hashable {
    enum Metric: Hashable { case stars, forks, subscribers }

    let fullName: String
    let metric: Metric

    init(_ fullName: String, _ metric: Metric) {
        self.fullName = fullName.lowercased()
        self.metric = metric
    }
}

/// 未知值保留占位。只给数字绑定仓库身份，让切换仓库时菜单和加载任务维持各自的生命周期。
struct RepoMetadataCountLabel: View {
    let count: Int?
    var complete = true
    var introductionKey: RepoStatCountKey?

    var body: some View {
        if let count {
            RollingCountText(count: count, complete: complete)
                .id(introductionKey)
        } else {
            Text(verbatim: "-").monospacedDigit()
        }
    }
}

/// 入场播放一次数字过渡，同一视图中目标值改变时沿用已显示的计数。
struct RollingCountText: View {
    let count: Int
    var complete = true
    var format: IntegerFormatStyle<Int> = .number

    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var presentation = Presentation.entering

    enum Presentation: Equatable {
        case entering
        case showing(Int)

        func display(for count: Int, reduceMotion: Bool) -> (value: Int, opacity: Double) {
            if reduceMotion { return (count, 1) }
            switch self {
            case .entering: return (0, count == 0 ? 0 : 1)
            case .showing(let value): return (value, 1)
            }
        }
    }

    var body: some View {
        let display = presentation.display(for: count, reduceMotion: reduceMotion)
        let localizedFormat = format.locale(locale)
        let targetText = count.formatted(localizedFormat)
        HStack(spacing: 0) {
            Text(verbatim: targetText)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: display.value.formatted(localizedFormat))
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(display.value)))
                }
            if !complete {
                Text(verbatim: "+")
            }
        }
        .opacity(display.opacity)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: targetText + (complete ? "" : "+")))
        .task(id: count) {
            guard presentation != .showing(count) else { return }
            if !reduceMotion { await Task.yield() }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                presentation = .showing(count)
            }
        }
        .onDisappear {
            // 视图身份可能被容器保留，恢复入场状态使同一数字下次出现时也能播放。
            presentation = .entering
        }
    }
}
