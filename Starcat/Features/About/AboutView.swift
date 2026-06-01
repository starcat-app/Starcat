//
//  AboutView.swift
//  Starcat
//
//  Starcat 自定义关于页主视图。
//
//  设计目标：
//  - 比系统标准 About Panel 信息密度更高，能承载支持、协议、隐私和开源致谢。
//  - 继续保持 macOS 原生质感，使用系统颜色、Material、SF Symbol 和 App Icon。
//  - 所有外部链接集中走 SafeExternalLink，避免在页面正文里散落 NSWorkspace 调用。
//

import AppKit
import SwiftUI

/// 关于窗口的页面选择。
private enum AboutPage: String, CaseIterable, Identifiable {
    case overview = "概览"
    case support = "支持"
    case copyright = "版权"
    case eula = "EULA"
    case credits = "致谢"
    case privacy = "隐私"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "sparkles"
        case .support: return "questionmark.circle"
        case .copyright: return "c.circle"
        case .eula: return "doc.text"
        case .credits: return "heart"
        case .privacy: return "lock.shield"
        }
    }
}

/// 关于窗口主视图。
struct AboutView: View {

    @State private var selectedPage: AboutPage = .overview

    var body: some View {
        HStack(spacing: 0) {
            AboutBrandPanel()

            Divider()

            VStack(spacing: 0) {
                pagePicker
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 14)

                Divider()

                ScrollView {
                    AboutPageContent(page: selectedPage)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.52))
            }
        }
        .frame(width: 680, height: 520)
        .background(.regularMaterial)
    }

    /// 用 Picker 保留 macOS 原生 segmented control 的键盘与无障碍行为。
    private var pagePicker: some View {
        Picker("关于页面", selection: $selectedPage) {
            ForEach(AboutPage.allCases) { page in
                Label(page.rawValue, systemImage: page.systemImage)
                    .tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

// MARK: - 左侧品牌区

/// 左侧品牌信息面板。
private struct AboutBrandPanel: View {

    private let version = AboutVersion.current

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            appIcon

            VStack(spacing: 6) {
                Text("Starcat")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text(version.fullText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text("把 GitHub Stars 变成可搜索、可整理、可长期维护的开发者知识库。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 18)

            SafeExternalLink(
                title: "获取支持",
                systemImage: "lifepreserver",
                url: URL(string: "https://starcat.app/support")
            )
            .buttonStyle(.plain)
            .focusEffectDisabled()

            VStack(spacing: 8) {
                AboutBadge(title: "macOS 15+", systemImage: "desktopcomputer")
                AboutBadge(title: "Local First", systemImage: "internaldrive")
                AboutBadge(title: "SwiftUI Native", systemImage: "swift")
            }
            .padding(.top, 6)

            Spacer()

            Text("Copyright © 2026 Starcat.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(width: 218)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.16),
                    Color(nsColor: .windowBackgroundColor).opacity(0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.34), lineWidth: 1)
            }
    }
}

/// 品牌区的小徽章。
private struct AboutBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }
}

// MARK: - 内容区

/// 根据当前选择渲染不同页面。
private struct AboutPageContent: View {
    let page: AboutPage

    var body: some View {
        Group {
            switch page {
            case .overview:
                OverviewPage()
            case .support:
                SupportPage()
            case .copyright:
                CopyrightPage()
            case .eula:
                EULAPage()
            case .credits:
                CreditsPage()
            case .privacy:
                PrivacyPage()
            }
        }
        .animation(.snappy(duration: 0.18), value: page)
    }
}

private struct OverviewPage: View {
    var body: some View {
        AboutSection(title: "Starcat 是什么", subtitle: "一个本地优先的 GitHub Star 管理工具") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Starcat 将扁平的 GitHub 收藏转化为可搜索、可打标签、可写私有笔记的知识库。MVP 阶段优先保证本地数据可靠、阅读体验顺滑，再逐步接入 AI 摘要与标签推荐。")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    AboutFeatureCard(title: "本地优先", detail: "Tags、Notes、Status 写入本地 SQLite，repo 缓存可重建。", systemImage: "externaldrive")
                    AboutFeatureCard(title: "GitHub 原生", detail: "同步 Stars、README、Release 与仓库元数据。", systemImage: "star.circle")
                    AboutFeatureCard(title: "搜索找回", detail: "FTS5 全文检索，按语言、标签和状态过滤。", systemImage: "magnifyingglass")
                    AboutFeatureCard(title: "AI 预留", detail: "摘要、标签建议和语义搜索都采用用户确认后写入。", systemImage: "brain")
                }
            }
        }
    }
}

