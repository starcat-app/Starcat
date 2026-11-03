//
//  RepositorySourceDownloadSettingsSection.swift
//  Starcat
//
//  源码工具共用的下载限制；沿用原 AppSettings 字段，不创建另一份工具配置。
//

import SwiftUI

/// 共享 ZIP 上限独立于代码上下文开关，其他源码工具仍需要读取这项设置。
struct RepositorySourceDownloadSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ai.context.settings.maximumArchiveSize")
                    Text("settings.integration.tools.download.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                LocalToolIntegerField(
                    title: "ai.context.settings.maximumArchiveSize",
                    value: $settings.aiRepoContextMaximumArchiveMB,
                    range: AppSettings.aiRepoContextMaximumArchiveMBRange
                )
            }
        } header: {
            SettingsSectionHeader("settings.integration.tools.download.title", systemImage: "arrow.down.circle")
        }
    }
}
