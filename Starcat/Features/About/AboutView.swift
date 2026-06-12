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
    case eula
    case credits
    case privacy
    case copyright

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
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                Divider()

                ScrollView {
                    AboutPageContent(page: selectedPage)
                        .padding(24)
                        .frame(minHeight: 328, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.52))
            }
            .frame(minWidth: 461, maxWidth: .infinity)
        }
        .frame(minWidth: 680, minHeight: 450)
        .background(.regularMaterial)
    }

    /// 用 Picker 保留 macOS 原生 segmented control 的键盘与无障碍行为。
    private var pagePicker: some View {
        Picker("", selection: $selectedPage) {
            ForEach(AboutPage.allCases) { page in
                // 这里刻意只放文字：macOS segmented control 放图标后会显得更像自绘 tab，
                // 也更容易撑高 About 窗口顶部 chrome。
                Text(page.displayNameKey)
                    .tag(page)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .labelsHidden()
    }
}

// MARK: - 左侧品牌区

/// 左侧品牌信息面板。
private struct AboutBrandPanel: View {

    private let version = AboutVersion.current

    var body: some View {
        VStack(spacing: 16) {
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

            VStack(spacing: 9) {
                AboutBadge(title: "about.brand.badge.macos", systemImage: "desktopcomputer")
                AboutBadge(title: "about.brand.badge.localFirst", systemImage: "internaldrive")
                AboutBadge(title: "about.brand.badge.swiftNative", systemImage: "swift")
            }
            .padding(.top, 4)
        }
        .frame(width: 218)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 38)
        .background(AboutBrandAnimatedBackground())
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 128, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
    }
}

