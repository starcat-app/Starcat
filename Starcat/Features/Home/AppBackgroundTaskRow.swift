//
//  AppBackgroundTaskRow.swift
//  Starcat
//
//  单个后台任务的状态与安全操作入口；不持有服务或执行状态，不把整行包成含嵌套按钮的 Button。
//

import SwiftUI

/// 只有真实的窗口目标显示查看按钮；停止按钮只影响这一行的服务，不冒充全局取消。
struct AppBackgroundTaskRow: View {
    let task: AppBackgroundTask
    let onOpen: () -> Void
    let onCancel: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let content = HStack(spacing: 8) {
            BusinessIcon(task.kind.icon, pointSize: (task.kind.icon.isAsset ? 16 : 13) * interfaceScale.multiplier)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: task.title)
                    .font(interfaceScale.font(.body, weight: .medium))
                    .help(Text(verbatim: task.title))
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(task.phase.titleKey))
                        .help(Text(LocalizedStringKey(task.phase.titleKey)))
                    if let detail = task.detail.text(locale: locale) {
                        Text(verbatim: detail)
                            .monospacedDigit()
                            .help(Text(verbatim: detail))
                    }
                }
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if task.opensWindow {
                Image(systemName: "macwindow")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        HStack(spacing: 8) {
            if task.opensWindow {
                // 名称、说明和空白区域都可打开任务；停止按钮是并列控件，不会触发窗口。
                Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("aiOrganization.banner.viewTask"))
            } else {
                content
            }
            if task.canCancel {
                Button(action: onCancel) {
                    Label(LocalizedStringKey(task.cancelTitleKey), systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text(LocalizedStringKey(task.cancelTitleKey)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: interfaceScale.scaled(52))
        .accessibilityElement(children: .contain)
    }

}
