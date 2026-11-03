//
//  ListPreferencesResetSheet.swift
//  Starcat
//
//  列表偏好重置确认。由触发入口所在窗口承载，固定后果分组展示，不提供范围勾选。
//  Sheet 只负责确认；账号校验、持久化及列表刷新由调用方和 AppSettings 完成。
//

import SwiftUI

/// 设置、Dock 与菜单栏共用的轻量确认界面，避免同一操作出现不同范围说明。
struct ListPreferencesResetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Text("settings.listPreferences.reset.title")
                    .font(.title3.weight(.semibold))
                Spacer()
                SheetCloseButton { dismiss() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.listPreferences.reset.scope.title")
                    .font(.body.weight(.semibold))
                Text("settings.listPreferences.reset.scope.filters")
                Text("settings.listPreferences.reset.scope.sort")
                Text("settings.listPreferences.reset.scope.selection")
            }
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.listPreferences.reset.preserved.title")
                    .font(.body.weight(.semibold))
                Text("settings.listPreferences.reset.preserved.cache")
                Text("settings.listPreferences.reset.preserved.data")
                Text("settings.listPreferences.reset.preserved.collections")
                Text("settings.listPreferences.reset.preserved.languages")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Spacer()
                Button("general.cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("settings.listPreferences.reset.confirmAction", role: .destructive) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.regular)
        }
        .foregroundStyle(.primary)
        .padding(24)
        // 单列短内容按自然高度展开，长译文换行；无需固定工作区的 AppKit sheet。
        .frame(width: 480, alignment: .leading)
    }
}