/// 左侧品牌区的淡渐变背景。
///
/// 这层以 App Icon 附近为中心做低透明度黄色柔光，而不是整块线性渐变。
/// 这样四周会自然衰减，不会在窗口顶部形成明显色彩分隔线。
/// 开启“减少动态效果”时退化为静态背景。
private struct AboutBrandAnimatedBackground: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isAnimating = false

    private let starGold = Color(red: 1.0, green: 0.74, blue: 0.28)

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.62)

            GeometryReader { proxy in
                let size = proxy.size
                let iconCenterOffsetY = min(size.height * 0.24, 98) - size.height * 0.5

                ZStack {
                    animatedGlow(
                        color: starGold.opacity(0.13),
                        diameter: size.width * 1.9,
                        offset: CGPoint(
                            x: isAnimating ? 10 : -8,
                            y: iconCenterOffsetY + (isAnimating ? 8 : -10)
                        )
                    )

                    animatedGlow(
                        color: starGold.opacity(0.08),
                        diameter: size.width * 2.35,
                        offset: CGPoint(
                            x: isAnimating ? -16 : 14,
                            y: iconCenterOffsetY + (isAnimating ? -12 : 10)
                        )
                    )
                }
                .blur(radius: 34)
                .animation(reduceMotion ? nil : .easeInOut(duration: 9).repeatForever(autoreverses: true), value: isAnimating)
                .onAppear {
                    guard !reduceMotion else { return }
                    isAnimating = true
                }
                .onChange(of: reduceMotion) { _, newValue in
                    isAnimating = !newValue
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    private func animatedGlow(color: Color, diameter: CGFloat, offset: CGPoint) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color,
                        color.opacity(0.45),
                        color.opacity(0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .offset(x: offset.x, y: offset.y)
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
            .labelStyle(.titleAndIcon)
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
            VStack(alignment: .leading, spacing: 12) {
                Text("about.overview.description")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
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

                HStack {
                    Spacer()

                    SafeExternalLink(
                        title: "about.eula.viewFull",
                        systemImage: "arrow.up.right.square",
                        url: URL(string: "https://starcat.app/eula")
                    )
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct CreditsPage: View {
    var body: some View {
        AboutSection(title: "about.credits.title", subtitle: "about.credits.subtitle") {
            VStack(alignment: .leading, spacing: 10) {
                CreditsList(dependencies: AboutDependency.all)

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

                HStack {
                    Spacer()

                    SafeExternalLink(
                        title: "about.privacy.viewFull",
                        systemImage: "arrow.up.right.square",
                        url: URL(string: "https://starcat.app/privacy")
                    )
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
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
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
                .tint(.accentColor)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                // 四个卡片固定同高：短文案也预留两行高度，避免左右列底部不齐。
                .frame(minHeight: 32, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                // 固定 36pt 图标槽，后续替换成真实项目 logo 时仍能保持上下居中。
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: dependency.name)
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

            // 致谢页空间紧凑，且每行已经显示了项目名/许可证/版权，链接只需一个跳转图标即可。
            // 文本由 Label 的 title 承担无障碍语义（labelStyle(.iconOnly) 仅隐藏视觉文本）。
            SafeExternalLink(
                title: "about.externalLink.source",
                systemImage: "arrow.up.right",
                url: dependency.url,
                iconOnly: true
            )
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 致谢页中部的依赖列表。
///
/// 依赖项较多（>10 条），整页滚动会让其它信息区被挤出视野，因此这里独立成一个固定高度的滚动容器，
/// 由用户手动滚动浏览。早期版本曾加过基于 Timer 的自动轮播，但实际使用中干扰复制/点击操作，已移除。
private struct CreditsList: View {
    let dependencies: [AboutDependency]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(dependencies.enumerated()), id: \.element.id) { index, dependency in
                    DependencyRow(dependency: dependency)

                    if index != dependencies.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(height: 168)
        .scrollIndicators(.visible)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}

/// 外部链接按钮。
///
/// 这里只接受调用方传入的 URL，内部统一用 NSWorkspace 打开，便于后续加 URL 白名单或埋点。
///
/// 形态：
/// - 默认胶囊（icon + 文本），用于品牌区/EULA/Privacy 等需要文案引导的场景。
/// - `iconOnly = true` 时退化为圆形图标按钮，用于致谢列表这种空间紧凑、上下文已说明用途的场景；
///   仍保留 Label 的 title 以保证 VoiceOver 能正确读出按钮含义。
private struct SafeExternalLink: View {
    let title: LocalizedStringKey
    let systemImage: String
    let url: URL?
    var iconOnly: Bool = false

    var body: some View {
        Button {
            guard let url else { return }
            NSWorkspace.shared.open(url)
        } label: {
            if iconOnly {
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .font(.callout.weight(.medium))
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.quaternary, lineWidth: 1)
                    }
            } else {
                Label(title, systemImage: systemImage)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().stroke(.quaternary, lineWidth: 1)
                    }
            }
        }
        .disabled(url == nil)
        .help(Text(verbatim: url?.absoluteString ?? ""))
    }
}

// MARK: - 数据模型

/// About 页展示的版本信息。
///
/// 三个字段全部来自 `Info.plist`，由 `scripts/bump-version.sh`（postBuildScripts）从 git 元数据动态写入：
///   - `marketing`  ← `CFBundleShortVersionString`：最新 git tag（无 tag 时退到 project.yml 兜底 `0.1.0`）
///   - `build`      ← `CFBundleVersion`：git commit 总数（纯整数，符合 App Store 规范）
///   - `gitHash`    ← `GitCommitHash`：7 位短 hash（项目自定义 key，App Review 不审）
///
/// UI 展示规则：拿到 hash 时拼成 `Version 0.1.0 (Build 201.f09a499)`，缺 hash 时降级到 `Version 0.1.0 (Build 201)`，
/// 让脚本未跑 / 非 git 仓库等异常路径仍能展示出可读版本号。
private struct AboutVersion {
    let marketing: String
    let build: String
    let gitHash: String?

    static var current: AboutVersion {
        let dictionary = Bundle.main.infoDictionary
        let rawHash = dictionary?["GitCommitHash"] as? String
        // 空串视为缺失（脚本退化路径或老 build），统一走降级分支。
        let normalizedHash = rawHash?.trimmingCharacters(in: .whitespaces).isEmpty == false ? rawHash : nil
        return AboutVersion(
            marketing: dictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            build: dictionary?["CFBundleVersion"] as? String ?? "1",
            gitHash: normalizedHash
        )
    }

    /// 关于页展示用的完整 build 字符串：有 hash 拼 `<count>.<hash>`，没有就只显示 `<count>`。
    /// 这样本地化字符串 `about.version.fullFormat`（仍是 `Version %@ (Build %@)`）无需修改，
    /// 拼接逻辑全部收敛在 Swift 侧，便于以后加 `.dirty` 后缀等扩展时只动这一处。
    var displayBuild: String {
        guard let hash = gitHash, !hash.isEmpty else { return build }
        return "\(build).\(hash)"
    }

    var fullText: String {
        String(format: String(localized: "about.version.fullFormat"), marketing, displayBuild)
    }
}

/// 第三方依赖展示项。
///
/// 维护规则（强制，2026-06-07 起生效）：
/// 凡是 Starcat 集成的外部开源项目（SPM 依赖 / 嵌入式资源 / 通过脚本嵌入的代码或数据），
/// 都必须在这里追加一条记录，确保关于页 → 开源致谢列表与实际工程一一对应。
/// 详细规则见 `AGENTS.md` / `CLAUDE.md` 的「开源致谢同步规则」章节。
private struct AboutDependency: Identifiable {
    let name: String
    let license: String
    let copyright: String
    let url: URL?

    var id: String { name }

    static let all: [AboutDependency] = [
        // MARK: SPM 依赖（与 project.yml `packages` 一一对应）

        AboutDependency(
            name: "GRDB.swift",
            license: "MIT",
            copyright: "Copyright (c) 2015-2026 Gwendal Roué",
            url: URL(string: "https://github.com/groue/GRDB.swift")
        ),
        AboutDependency(
            name: "KeychainAccess",
            license: "MIT",
            copyright: "Copyright (c) 2014-2026 Kishikawa Katsumi",
            url: URL(string: "https://github.com/kishikawakatsumi/KeychainAccess")
        ),
        AboutDependency(
            name: "Kingfisher",
            license: "MIT",
            copyright: "Copyright (c) 2019 Wei Wang",
            url: URL(string: "https://github.com/onevcat/Kingfisher")
        ),
        AboutDependency(
            name: "swift-markdown-ui",
            license: "MIT",
            copyright: "Copyright (c) 2020 Guillermo Gonzalez",
            url: URL(string: "https://github.com/gonzalezreal/swift-markdown-ui")
        ),
        AboutDependency(
            name: "OpenAI",
            license: "MIT",
            copyright: "Copyright (c) 2023 MacPaw Inc.",
            url: URL(string: "https://github.com/MacPaw/OpenAI")
        ),
        AboutDependency(
            name: "ConfettiSwiftUI",
            license: "MIT",
            copyright: "Copyright (c) 2020 Simon Bachmann",
            url: URL(string: "https://github.com/simibac/ConfettiSwiftUI")
        ),

        // MARK: 嵌入式资源 / 生成代码（非 SPM，但同样属于第三方开源）

        AboutDependency(
            name: "Devicon",
            license: "MIT",
            copyright: "Copyright (c) 2015 konpa",
            url: URL(string: "https://github.com/devicons/devicon")
        ),
        AboutDependency(
            name: "GitHub Linguist",
            license: "MIT",
            copyright: "Copyright (c) 2017 GitHub, Inc.",
            url: URL(string: "https://github.com/github/linguist")
        ),
        AboutDependency(
            name: "ruanyf/weekly",
            license: "CC BY-NC-SA 4.0",
            copyright: "Copyright (c) Ruanyifeng",
            url: URL(string: "https://github.com/ruanyf/weekly")
        ),

        // MARK: 第三方品牌标识（非开源代码，但仍登记以保持透明）
        //
        // 外部来源品牌 logo 嵌入在 `Assets.xcassets/WikiSources/`（Wiki 菜单）与
        // `Assets.xcassets/WeeklySources/`（Weekly 三源 feed）下,用于来源识别。
        // 它们是各品牌的商标 / 品牌资产,Starcat 仅作"识别用图"展示,不主张所有权,
        // license 字段标记为 "Brand Asset"。
        // 严格按 CLAUDE.md「开源致谢同步规则」第 2 条「嵌入式资源」登记。

        AboutDependency(
            name: "DeepWiki Logo",
            license: "Brand Asset",
            copyright: "Cognition Labs, Inc. — used for source identification only",
            url: URL(string: "https://deepwiki.com")
        ),
        AboutDependency(
            name: "Zread Logo",
            license: "Brand Asset",
            copyright: "Zread.ai — used for source identification only",
            url: URL(string: "https://zread.ai")
        ),
        AboutDependency(
            name: "ZRead",
            license: "Brand Asset",
            copyright: "Zread.ai — used for weekly source identification only",
            url: URL(string: "https://zread.ai")
        ),
        AboutDependency(
            name: "Hacker News",
            license: "Brand Asset",
            copyright: "Y Combinator — used for source identification only",
            url: URL(string: "https://news.ycombinator.com")
        ),
        AboutDependency(
            name: "Code Wiki Logo",
            license: "Brand Asset",
            copyright: "Google LLC — used for source identification only",
            url: URL(string: "https://codewiki.google")
        )
    ]
}
