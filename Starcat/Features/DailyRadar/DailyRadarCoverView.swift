//
//  DailyRadarCoverView.swift
//  Starcat
//
//  远程封面下载失败或尚无 CDN 时使用已随 App 分发的分类封面。
//

import SwiftUI

/// 图片只接受 HTTPS，失败不展示破图、不触发额外生成。
struct DailyRadarCoverView: View {
    let cover: DailyRadarReport.Cover
    var hero = false
    var body: some View {
        let candidate = hero ? (cover.heroURL ?? cover.cardURL) : cover.cardURL
        AsyncImage(url: candidate?.scheme == "https" ? candidate : nil) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(cover.assetName).resizable().scaledToFill()
            }
        }
        .accessibilityLabel(Text(verbatim: cover.alt))
    }
}
