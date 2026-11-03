//
//  BrowserExtensionSetupGuide.swift
//  Starcat
//
//  浏览器扩展安装与连接说明。仅展示操作步骤并打开原有公开仓库，
//  不执行安装、不读取凭据，也不更改本地连接状态。
//

import SwiftUI

/// 轻量说明使用自然高度的原生 sheet，避免将简单指引做成固定高度工作区。
struct BrowserExtensionSetupGuide: View {
    /// 浏览器身份同时决定说明、图标和原有源码入口，防止两种扩展链接错配。
    enum Browser: String, CaseIterable, Identifiable {
        case chrome
        case safari

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .chrome: return "settings.integration.browser.install.chrome"
            case .safari: return "settings.integration.browser.install.safari"
            }
        }

        var instructionsKey: LocalizedStringKey {
            switch self {
            case .chrome: return "settings.integration.browser.install.chromeHelp"
            case .safari: return "settings.integration.browser.install.safariHelp"
            }
        }

        /// 沿用既有插件仓库；具体安装方式由对应仓库的 README 维护。
        var repositoryURL: URL {
            switch self {
            case .chrome: return URL(string: "https://github.com/starcat-app/starcat-chrome-plugin")!
            case .safari: return URL(string: "https://github.com/starcat-app/starcat-safari-plugin")!
            }
        }
    }

    let browser: Browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(browser.rawValue)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(browser.titleKey)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                SheetCloseButton { dismiss() }
            }

            Text(browser.instructionsKey)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Spacer(minLength: 8)
                Link(destination: browser.repositoryURL) {
                    Text("settings.integration.browser.install.source")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
