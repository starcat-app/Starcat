//
//  RepoWikiMenu.swift
//  Starcat
//
//  Repo 详情页 hero action 区的外部 Wiki 下拉入口。
//
//  设计约束：
//  - Wiki 是公开阅读能力，不依赖 GitHub 登录，也不依赖当前 repo 是否已 Star。
//  - 本组件只负责展示已确认 indexed 的链接；请求和"是否显示"由 RepoDetailScaffold
//    统一处理。
//  - 空 / 加载 / 服务错误状态不创建本组件，避免异步结果影响 window toolbar 布局。
//

import SwiftUI

/// Wiki 入口统一品牌色：indigo 族，light / dark 各一档 hex，与搜索详情 wiki chip 同族。
enum WikiAccent {
    static func foreground(colorScheme: ColorScheme) -> Color {
        Color.fromHex6(colorScheme == .dark ? 0x818CF8 : 0x4F46E5)
    }

}

/// Wiki 入口统一 SF Symbol：`doc.text.magnifyingglass` 表达「可查的外部文档」，
/// 与编程语言 / 普通书本图标区分。详情 hero `RepoWikiMenu` 与搜索卡 wikis 行共用。
struct WikiEntryIcon: View {
    var size: CGFloat = 13

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "doc.text.magnifyingglass")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(WikiAccent.foreground(colorScheme: colorScheme))
    }
}

/// 详情页 hero action 区的 Wiki 下拉菜单。
struct RepoWikiMenu: View {
    let links: [WikiLink]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        menuButton
    }

    /// 只保留图标入口；背景与同组操作一致，indigo 只用于表达 Wiki 语义。
    @ViewBuilder
    private var menuButton: some View {
        Menu {
            ForEach(links) { link in
                Link(destination: link.url) {
                    Label {
                        Text(link.title)
                    } icon: {
                        WikiSourceIcon(source: link.source)
                    }
                }
            }
        } label: {
            WikiEntryIcon(size: 13)
                .frame(width: 28, height: 28)
                .background {
                    Capsule()
                        .fill(HeroActionIconStyle.background(colorScheme: colorScheme))
                }
                .contentShape(Capsule())
                .accessibilityLabel(Text("wiki.menu.title"))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text("wiki.menu.help"))
        .fixedSize()
    }
}

/// Wiki 来源图标的统一容器。
///
/// 各家原始 logo 的“有效内容”不一致：DeepWiki 自带深色底，Zread / Code Wiki 的底座
/// 形态也不同。菜单里统一使用带 light / dark appearance 的 provider tile 资源，让
/// 外圈底座、内部标志比例和主题切换都由 asset catalog 归一化。
private struct WikiSourceIcon: View {
    private static let containerSize: CGFloat = 12
    private static let containerCornerRadius: CGFloat = 3
    private static let fallbackSymbolSize: CGFloat = 7

    let source: WikiSource

    var body: some View {
        if let assetName = providerTileAssetName {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Self.containerSize, height: Self.containerSize)
        } else {
            fallbackIcon
        }
    }

    /// 菜单专用 provider tile。不要复用 `WikiSource.assetName`：
    /// 全局 asset 保留各 provider 原始形态；菜单需要三家都有同规格底座，并随系统
    /// 亮 / 暗主题切换深浅底色。
    private var providerTileAssetName: String? {
        switch source {
        case .deepWiki:
            "WikiSources/deepwiki-menu"
        case .zread:
            "WikiSources/zread-menu"
        case .codeWiki:
            "WikiSources/codewiki-menu"
        case .unknown:
            nil
        }
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.containerCornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.containerCornerRadius, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 0.5)
                }

            Image(systemName: source.fallbackSFSymbol)
                .font(.system(size: Self.fallbackSymbolSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: Self.containerSize, height: Self.containerSize)
    }
}
