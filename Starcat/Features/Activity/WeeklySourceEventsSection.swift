//
//  WeeklySourceEventsSection.swift
//  Starcat
//
//  Weekly 详情页的通用来源事件时间线。所有来源只依赖通用字段，新增渠道无需
//  再增加专属 View；来源私有 payload 只保留在 API 层，不参与基础渲染。
//
//  展开高度：≤4 条贴合内容；>4 条才滚动。不能无条件包 ScrollView + maxHeight，
//  否则 1 条也会被撑出大块空白（ScrollView 会吃掉 maxHeight）。
//

import SwiftUI

struct WeeklySourceEventsSection: View {
    let events: [WeeklySourceEvent]

    @State private var isExpanded = false
    @Environment(\.openURL) private var openURL

    /// 不超过这个条数时面板贴合内容；再多才滚动。
    private static let maxUnscrolledEventCount = 4
    private static let eventRowVerticalPadding: CGFloat = 9
    private static let eventSourceIconSize: CGFloat = 20
    private static let eventRowDividerHeight: CGFloat = 1

    /// 滚动视口按 4 条紧凑行估算（上下 padding + 来源图标）。
    /// 带摘要的行更高，视口里可能看到不足 4 条，多出来的靠滚动看。
    private static var scrolledContentMaxHeight: CGFloat {
        let compactRowHeight = eventRowVerticalPadding * 2 + eventSourceIconSize
        return compactRowHeight * CGFloat(maxUnscrolledEventCount)
            + eventRowDividerHeight * CGFloat(maxUnscrolledEventCount - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                    Text("weekly.sourceEvents.title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(events.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                expandedEventList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private var expandedEventList: some View {
        if events.count <= Self.maxUnscrolledEventCount {
            VStack(alignment: .leading, spacing: 0) {
                eventRows
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    eventRows
                }
            }
            .frame(maxHeight: Self.scrolledContentMaxHeight)
        }
    }

    @ViewBuilder
    private var eventRows: some View {
        ForEach(events) { event in
            eventRow(event)
            if event.id != events.last?.id {
                Divider().padding(.leading, 42)
            }
        }
    }

    @ViewBuilder
    private func eventRow(_ event: WeeklySourceEvent) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            sourceIcon(event.source)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.presentationTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let rank = event.rank {
                        Text("#\(rank)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(event.presentationDate)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let summary = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if event.sourceURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.eventRowVerticalPadding)
        .contentShape(Rectangle())

        if let sourceURL = event.sourceURL {
            Button { openURL(sourceURL) } label: { content }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(sourceURL.absoluteString)
        } else {
            content
        }
    }

    @ViewBuilder
    private func sourceIcon(_ source: WeeklySource) -> some View {
        if let assetName = source.presentation.assetName {
            Image(assetName)
                .resizable()
                .scaledToFill()
                .frame(width: Self.eventSourceIconSize, height: Self.eventSourceIconSize)
                .clipShape(Circle())
        } else {
            Image(systemName: source.presentation.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.eventSourceIconSize, height: Self.eventSourceIconSize)
        }
    }
}
