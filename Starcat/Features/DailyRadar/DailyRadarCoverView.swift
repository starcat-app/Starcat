//
//  DailyRadarCoverView.swift
//  Starcat
//
//  封面两级来源：AI/远程封面（hero_url / card_url）→ 程序化封面（本地 Canvas 绘制）。
//  远程失败或无 CDN 时不展示破图，永远有程序化兜底，不触发额外网络请求。
//

import SwiftUI

/// 图片只接受 HTTPS，失败不展示破图、不触发额外生成。
struct DailyRadarCoverView: View {
    let cover: DailyRadarReport.Cover
    /// 分类决定程序化封面的色相与母题；nil 走中性兜底母题。
    var category: String?
    /// 稳定 seed（报告 id）：同分类不同报告的色温/光斑/母题布局各不相同。
    var seed: String = ""
    var hero = false
    /// 左侧文字安全区占比（0~0.4）：featured 大卡左侧叠标题/摘要时传入，
    /// 程序化封面主体右移避让；阅读页 hero / 普通卡 / 往期行保持 0。
    var textSafeLeading: CGFloat = 0

    var body: some View {
        let candidate = hero ? (cover.heroURL ?? cover.cardURL) : cover.cardURL
        AsyncImage(url: candidate?.scheme == "https" ? candidate : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                DailyRadarProgrammaticCover(category: category, seed: seed,
                                            textSafeLeading: textSafeLeading)
            }
        }
        .accessibilityLabel(Text(verbatim: cover.alt))
    }
}
