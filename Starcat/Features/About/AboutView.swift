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
    case overview
    case support
    case copyright
    case eula
    case credits
    case privacy

    var id: String { rawValue }

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .overview: return "about.nav.overview"
        case .support: return "about.nav.support"
        case .copyright: return "about.nav.copyright"
        case .eula: return "about.nav.eula"
        case .credits: return "about.nav.credits"
        case .privacy: return "about.nav.privacy"
        }
    }

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
            .frame(width: 461)
        }
        .frame(width: 680, height: 520)
        .background(.regularMaterial)
    }

    /// 用 Picker 保留 macOS 原生 segmented control 的键盘与无障碍行为。
    private var pagePicker: some View {
        Picker("", selection: $selectedPage) {
            ForEach(AboutPage.allCases) { page in
                Label(page.displayNameKey, systemImage: page.systemImage)
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

            Text("about.brand.slogan")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 18)

            SafeExternalLink(
                title: "about.brand.getSupport",
                systemImage: "lifepreserver",
                url: URL(string: "https://starcat.app/support")
            )
            .buttonStyle(.plain)
            .focusEffectDisabled()

            VStack(spacing: 8) {
                AboutBadge(title: "about.brand.badge.macos", systemImage: "desktopcomputer")
                AboutBadge(title: "about.brand.badge.localFirst", systemImage: "internaldrive")
                AboutBadge(title: "about.brand.badge.swiftNative", systemImage: "swift")
            }
            .padding(.top, 6)

            Spacer()

            Text("about.brand.copyright")
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
    let title: LocalizedStringKey
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
        AboutSection(title: "about.overview.title", subtitle: "about.overview.subtitle") {
            VStack(alignment: .leading, spacing: 14) {
                Text("about.overview.description")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    AboutFeatureCard(title: "about.overview.feature.localFirst.title", detail: "about.overview.feature.localFirst.detail", systemImage: "externaldrive")
                    AboutFeatureCard(title: "about.overview.feature.githubNative.title", detail: "about.overview.feature.githubNative.detail", systemImage: "star.circle")
                    AboutFeatureCard(title: "about.overview.feature.searchFind.title", detail: "about.overview.feature.searchFind.detail", systemImage: "magnifyingglass")
                    AboutFeatureCard(title: "about.overview.feature.aiReserved.title", detail: "about.overview.feature.aiReserved.detail", systemImage: "brain")
                }
            }
        }
    }
}

private struct SupportPage: View {
    var body: some View {
        AboutSection(title: "about.support.title", subtitle: "about.support.subtitle") {
            VStack(alignment: .leading, spacing: 12) {
                SupportRow(
                    title: "about.support.email.title",
                    detail: "about.support.email.detail",
                    systemImage: "envelope",
                    url: URL(string: "mailto:support@starcat.app")
                )
                SupportRow(
                    title: "about.support.issues.title",
                    detail: "about.support.issues.detail",
                    systemImage: "exclamationmark.bubble",
                    url: URL(string: "https://github.com/dong4j/starcat/issues")
                )
                SupportRow(
                    title: "about.support.website.title",
                    detail: "about.support.website.detail",
                    systemImage: "safari",
                    url: URL(string: "https://starcat.app")
                )

                Divider().padding(.vertical, 4)

                Text("about.support.feedbackHint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

private struct CopyrightPage: View {
    var body: some View {
        AboutSection(title: "about.copyright.title", subtitle: "about.copyright.subtitle") {
            VStack(alignment: .leading, spacing: 12) {
                AboutParagraph("about.copyright.paragraph1")
                AboutParagraph("about.copyright.paragraph2")
                AboutParagraph("about.copyright.paragraph3")
            }
        }
    }
}

private struct EULAPage: View {
    var body: some View {
        AboutSection(title: "about.eula.title", subtitle: "about.eula.subtitle") {
            VStack(alignment: .leading, spacing: 12) {
                NumberedTerm(number: "1", title: "about.eula.term1.title", text: "about.eula.term1.text")
                NumberedTerm(number: "2", title: "about.eula.term2.title", text: "about.eula.term2.text")
                NumberedTerm(number: "3", title: "about.eula.term3.title", text: "about.eula.term3.text")

                SafeExternalLink(
                    title: "about.eula.viewFull",
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
        AboutSection(title: "about.credits.title", subtitle: "about.credits.subtitle") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AboutDependency.all) { dependency in
                    DependencyRow(dependency: dependency)
                }

                Divider().padding(.vertical, 4)

                Text("about.credits.dependencyHint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
    }
}

private struct PrivacyPage: View {
    var body: some View {
        AboutSection(title: "about.privacy.title", subtitle: "about.privacy.subtitle") {
            VStack(alignment: .leading, spacing: 12) {
                PrivacyPoint(systemImage: "checkmark.shield", title: "about.privacy.whatWeStore.title", text: "about.privacy.whatWeStore.text")
                PrivacyPoint(systemImage: "xmark.shield", title: "about.privacy.whatWeWontDo.title", text: "about.privacy.whatWeWontDo.text")
                PrivacyPoint(systemImage: "icloud", title: "about.privacy.futureCloud.title", text: "about.privacy.futureCloud.text")

                SafeExternalLink(
                    title: "about.privacy.viewFull",
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
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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

            SafeExternalLink(title: "about.externalLink.open", systemImage: "arrow.up.right", url: url)
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
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
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
    let title: LocalizedStringKey
    let text: LocalizedStringKey

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
    let title: LocalizedStringKey
    let text: LocalizedStringKey

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
                    Text(verbatim: dependency.license)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }

                Text(verbatim: dependency.copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SafeExternalLink(title: "about.externalLink.source", systemImage: "arrow.up.right", url: dependency.url)
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
    let title: LocalizedStringKey
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
