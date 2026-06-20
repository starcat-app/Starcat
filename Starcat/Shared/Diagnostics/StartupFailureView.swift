//
//  StartupFailureView.swift
//  Starcat
//
//  启动失败兜底页。
//
//  当数据库等核心依赖无法初始化时，继续进入主界面会让 Repository 在半初始化状态下
//  读写错误位置。这里改为受控失败页：明确告诉用户发生了什么，并保留导出诊断包入口。
//

import AppKit
import SwiftUI

struct StartupFailureView: View {

    let error: UserFacingError

    @State private var exportMessage: String?
    @State private var exportError: String?
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(verbatim: error.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(verbatim: error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                if let recovery = error.recovery {
                    Text(verbatim: recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await exportDiagnostics() }
                } label: {
                    Label("diagnostics.export.button", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)

                Button("diagnostics.quit") {
                    NSApplication.shared.terminate(nil)
                }
            }

            if isExporting {
                ProgressView()
                    .controlSize(.small)
            } else if let exportMessage {
                Text(verbatim: exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 360)
        .alert(
            "diagnostics.export.failed.title",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("general.ok") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @MainActor
    private func exportDiagnostics() async {
        isExporting = true
        defer { isExporting = false }

        switch await DiagnosticBundleExporter.exportFromPanel(settings: nil) {
        case .exported(let url):
            exportMessage = String(format: String.l10n("diagnostics.export.successFormat"), url.path)
        case .cancelled:
            break
        case .failed(let message):
            exportError = message
        }
    }
}
