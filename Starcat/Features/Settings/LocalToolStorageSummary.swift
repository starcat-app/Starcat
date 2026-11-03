//
//  LocalToolStorageSummary.swift
//  Starcat
//
//  本地源码工具共用的单行产物统计，只展示已有存储摘要，不触发扫描。
//

import SwiftUI

/// 四项统计始终保留在同一行；长翻译或大字号放不下时横向滚动，不改变分组高度。
struct LocalToolStorageSummary: View {
    let projectCount: Int
    let totalBytes: Int64
    let generationCount: Int
    let latestGeneratedAt: Date?

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        ViewThatFits(in: .horizontal) {
            metrics
            ScrollView(.horizontal) {
                metrics.fixedSize(horizontal: true, vertical: true)
            }
            .scrollIndicators(.hidden)
        }
        // 水平 ScrollView 在 Form 中需要明确高度，避免参与纵向剩余空间分配。
        .frame(height: interfaceScale.scaled(48), alignment: .center)
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 24) {
            metric("settings.integration.codeFlow.stat.projects", value: projectCount.formatted(.number.locale(locale)))
            metric("settings.integration.codeFlow.stat.usage", value: totalBytes.formatted(.byteCount(style: .file).locale(locale)))
            metric("settings.integration.codeFlow.stat.totalGenerated", value: String(
                format: String.l10n("settings.integration.codeFlow.stat.totalGeneratedFormat"),
                locale: locale,
                generationCount
            ))
            metric("settings.integration.codeFlow.stat.lastGenerated", value: latestGeneratedAt.map {
                $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            } ?? "—")
        }
    }

    /// 标签和值一起测量宽度，避免英文标题换行而使同排统计错位。
    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
