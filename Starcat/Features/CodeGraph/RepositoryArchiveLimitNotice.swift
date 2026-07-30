//
//  RepositoryArchiveLimitNotice.swift
//  Starcat
//
//  CodeFlow 与 CodebaseMemory 共用的完整仓库 ZIP 上限说明和设置快捷入口。
//

import SwiftUI

/// 在需要下载完整仓库源码的功能入口常驻展示限制，避免用户只在失败后才知道阈值来源。
struct RepositoryArchiveLimitNotice: View {
    @Environment(\.openSettings) private var openSettings

    let maximumArchiveMB: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)

            Text(
                String(
                    format: String.l10n("codeGraph.archiveLimit.noticeFormat"),
                    maximumArchiveMB
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("codeGraph.archiveLimit.adjust") {
                openRepoContextSettings()
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    /// 先打开 Settings scene，再延后一轮切 Tab/展开分组，避免首次创建窗口时通知丢失。
    private func openRepoContextSettings() {
        openSettings()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .starcatJumpToSettingsTab,
                object: "ai.repoContext"
            )
        }
    }
}
