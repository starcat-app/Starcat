//
//  CollectionTrendConfigurationIntent.swift
//  Starcat
//
//  收藏趋势 Widget 的单实例热力图配色配置。
//

import AppIntents

/// 用户可为每个收藏趋势 Widget 单独选择的热力图配色。
///
/// 配置只描述语义主题，实际颜色仍由 Widget 根据明暗模式生成，避免把固定背景色
/// 写进共享契约后破坏系统桌面材质与对比度。
enum CollectionTrendPalette: String, AppEnum, CaseIterable, Sendable {
    case system
    case evergreen
    case ocean
    case ember
    case nordic

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "widget.collectionTrend.palette.type"
    )

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .system: DisplayRepresentation(title: "widget.collectionTrend.palette.system"),
        .evergreen: DisplayRepresentation(title: "widget.collectionTrend.palette.evergreen"),
        .ocean: DisplayRepresentation(title: "widget.collectionTrend.palette.ocean"),
        .ember: DisplayRepresentation(title: "widget.collectionTrend.palette.ember"),
        .nordic: DisplayRepresentation(title: "widget.collectionTrend.palette.nordic")
    ]
}

/// Widget Gallery 的“编辑 Widget”入口使用此 Intent 保存每个实例的主题选择。
struct CollectionTrendConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.collectionTrend.configuration.title"
    static let description = IntentDescription(
        "widget.collectionTrend.configuration.description"
    )

    @Parameter(
        title: "widget.collectionTrend.configuration.palette",
        default: CollectionTrendPalette.system
    )
    var palette: CollectionTrendPalette

    init() {
        palette = .system
    }
}
