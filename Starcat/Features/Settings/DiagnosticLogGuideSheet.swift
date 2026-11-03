//
//  DiagnosticLogGuideSheet.swift
//  Starcat
//
//  轻量日志说明弹窗：区分本机诊断包与 macOS 系统日志，并说明分享前的检查事项。
//  只提供操作说明，不读取系统日志、不上传诊断文件或启动其他应用。
//

import SwiftUI

/// 内容拥有自然高度的单列表单，沿用设置页的关闭按钮与本地化环境。
struct DiagnosticLogGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("settings.diagnostics.layout.logs.title")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                SheetCloseButton { dismiss() }
            }
            Divider()
            explanation(
                "settings.diagnostics.layout.report.title",
                description: "settings.diagnostics.layout.guide.diagnostics"
            )
            Divider()
            explanation(
                "settings.diagnostics.layout.guide.systemTitle",
                description: "settings.diagnostics.layout.guide.systemDescription"
            )
            Divider()
            explanation(
                "settings.diagnostics.layout.guide.sharingTitle",
                description: "settings.diagnostics.layout.guide.sharingDescription"
            )
            HStack {
                Spacer(minLength: 8)
                Button("general.close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    /// 说明内容允许长语言换行，避免固定高度截断排查步骤。
    private func explanation(_ title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.semibold))
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
