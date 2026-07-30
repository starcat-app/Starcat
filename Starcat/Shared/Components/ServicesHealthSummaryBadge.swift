//
//  ServicesHealthSummaryBadge.swift
//  Starcat
//
//  设置页 → 服务 Tab intro 行右侧：四路 ping 探测的汇总 pill。
//
//  数据来自 `ServicesHealthSummary`（本地 `ServiceHealthChecker`）；点击跳转公开状态页。
//

import SwiftUI

struct ServicesHealthSummaryBadge: View {

    let summary: ServicesHealthSummary
    let linkURL: URL

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Link(destination: linkURL) {
            badgeContent
        }
        .help(Text("settings.services.status"))
    }

    private var badgeContent: some View {
        HStack(spacing: 6) {
            if summary == .checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: summary.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(summary.tint)
            }
            if let formatted = summary.partialTitle {
                Text(verbatim: formatted)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text(summary.titleKey)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(badgeBorder, lineWidth: 1)
        }
        .fixedSize()
    }

    private var badgeBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }

    private var badgeBorder: Color {
        Color.secondary.opacity(colorScheme == .dark ? 0.35 : 0.22)
    }
}

/// 单服务 ping 结果行（设置页各卡片「测试」行左侧复用）。
struct ServiceHealthOutcomeLabel: View {

    let outcome: HealthCheckOutcome
    var colorForOutcome: (HealthCheckOutcome) -> Color

    var body: some View {
        let successVersionSuffix = outcome.successVersionSuffix

        HStack(spacing: 4) {
            Image(systemName: outcome.systemImage)
                .foregroundStyle(colorForOutcome(outcome))
            HStack(spacing: successVersionSuffix == nil ? 4 : 0) {
                Text(outcome.titleKey)
                    .foregroundStyle(colorForOutcome(outcome))
                    .font(.caption)
                if let successVersionSuffix {
                    Text(verbatim: successVersionSuffix)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !outcome.subtitle.isEmpty {
                    Text(verbatim: outcome.subtitle)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}
