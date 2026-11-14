//
//  RepoMetadataCountLabel.swift
//  Starcat
//
//  Hero 元信息胶囊共用的数字过渡，保持 Skills 与 Issues 的动画节奏和宽度策略一致。
//

import SwiftUI

/// 只持有显示数字，不回写业务 Store；未完成的 Skill 扫描可继续携带数量后的「+」。
struct RepoMetadataCountLabel: View {
    let count: Int
    var complete = true

    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var displayedCount = 0

    /// 按真实数量预留空间，让原生数字过渡只影响字形，不逐帧推动整行胶囊。
    var body: some View {
        HStack(spacing: 0) {
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
            // 首次让 0 先进入视图事务；后续从当前值过渡，离页取消，不引入逐数定时器。
            if !reduceMotion { await Task.yield() }
            guard !Task.isCancelled else { return }
            displayedCount = count
        }
    }
}
