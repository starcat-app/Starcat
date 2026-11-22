//
//  LinuxDoSourceBadge.swift
//  Starcat
//
//  来源事实与 Weekly/Activity 当前场景徽章并列显示。列表是纯本地标识，只有详情点击才加载帖子。
//

import SwiftUI

enum LinuxDoBadgeSource {
    case verifiedMembership
    case catalog

    func isVisible(verified: @autoclosure () -> Bool) -> Bool {
        self == .catalog || verified()
    }
}

private struct LinuxDoBadgeRequest: Equatable {
    let key: LinuxDoProvenanceKey
    let ids: [Int64]
}

private struct LinuxDoBadgeResult {
    let key: LinuxDoProvenanceKey
    let checked: Set<Int64>
    let verified: Set<Int64>
}

extension EnvironmentValues {
    @Entry fileprivate var linuxDoVerifiedSourceIDs: Set<Int64>? = nil
    @Entry var linuxDoDetailBadgeSource: LinuxDoBadgeSource = .verifiedMembership
}

/// 中栏只做一次批量 SQL 查询。扩页时旧行保留已确认状态，服务或来源版本变化后立即失效。
private struct LinuxDoSourceBadgesModifier: ViewModifier {
    let ids: [Int64]
    @Environment(AppDependencies.self) private var dependencies
    @State private var result: LinuxDoBadgeResult?

    func body(content: Content) -> some View {
        let store = dependencies.linuxDoStore
        let key = ids.isEmpty ? nil : store.provenanceKey
        let request = key.map { LinuxDoBadgeRequest(key: $0, ids: ids) }
        content
            .environment(\.linuxDoVerifiedSourceIDs, key == result?.key ? result?.verified ?? [] : [])
            .task(id: request) {
                guard let request else { return }
                let previous = result?.key == request.key ? result : nil
                let checked = previous?.checked ?? []
                let missing = Set(request.ids).subtracting(checked)
                guard !missing.isEmpty else { return }
                let verified = await store.verifiedIDs(Array(missing), key: request.key)
                guard !Task.isCancelled, store.provenanceKey == request.key else { return }
                result = LinuxDoBadgeResult(key: request.key, checked: checked.union(missing),
                                            verified: (previous?.verified ?? []).union(verified))
            }
    }
}

extension View {
    func linuxDoSourceBadges(for ids: [Int64]) -> some View {
        modifier(LinuxDoSourceBadgesModifier(ids: ids))
    }
}

/// 列表只展示来源；详情点击直接打开最新讨论，不再插入二次选择弹窗。
struct LinuxDoSourceBadge: View {
    let repoID: Int64
    var interactive = false
    var source: LinuxDoBadgeSource = .verifiedMembership
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.linuxDoVerifiedSourceIDs) private var verifiedIDs
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 13
    @State private var isOpeningDiscussion = false
    @State private var openingFailed = false
    @State private var verifiedRequest: LinuxDoBadgeRequest?

    var body: some View {
        if source.isVisible(verified: verifiedIDs?.contains(repoID) == true) {
            badgeContent
        } else if let request = individualRequest {
            Group {
                if verifiedRequest == request {
                    badgeContent
                }
            }
            .task(id: request) {
                let verified = await dependencies.linuxDoStore.verifiedIDs(request.ids, key: request.key)
                guard !Task.isCancelled else { return }
                verifiedRequest = verified.contains(repoID) ? request : nil
            }
        }
    }

    @ViewBuilder
    private var badgeContent: some View {
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
            } else {
                badge
            }
        }
        .help(Text(openingFailed ? "linuxdo.cache.unavailable" : "linuxdo.source.help"))
        .accessibilityLabel(Text("linuxdo.source.help"))
    }

    private var individualRequest: LinuxDoBadgeRequest? {
        guard source == .verifiedMembership, verifiedIDs == nil, let key = dependencies.linuxDoStore.provenanceKey else { return nil }
        return LinuxDoBadgeRequest(key: key, ids: [repoID])
    }

    /// 生命周期任务防止切换仓库后迟到的请求打开旧帖子；请求期间禁止重复点击。
    private func openDiscussion() async {
        guard isOpeningDiscussion else { return }
        defer { if !Task.isCancelled { isOpeningDiscussion = false } }
        let url = await dependencies.linuxDoStore.discussionURL(for: repoID, fromCatalog: source == .catalog)
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
