//
//  RuntimeDownloadButton.swift
//  Starcat
//
//  三项外部工具共用的 Direct 安装操作行，沿用原生设置页的右对齐按钮与行内进度。
//

import SwiftUI

/// 视图只负责确认与展示；共享管理器持有安装，离开设置后继续执行。
struct RuntimeDownloadButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runtime: DownloadableRuntime
    /// nil 表示未找到可用程序；空字符串表示程序存在但无法读取版本，仍须确认
    let installedVersion: String?
    let isCheckingVersion: Bool
    @State private var manager = RuntimeDownloadManager.shared
    @State private var isConfirmingInstallation = false

    private var state: RuntimeDownloadState { manager.state(for: runtime) }
    private var isInstalling: Bool { state.isInstalling }
    private var progress: Double? {
        if case .installing(let value) = state { return value }
        return nil
    }
    private var canCancel: Bool {
        if case .installing = state { return true }
        return false
    }
    private var message: String {
        switch state {
        case .completed(let version): "\(String.l10n("settings.integration.runtimeDownload.configured")) · \(version)"
        case .failed(let message): message
        default: ""
        }
    }

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
                        if let progress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else if !message.isEmpty {
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    // 绿色胶囊只表示确实有更新，不能把当前版或较低版本标成新版
                    if !isCheckingVersion, versionRelationship == .updateAvailable {
                        HStack(spacing: 4) {
                            Image(systemName: "tag")
                                .accessibilityHidden(true)
                            Text(verbatim: runtime.version)
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(.green.opacity(0.3), lineWidth: 0.5)
                        }
                        .fixedSize()
                    }
                    Button("settings.integration.runtimeDownload.action", action: requestInstallation)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isInstalling || isCheckingVersion)
                        .help(Text(verbatim: runtime.downloadURLs.map(\.absoluteString).joined(separator: "\n")))
                    if canCancel {
                        Button("common.cancel") { manager.cancel(runtime) }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                    }
                }
            }
            .alert("settings.integration.runtimeDownload.action", isPresented: $isConfirmingInstallation) {
                if versionRelationship == .current {
                    Button("settings.integration.runtimeDownload.reinstall", action: install)
                } else {
                    Button("settings.integration.runtimeDownload.action", action: install)
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text(verbatim: installationConfirmation)
            }
            .onChange(of: installedVersion) { isConfirmingInstallation = false }
            .onChange(of: isCheckingVersion) {
                if isCheckingVersion { isConfirmingInstallation = false }
            }
            .onDisappear {
                isConfirmingInstallation = false
            }
        }
    }

    private var versionRelationship: RuntimeDownloadVersionRelationship {
        RuntimeDownloadVersionRelationship(installedVersion: installedVersion ?? "", availableVersion: runtime.executableVersion)
    }

    /// 确认文案使用同一次检测结果；未知版本与降级不能伪装成普通更新
    private var installationConfirmation: String {
        switch versionRelationship {
        case .current:
            String(format: String.l10n("settings.integration.runtimeDownload.currentVersion"),
                   runtime.displayName, installedVersion ?? "")
        case .newer:
            String(format: String.l10n("settings.integration.runtimeDownload.newerVersion"),
                   runtime.displayName, installedVersion ?? "", runtime.version)
        case .unknown, .updateAvailable:
            String(format: String.l10n("settings.integration.runtimeDownload.unknownVersion"),
                   runtime.displayName, runtime.version)
        }
    }

    /// 未安装或确有更新时直接安装；已有程序的重复安装、降级和版本读取失败均先确认
    private func requestInstallation() {
        guard !isInstalling, !isCheckingVersion else { return }
        if installedVersion == nil || versionRelationship == .updateAvailable {
            install()
        } else {
            isConfirmingInstallation = true
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

    /// 只发起已经确认的请求，不捕获视图 Binding 或拥有后台任务。
    private func install() {
        guard !isInstalling, !isCheckingVersion else { return }
        manager.start(runtime)
    }
}
