//
//  LinuxDoSourceBadge.swift
//  Starcat
//
//  来源事实与 Weekly/Activity 当前场景徽章并列显示。列表是纯本地标识，只有详情点击才加载帖子。
//

import SwiftUI

/// 列表只展示来源；详情点击直接打开最新讨论，不再插入二次选择弹窗。
struct LinuxDoSourceBadge: View {
    let repoID: Int64
    var interactive = false
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 13
    @State private var isOpeningDiscussion = false
    @State private var openingFailed = false

    var body: some View {
        if dependencies.linuxDoStore.origin(for: repoID) != nil {
            Group {
                if interactive {
                    Button {
                        openingFailed = false
                        isOpeningDiscussion = true
                    } label: { badge }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .pressableHover(opacity: 0.8, scale: 1.0)
                        .clickablePointer()
                        .disabled(isOpeningDiscussion)
                        .task(id: isOpeningDiscussion) {
                            await openDiscussion()
                        }
                        .onChange(of: repoID) {
                            isOpeningDiscussion = false
                            openingFailed = false
                        }
                        .onDisappear { isOpeningDiscussion = false }
                } else { badge }
            }
            .help(Text(openingFailed ? "linuxdo.cache.unavailable" : "linuxdo.source.help"))
            .accessibilityLabel(Text("linuxdo.source.help"))
        }
    }

    /// 生命周期任务防止切换仓库后迟到的请求打开旧帖子；请求期间禁止重复点击。
    private func openDiscussion() async {
        guard isOpeningDiscussion else { return }
        defer { if !Task.isCancelled { isOpeningDiscussion = false } }
        let url = await dependencies.linuxDoStore.discussionURL(for: repoID)
        guard !Task.isCancelled else { return }
        guard let url else {
            openingFailed = true
            return
        }
        openURL(url)
    }

    @ViewBuilder
    private var badge: some View {
        if interactive {
            HStack(spacing: 4) {
                // 品牌三色不能走模板染色；明暗外圈由 Asset Catalog 自动选取。
                Image("LinuxDoLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: interfaceScale.scaled(iconSize), height: interfaceScale.scaled(iconSize))
                    .accessibilityHidden(true)
                Text(verbatim: "Linux.do")
            }
            .foregroundStyle(.primary)
            // 主文字色随主题反转，深色略加强底色与描边，避免 Hero 色底吞掉灰色胶囊。
            .modifier(RepoMetadataCapsuleStyle(
                background: Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                border: Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.18)
            ))
            .fixedSize()
        } else {
            // 品牌 SVG 保留原色并自动切换明暗资源；图标高度贴合同排徽章的文字行高。
            Image("LinuxDoLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: interfaceScale.scaled(iconSize), height: interfaceScale.scaled(iconSize))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                // 与 Stars 使用同一档中性底色，避免浅色或深色卡片吞掉胶囊边界。
                .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), in: Capsule())
                .fixedSize()
        }
    }
}