private struct SupportPage: View {
    var body: some View {
        AboutSection(title: "获取帮助", subtitle: "遇到问题时优先保留现场信息，便于快速定位") {
            VStack(alignment: .leading, spacing: 12) {
                SupportRow(
                    title: "邮件支持",
                    detail: "support@starcat.app",
                    systemImage: "envelope",
                    url: URL(string: "mailto:support@starcat.app")
                )
                SupportRow(
                    title: "GitHub Issues",
                    detail: "提交复现步骤、截图和 Console 日志",
                    systemImage: "exclamationmark.bubble",
                    url: URL(string: "https://github.com/dong4j/starcat/issues")
                )
                SupportRow(
                    title: "产品主页",
                    detail: "查看更新说明与帮助文档",
                    systemImage: "safari",
                    url: URL(string: "https://starcat.app")
                )

                Divider().padding(.vertical, 4)

                Text("建议反馈问题时附上：Starcat 版本、macOS 版本、是否刚完成同步、可复现的操作路径。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

private struct CopyrightPage: View {
    var body: some View {
        AboutSection(title: "版权声明", subtitle: "Starcat 与相关服务的权利归属") {
            VStack(alignment: .leading, spacing: 12) {
                AboutParagraph("Copyright © 2026 Starcat. All rights reserved.")
                AboutParagraph("Starcat 名称、图标和界面设计受版权和商标相关法律保护。未经明确书面授权，不得复制、分发、出售或以其它方式重新发布本软件。")
                AboutParagraph("GitHub 是 GitHub, Inc. 的注册商标。Apple、macOS 和 Swift 是 Apple Inc. 的商标。Starcat 与上述公司不存在从属或背书关系。")
            }
        }
    }
}

private struct EULAPage: View {
    var body: some View {
        AboutSection(title: "最终用户许可协议", subtitle: "这里展示摘要，正式分发前应补齐完整法律文本") {
            VStack(alignment: .leading, spacing: 12) {
                NumberedTerm(number: "1", title: "许可授予", text: "Starcat 授予您有限、非独占、不可转让的许可，用于在您拥有或控制的 Apple 设备上安装和使用本软件。")
                NumberedTerm(number: "2", title: "限制", text: "除适用法律明确允许外，您不得反向工程、再分发、出租、出售或移除本软件中的版权与许可声明。")
                NumberedTerm(number: "3", title: "数据责任", text: "GitHub token、标签、笔记和缓存数据属于用户数据。请在清理缓存、取消 Star 或导入导出前自行确认操作影响。")

                SafeExternalLink(
                    title: "查看完整协议",
                    systemImage: "arrow.up.right.square",
                    url: URL(string: "https://starcat.app/eula")
                )
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.top, 4)
            }
        }
    }
}

private struct CreditsPage: View {
    var body: some View {
        AboutSection(title: "开源致谢", subtitle: "Starcat 建立在这些优秀的 Swift 生态项目之上") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AboutDependency.all) { dependency in
                    DependencyRow(dependency: dependency)
                }

                Divider().padding(.vertical, 4)

                Text("感谢所有开源维护者。Starcat 只列出当前工程直接依赖；如果后续新增 SPM package，请同步更新这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

private struct PrivacyPage: View {
    var body: some View {
        AboutSection(title: "隐私政策", subtitle: "本地优先是 Starcat 的核心边界") {
            VStack(alignment: .leading, spacing: 12) {
                PrivacyPoint(systemImage: "checkmark.shield", title: "我们会存储什么", text: "GitHub OAuth token、仓库缓存、标签、私有笔记和阅读状态。MVP 阶段这些数据保存在本机。")
                PrivacyPoint(systemImage: "xmark.shield", title: "我们不会做什么", text: "不会出售个人信息，不会把本地笔记用于广告，也不会在未经确认时自动把 AI 建议写回用户数据。")
                PrivacyPoint(systemImage: "icloud", title: "未来云同步", text: "CloudKit 同步只用于用户自己的 iCloud 容器，发布前会在设置页提供明确开关与数据管理入口。")

                SafeExternalLink(
                    title: "查看完整隐私政策",
                    systemImage: "arrow.up.right.square",
                    url: URL(string: "https://starcat.app/privacy")
                )
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - 共享组件

private struct AboutSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}

private struct AboutFeatureCard: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26, alignment: .leading)

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct SupportRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let url: URL?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SafeExternalLink(title: "打开", systemImage: "arrow.up.right", url: url)
                .buttonStyle(.plain)
                .focusEffectDisabled()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct AboutParagraph: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NumberedTerm: View {
    let number: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

private struct PrivacyPoint: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

private struct DependencyRow: View {
    let dependency: AboutDependency

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(dependency.name)
                        .font(.headline)
                    Text(dependency.license)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }

                Text(dependency.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SafeExternalLink(title: "源码", systemImage: "arrow.up.right", url: dependency.url)
                .buttonStyle(.plain)
                .focusEffectDisabled()
        }
        .padding(.vertical, 8)
    }
}

/// 外部链接按钮。
///
/// 这里只接受调用方传入的 URL，内部统一用 NSWorkspace 打开，便于后续加 URL 白名单或埋点。
private struct SafeExternalLink: View {
    let title: String
    let systemImage: String
    let url: URL?

    var body: some View {
        Button {
            guard let url else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(.quaternary, lineWidth: 1)
                }
        }
        .disabled(url == nil)
        .help(url?.absoluteString ?? "")
    }
}

// MARK: - 数据模型

/// About 页展示的版本信息。
private struct AboutVersion {
    let marketing: String
    let build: String

    static var current: AboutVersion {
        let dictionary = Bundle.main.infoDictionary
        return AboutVersion(
            marketing: dictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            build: dictionary?["CFBundleVersion"] as? String ?? "1"
        )
    }

    var fullText: String {
        "Version \(marketing) (Build \(build))"
    }
}

/// 第三方依赖展示项。
private struct AboutDependency: Identifiable {
    let name: String
    let license: String
    let copyright: String
    let url: URL?

    var id: String { name }

    static let all: [AboutDependency] = [
        AboutDependency(
            name: "GRDB.swift",
            license: "MIT",
            copyright: "Copyright (c) 2015-2024 Gwendal Rouard",
            url: URL(string: "https://github.com/groue/GRDB.swift")
        ),
        AboutDependency(
            name: "KeychainAccess",
            license: "MIT",
            copyright: "Copyright (c) 2014-2024 Kishikawa Katsumi",
            url: URL(string: "https://github.com/kishikawakatsumi/KeychainAccess")
        ),
        AboutDependency(
            name: "Kingfisher",
            license: "MIT",
            copyright: "Copyright (c) 2019 Wei Wang",
            url: URL(string: "https://github.com/onevcat/Kingfisher")
        )
    ]
}
