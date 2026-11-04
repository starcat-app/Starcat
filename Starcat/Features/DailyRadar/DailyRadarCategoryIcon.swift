//
//  DailyRadarCategoryIcon.swift
//  Starcat
//
//  日报侧栏与标题共用分类图标；品牌素材保持原色，SF Symbol 使用固定分类色。
//  仅侧栏响应系统选中背景，避免标题继承列表选中态后意外反白。
//

import SwiftUI

/// 按当前分类绘制本地图标；调用方保留原有字号和画布，不改变导航布局。
struct DailyRadarCategoryIcon: View {
    let categoryID: String?
    let size: CGFloat
    var isSidebar = false
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let canvas = isSidebar ? 14.0 : size
        Group {
            if let assetName {
                let needsPedestal = isSidebar && backgroundProminence == .increased && colorScheme == .light
                let logoSize = needsPedestal ? max(canvas - 3, canvas * 0.72) : canvas
                ZStack {
                    if needsPedestal {
                        Circle().fill(Color.white)
                    }
                    Image(assetName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                }
                .frame(width: canvas, height: canvas)
            } else if let symbol {
                // 分类色是用户确认的识别色；文字仍沿用 primary/secondary。
                // 侧栏选中反白交给系统背景语义，不能用 selection binding 猜测。
                BusinessIcon(symbol, pointSize: canvas)
                    .foregroundStyle(isSidebar
                        ? AnyShapeStyle(SidebarSemanticIconStyle(semanticColor: color))
                        : AnyShapeStyle(color))
            } else {
                // 未知分类保留中性圆点（SF）。
                Image(systemName: "circle.fill")
                    .foregroundStyle(isSidebar
                        ? AnyShapeStyle(SidebarSemanticIconStyle(semanticColor: color))
                        : AnyShapeStyle(color))
                    .frame(width: canvas, height: canvas)
            }
        }
        .accessibilityHidden(true)
    }

    /// 复用已登记许可的本地品牌素材，避免标题和侧栏各维护一份来源映射。
    private var assetName: String? {
        switch categoryID {
        case "ai-hn": return "WeeklySources/hackernews"
        case "ai-ph": return "WeeklySources/producthunt"
        case "ai-arxiv": return "WeeklySources/arxiv"
        case "ai-hf": return "WeeklySources/huggingface"
        default: return nil
        }
    }

    /// 总览标题用报纸，侧栏「全部主题」沿用网格；其余分类对齐注册表业务图形。
    private var symbol: BusinessIcon.Symbol? {
        switch categoryID {
        case nil: return isSidebar ? .layoutGrid : .weekly
        case "ai-cli": return .terminal
        case "ai-agents": return .following
        case "ai-infra": return .services
        case "ai-web": return .announcement
        case "ai-trending": return .alternatives
        case "ai-community": return .linuxDo
        case "ai-weekly": return .weekly
        case "ai-weekly-events": return .announcement
        case "ai-monthly": return .archive
        default: return nil
        }
    }

    /// 固定分类色使用系统调色板适配明暗主题；未知分类保留中性图标。
    private var color: Color {
        switch categoryID {
        case nil: return .indigo
        case "ai-cli": return .cyan
        case "ai-agents": return .orange
        case "ai-infra": return .blue
        case "ai-web": return .pink
        case "ai-trending": return .teal
        case "ai-community": return .green
        case "ai-weekly": return .indigo
        case "ai-weekly-events": return .teal
        case "ai-monthly": return .brown
        default: return .secondary
        }
    }
}
