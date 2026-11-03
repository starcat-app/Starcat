//
//  IndexRebuildConfirmationSheet.swift
//  Starcat
//
//  两类索引共用的轻量确认表单：将执行影响和保留内容分开说明。
//  仅确认后调用原构建入口，不新增配置或清理源数据。
//

import SwiftUI

/// 自然高度的单列 sheet，由设置窗口承载；固定后果不呈现为可勾选选项。
struct IndexRebuildConfirmationSheet: View {
    enum Kind {
        case repository
        case knowledge
    }

    let kind: Kind
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(LocalizedStringKey(kind == .repository
                     ? "settings.aiIndex.rebuildAll.confirmTitle"
                     : "settings.searchIndex.knowledge.confirmTitle"))
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                SheetCloseButton { dismiss() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.searchIndex.confirm.impact")
                    .font(.body.weight(.semibold))
                Text(LocalizedStringKey(kind == .repository
                     ? "settings.searchIndex.repository.rebuildImpact"
                     : "settings.searchIndex.knowledge.rebuildImpact"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("settings.searchIndex.confirm.preserved")
                    .font(.body.weight(.semibold))
                Text("settings.searchIndex.confirm.preservedHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                Button("general.cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: kind == .repository ? .destructive : nil) {
                    dismiss()
                    onConfirm()
                } label: {
                    Text(LocalizedStringKey(kind == .repository
                         ? "settings.aiIndex.rebuildAll.confirm" : "settings.rag.index.rebuild"))
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .frame(width: 460)
    }
}
