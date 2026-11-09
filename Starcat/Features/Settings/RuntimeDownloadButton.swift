//
//  RuntimeDownloadButton.swift
//  Starcat
//
//  三项外部工具共用的 Direct 安装操作行，沿用原生设置页的右对齐按钮与行内进度。
//

import SwiftUI

/// 视图拥有按钮任务的生命周期；离开页面时取消安装，取消后不得提交配置。
struct RuntimeDownloadButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runtime: DownloadableRuntime
    @Binding var isInstalling: Bool
    let configure: @MainActor (RuntimeDownloadInstallation) async throws -> Void

    @State private var task: Task<Void, Never>?
    @State private var progress: Double?
    @State private var message = ""

    var body: some View {
        if DistributionChannel.current.isDirect, runtime.isSupported {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isInstalling {
                        downloadProgress
                            .frame(width: 64)
                        Text("settings.integration.runtimeDownload.installing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !message.isEmpty {
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: runtime.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("settings.integration.runtimeDownload.action", action: install)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isInstalling)
                    if isInstalling {
                        Button("common.cancel") { task?.cancel() }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
                if runtime == .codebaseMemory {
                    Text("settings.integration.runtimeDownload.reindex")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    /// 沿用本地模型下载的 4pt 轨道；未知总量时使用同款滑块，避免把等待误报为 0%。
    private var downloadProgress: some View {
        Group {
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(.tint)
                            .frame(width: geometry.size.width * max(0, min(1, progress)))
                    }
                }
                .frame(height: 4)
            } else {
                IndeterminateCapsuleBar(tint: .accentColor, reduceMotion: reduceMotion)
            }
        }
        .accessibilityRepresentation {
            ProgressView(value: progress) {
                Text("settings.integration.runtimeDownload.installing")
            }
        }
    }

    /// configure 闭包仅在校验和取消检查通过之后执行；失败时维持已有配置。
    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        message = ""
        progress = nil
        task = Task { @MainActor in
            defer {
                isInstalling = false
                task = nil
            }
            do {
                let installation = try await RuntimeDownloadInstaller.shared.install(runtime) { value in
                    Task { @MainActor in progress = value }
                }
                try Task.checkCancellation()
                try await configure(installation)
                message = "\(String.l10n("settings.integration.runtimeDownload.configured")) · \(installation.reportedVersion)"
            } catch is CancellationError {
                message = ""
            } catch {
                // URLSession 取消可能表现为 URLError.cancelled，同样属于主动停止。
                message = Task.isCancelled ? "" : error.localizedDescription
            }
        }
    }
}
