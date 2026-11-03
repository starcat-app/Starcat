//
//  ExternalSearchProviderIcon.swift
//  Starcat
//
//  联网搜索服务商的共享识别图标。
//  搜索筛选、结果来源和设置分组沿用同一套符号与颜色，避免同一服务商出现不同标识。
//

import SwiftUI

/// 只绘制服务商标识；尺寸由调用方决定，名称与可访问性语义由相邻标题提供。
struct ExternalSearchProviderIcon: View {
    let provider: ExternalSearchProviderID
    let size: CGFloat

    var body: some View {
        icon
            .foregroundStyle(Self.tint(for: provider))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch provider {
        case .anySearch:
            Image(systemName: "asterisk")
                .font(.system(size: size, weight: .bold))
        case .tavily:
            Image(systemName: "bolt.fill")
                .font(.system(size: size, weight: .semibold))
        case .exa:
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: size, weight: .semibold))
        case .braveLLMContext:
            Image(systemName: "shield.fill")
                .font(.system(size: size, weight: .semibold))
        case .firecrawl:
            Image(systemName: "flame.fill")
                .font(.system(size: size, weight: .semibold))
        }
    }

    /// 保留搜索入口既有的服务商识别色，不将其解释为启用或验证状态。
    static func tint(for provider: ExternalSearchProviderID) -> Color {
        switch provider {
        case .anySearch:
            return .orange
        case .tavily:
            return .pink
        case .exa:
            return .purple
        case .braveLLMContext:
            return .orange
        case .firecrawl:
            return .red
        }
    }
}
