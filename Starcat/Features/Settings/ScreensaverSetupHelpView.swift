//
//  ScreensaverSetupHelpView.swift
//  Starcat
//
//  屏保入口的上下文帮助：按安装、启用与排错组织，避免把系统操作长说明挤进设置行。
//  这里只展示指引，不安装文件、不操作系统设置，也不改变头像下载任务。
//

import SwiftUI

/// 轻量 popover 内容；窄宽度内允许步骤自然换行，技术名称 Starcat.saver 保持原样。
struct ScreensaverSetupHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.general.screensaver.guide.title")
                .font(.headline)
                .foregroundStyle(.primary)

            step(
                "settings.general.screensaver.guide.install.title",
                detail: "settings.general.screensaver.guide.install.body",
                systemImage: "1.circle"
            )
            step(
                "settings.general.screensaver.guide.select.title",
                detail: "settings.general.screensaver.guide.select.body",
                systemImage: "2.circle"
            )

            Divider()

            step(
                "settings.general.screensaver.guide.missing.title",
                detail: "settings.general.screensaver.guide.missing.body",
                systemImage: "questionmark.circle"
            )

            Text("settings.general.screensaver.guide.download.body")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    /// 步骤标题与说明作为同一阅读单元；数字仅作视觉序号，避免辅助功能重复朗读。
    private func step(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(SettingsIconMetrics.standardGlyph)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
