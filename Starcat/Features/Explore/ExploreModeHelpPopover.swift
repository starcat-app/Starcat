//
//  ExploreModeHelpPopover.swift
//  Starcat
//
//  探索分类的数据口径说明：复用 RAG 计划面板的结构化 popover 语言，
//  让用户在侧栏即可核对每个分类的数据来源与入选规则。
//

import SwiftUI

extension ExploreMode {
    /// 动态 key 只负责固定分类的帮助文案；分类本身仍复用现有标题 key，避免两处名称分叉。
    fileprivate var helpOpenKey: String { "explore.help.\(rawValue).open" }
    fileprivate var helpSourceKey: String { "explore.help.\(rawValue).source" }

    /// 每个分类固定说明有效期、更新方式与离线处理，避免只给一个 TTL 数字却不解释过期行为。
    fileprivate var helpCacheKeys: [String] {
        [
            "explore.help.\(rawValue).cache.ttl",
            "explore.help.\(rawValue).cache.update",
            "explore.help.\(rawValue).cache.offline",
        ]
    }

    /// 入选规则按用户阅读顺序显式排列，不从后端字段名拼装，避免把内部评分器暴露给用户。
    fileprivate var helpRuleKeys: [String] {
        switch self {
        case .discover:
            return [
                "explore.help.discover.rule.catalog",
                "explore.help.discover.rule.ranking",
                "explore.help.discover.rule.scope",
            ]
        case .trending:
            return [
                "explore.help.trending.rule.period",
                "explore.help.trending.rule.meaning",
            ]
        case .popular:
            return [
                "explore.help.popular.rule.eligibility",
                "explore.help.popular.rule.threshold",
                "explore.help.popular.rule.ranking",
            ]
        case .newReleases:
            return [
                "explore.help.newReleases.rule.window",
                "explore.help.newReleases.rule.release",
                "explore.help.newReleases.rule.ranking",
            ]
        case .weekly:
            return [
                "explore.help.weekly.rule.inclusion",
                "explore.help.weekly.rule.priority",
            ]
        }
    }
}

/// 探索侧栏分类标题后的说明入口；按钮自身持有 popover 状态，不污染侧栏选择状态。
struct ExploreModeInfoButton: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let mode: ExploreMode
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(interfaceScale.font(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(LocalizedStringKey(mode.helpOpenKey))
        .accessibilityLabel(Text(LocalizedStringKey(mode.helpOpenKey)))
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            ExploreModeHelpPopover(mode: mode)
                .appLocaleEnvironment()
        }
    }
}

/// 结构化说明固定为「数据来源 → 入选规则」，与 RAG 计划帮助弹层保持同一阅读层级。
struct ExploreModeHelpPopover: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let mode: ExploreMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                sourceBlock
                rulesBlock
                cacheBlock
            }
            .padding(16)
        }
        // 入口嵌在侧栏单行标题中，会继承外层 `.lineLimit(1)`；弹层必须显式清除该环境值，
        // 否则即使正文允许垂直扩展，来源和规则仍会在第一行末尾显示省略号。
        .lineLimit(nil)
        .frame(width: 360 * interfaceScale.multiplier, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: mode.systemImage)
                .font(interfaceScale.font(.iconSmall, weight: .semibold))
                .foregroundStyle(mode.sidebarIconColor)
                .accessibilityHidden(true)
            Text(mode.titleKey)
                .font(interfaceScale.font(.panelTitle, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("explore.help.source.title")
                .font(interfaceScale.font(.captionStrong))
                .foregroundStyle(.primary)
            Text(LocalizedStringKey(mode.helpSourceKey))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rulesBlock: some View {
        keyedBulletBlock(
            titleKey: "explore.help.rules.title",
            keys: mode.helpRuleKeys
        )
    }

    private var cacheBlock: some View {
        keyedBulletBlock(
            titleKey: "explore.help.cache.title",
            keys: mode.helpCacheKeys
        )
    }

    /// 入选规则与缓存说明共用同一结构，保证标题、色点、正文和背景间距完全一致。
    private func keyedBulletBlock(
        titleKey: LocalizedStringKey,
        keys: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleKey)
                .font(interfaceScale.font(.captionStrong))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(keys, id: \.self) { key in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(mode.sidebarIconColor)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(key))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }
}
