//
//  ScreensaverSettingsSection.swift
//  Starcat
//
//  Direct「macOS 集成」里的屏保安装 / 更新 / 移除。App Store 构建不编译进可见 UI。
//  安装只拷 .saver；头像快照由 App 启动 / Stars 同步发布，重装不得重下。
//

import AppKit
import SwiftUI

/// Direct 设置页的屏保安装控制。按钮右对齐，符合设置页一次性操作规范。
struct ScreensaverSettingsSection: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale

    @State private var status: ScreensaverInstallStatus = .notInstalled
    @State private var errorMessage: String?
    @State private var isBusy = false
    @State private var showingSetupHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 安装与移除用文字说明动作；帮助保留含义明确的行尾图标。
            HStack(spacing: 16) {
                overview
                actionButtons
            }
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = dependencies.screensaverRefreshCoordinator.avatarProgress,
               progress.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    avatarProgressBar(completed: progress.completed, total: progress.total)
                    Text(
                        String(
                            format: String.l10n("settings.general.screensaver.progressFmt"),
                            locale: locale,
                            progress.completed,
                            progress.total
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
        .onAppear(perform: refreshStatus)
    }

    /// 预览图仅作屏保入口的视觉识别；安装状态与完整系统操作指引仍可由辅助功能和提示读取。
    private var overview: some View {
        HStack(spacing: 12) {
            Image("ScreensaverSettingsPreview")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 36)
                // 小尺寸屏幕预览使用轻圆角与细边框，保留边缘头像并在明暗背景中划清边界。
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                // 16:9 静态头像墙由屏保组件渲染；保留原占位，避免改变整行高度和按钮布局。
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            Text("settings.general.screensaver.title")
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(statusText))
        .help(Text(statusText))
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button(installButtonTitle, action: performInstallAction)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isBusy || installer == nil)

            Button("settings.general.screensaver.remove", role: .destructive, action: remove)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isBusy || installer == nil || !showsRemoveButton)

            SettingsActionIconButton(
                title: "settings.general.screensaver.guide.title",
                systemImage: "questionmark.circle",
                action: { showingSetupHelp.toggle() }
            )
            .popover(isPresented: $showingSetupHelp) {
                ScreensaverSetupHelpView()
                    .appLocaleEnvironment()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 细线沿用应用内下载进度的紧凑样式；钳制比例，避免任务计数切换时溢出轨道。
    private func avatarProgressBar(completed: Int, total: Int) -> some View {
        let fraction = max(0, min(1, Double(completed) / Double(total)))
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(.tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
        .accessibilityRepresentation {
            ProgressView(value: Double(completed), total: Double(total)) {
                Text("settings.general.screensaver.title")
            }
        }
    }

    private var installer: ScreensaverInstaller? {
        ScreensaverInstaller.makeProduction()
    }

    private var showsRemoveButton: Bool {
        if case .notInstalled = status { return false }
        return true
    }

    private var installButtonTitle: LocalizedStringKey {
        switch status {
        case .installed:
            return "settings.general.screensaver.openSystemInstaller"
        case .updateAvailable:
            return "settings.general.screensaver.update"
        default:
            return "settings.general.screensaver.install"
        }
    }

    private var statusText: LocalizedStringKey {
        switch status {
        case .notInstalled:
            return "settings.general.screensaver.status.notInstalled"
        case .installed:
            return "settings.general.screensaver.status.installed"
        case .updateAvailable:
            return "settings.general.screensaver.status.needsUpdate"
        }
    }

    private func refreshStatus() {
        status = installer?.status() ?? .notInstalled
    }

    /// 已安装时只重新打开系统安装器，不重复复制或下载；有更新时复用既有更新流程。
    private func performInstallAction() {
        switch status {
        case .installed:
            openWithSystemInstaller()
        case .notInstalled, .updateAvailable:
            installOrUpdate()
        }
    }

    private func installOrUpdate() {
        guard let installer else {
            errorMessage = String.l10n("settings.general.screensaver.error.install")
            return
        }
        isBusy = true
        errorMessage = nil
        do {
            try installer.install()
            refreshStatus()
            openWithSystemInstaller()
        } catch {
            errorMessage = String.l10n("settings.general.screensaver.error.install")
        }
        isBusy = false
    }

    private func openWithSystemInstaller() {
        guard let installer else { return }
        _ = installer.openWithSystemInstaller { url in
            NSWorkspace.shared.open(url)
        }
    }

    private func remove() {
        guard let installer else { return }
        isBusy = true
        errorMessage = nil
        do {
            try installer.uninstall()
            refreshStatus()
        } catch {
            errorMessage = String.l10n("settings.general.screensaver.error.remove")
        }
        isBusy = false
    }
}
