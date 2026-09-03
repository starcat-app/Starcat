//
//  StorageCacheUsageOverview.swift
//  Starcat
//
//  设置 → 存储 → Cache Usage 顶部的用量总览卡。
//
//  视觉参考 OrbStack Disk usage：标题 + 汇总、分段比例条、双列色点图例、底部说明。
//  语义与 OrbStack 不同：条的 100% = Starcat 可清理缓存合计，不是整盘容量。
//
//  关键约束：
//  - 大类合并，避免十几种缓存把进度条切碎；
//  - 只做只读总览，清理仍走下方明细行；
//  - 颜色走固定 hex（明暗各一套），不用 `.tertiary`。
//

import SwiftUI

/// Cache Usage 总览的合并大类。
enum StorageCacheUsageGroup: String, CaseIterable, Identifiable {
    case content
    case discovery
    case ai
    case code

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .content: return "settings.storage.cacheOverview.group.content"
        case .discovery: return "settings.storage.cacheOverview.group.discovery"
        case .ai: return "settings.storage.cacheOverview.group.ai"
        case .code: return "settings.storage.cacheOverview.group.code"
        }
    }

    /// 亮色主题色点 / 色段。
    private var lightHex: UInt32 {
        switch self {
        case .content: return 0x3B82F6   // 蓝：README / 图片 / 归档等
        case .discovery: return 0x64748B // 灰蓝：搜索 / Wiki / Issue
        case .ai: return 0x8B5CF6        // 紫：对话 / RAG / 推荐
        case .code: return 0xE8A87C      // 桃橙：CodeFlow / Codebase Memory
        }
    }

    /// 暗色主题略提亮，保持同色相。
    private var darkHex: UInt32 {
        switch self {
        case .content: return 0x60A5FA
        case .discovery: return 0x94A3B8
        case .ai: return 0xA78BFA
        case .code: return 0xF0B48A
        }
    }

    func color(for colorScheme: ColorScheme) -> Color {
        Color.fromHex6(colorScheme == .dark ? darkHex : lightHex)
    }
}

/// 单个大类的字节占用。
struct StorageCacheUsageSegment: Identifiable, Equatable {
    let group: StorageCacheUsageGroup
    let bytes: Int64

    var id: String { group.id }
}

/// 从各缓存源汇总后的总览快照。
struct StorageCacheUsageOverviewSnapshot: Equatable {
    let segments: [StorageCacheUsageSegment]

    var totalBytes: Int64 {
        segments.reduce(0) { $0 + $1.bytes }
    }

    /// 只保留有占用的段，供进度条绘制；图例仍展示全部大类。
    var nonEmptySegments: [StorageCacheUsageSegment] {
        segments.filter { $0.bytes > 0 }
    }

    static func make(
        readmeBytes: Int64,
        imageBytes: Int64,
        archiveBytes: Int64,
        translationBytes: Int64,
        externalSearchBytes: Int64,
        wikiBytes: Int64,
        issueTimelineBytes: Int64,
        issueCommentDraftBytes: Int64,
        recommendationBytes: Int64,
        chatHistoryBytes: Int64,
        ragIndexBytes: Int64,
        ragHistoryBytes: Int64,
        aiContextBytes: Int64,
        codeFlowBytes: Int64,
        codebaseMemoryBytes: Int64
    ) -> StorageCacheUsageOverviewSnapshot {
        let content = readmeBytes + imageBytes + archiveBytes + translationBytes
        let discovery = externalSearchBytes + wikiBytes + issueTimelineBytes
            + issueCommentDraftBytes + recommendationBytes
        let ai = chatHistoryBytes + ragIndexBytes + ragHistoryBytes + aiContextBytes
        let code = codeFlowBytes + codebaseMemoryBytes

        return StorageCacheUsageOverviewSnapshot(
            segments: [
                StorageCacheUsageSegment(group: .content, bytes: content),
                StorageCacheUsageSegment(group: .discovery, bytes: discovery),
                StorageCacheUsageSegment(group: .ai, bytes: ai),
                StorageCacheUsageSegment(group: .code, bytes: code)
            ]
        )
    }
}

/// OrbStack 风格的缓存用量总览卡。
struct StorageCacheUsageOverviewCard: View {
    let snapshot: StorageCacheUsageOverviewSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private let barHeight: CGFloat = 10
    private let emptyBarColorLight = Color.fromHex6(0xE5E7EB)
    private let emptyBarColorDark = Color.fromHex6(0x3F3F46)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            usageBar
            legendGrid
            Divider()
            footer
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("settings.storage.cacheOverview.title"))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("settings.storage.cacheOverview.title")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(totalSummaryText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    private var usageBar: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let active = snapshot.nonEmptySegments
            HStack(spacing: 0) {
                if snapshot.totalBytes <= 0 || active.isEmpty {
                    Rectangle()
                        .fill(colorScheme == .dark ? emptyBarColorDark : emptyBarColorLight)
                } else {
                    ForEach(active) { segment in
                        let ratio = CGFloat(segment.bytes) / CGFloat(snapshot.totalBytes)
                        Rectangle()
                            .fill(segment.group.color(for: colorScheme))
                            .frame(width: max(width * ratio, 1))
                    }
                }
            }
            .frame(width: width, height: barHeight, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: barHeight)
        .accessibilityHidden(true)
    }

    private var legendGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16, alignment: .leading),
                GridItem(.flexible(), spacing: 16, alignment: .leading)
            ],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(snapshot.segments) { segment in
                legendRow(segment)
            }
        }
    }

    private func legendRow(_ segment: StorageCacheUsageSegment) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(segment.group.color(for: colorScheme))
                .frame(width: 8, height: 8)
            Text(segment.group.titleKey)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(segment.bytes.formattedByteSize)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        Text("settings.storage.cacheOverview.footer")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var totalSummaryText: String {
        if snapshot.totalBytes <= 0 {
            return String.l10n("settings.storage.cacheOverview.empty")
        }
        return String(
            format: String.l10n("settings.storage.cacheOverview.totalFormat"),
            snapshot.totalBytes.formattedByteSize
        )
    }
}

#Preview("StorageCacheUsageOverviewCard") {
    Form {
        Section {
            StorageCacheUsageOverviewCard(
                snapshot: .make(
                    readmeBytes: 12_000_000,
                    imageBytes: 4_200_000,
                    archiveBytes: 80_000_000,
                    translationBytes: 500_000,
                    externalSearchBytes: 1_200_000,
                    wikiBytes: 300_000,
                    issueTimelineBytes: 800_000,
                    issueCommentDraftBytes: 40_000,
                    recommendationBytes: 600_000,
                    chatHistoryBytes: 2_500_000,
                    ragIndexBytes: 45_000_000,
                    ragHistoryBytes: 3_000_000,
                    aiContextBytes: 15_000_000,
                    codeFlowBytes: 9_000_000,
                    codebaseMemoryBytes: 22_000_000
                )
            )
        }
    }
    .formStyle(.grouped)
    .frame(width: 560)
}
