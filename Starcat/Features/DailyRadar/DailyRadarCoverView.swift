//
//  DailyRadarCoverView.swift
//  Starcat
//
//  所有日报封面统一在本地绘制，服务端封面元数据仅提供无障碍描述。
//  不建立远程图片请求，保证离线、历史报告与首次展示使用同一套构图。
//

import SwiftUI

/// 首页、往期与阅读页共用的本地封面入口。
struct DailyRadarCoverView: View {
    let cover: DailyRadarReport.Cover
    /// 分类影响构图权重与配色；未知分类仍参与全部构图选择。
    var category: String?
    /// 必须传报告 id，避免多个调用方遗漏身份后生成完全相同的图片。
    let seed: String
    /// 左侧文字安全区占比（0~0.4）：featured 大卡左侧叠标题/摘要时传入，
    /// 图案连续铺满，渐变保护文字；阅读页 hero / 普通卡 / 往期行保持 0。
    var textSafeLeading: CGFloat = 0

    var body: some View {
        DailyRadarProgrammaticCover(category: category, seed: seed,
                                    textSafeLeading: textSafeLeading)
            .accessibilityLabel(Text(verbatim: cover.alt))
    }
}
