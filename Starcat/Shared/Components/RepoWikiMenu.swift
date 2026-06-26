//
//  RepoWikiMenu.swift
//  Starcat
//
//  Repo 详情页 toolbar 统一的外部 Wiki 下拉入口。
//
//  设计约束：
//  - 组件挂在当前 repo 的 window toolbar 操作组，Manage / Trending / Weekly / Activity
//    四类详情页共用。
//  - Wiki 是公开阅读能力，不依赖 GitHub 登录，也不依赖当前 repo 是否已 Star。
//  - 请求中、未收录、服务错误都不占 UI 空间；只有服务端确认 indexed 才显示菜单。
//  - `.task(id:)` 在切换 repo 时自动取消旧请求并重跑，避免旧结果串到新详情页。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.2 修订（2026-06-12，dong4j bug 反馈「按钮永远不出现」）
//  ────────────────────────────────────────────────────────────────────────────
//
//  老版 body（v1.0）：
//      Group {
//          if !links.isEmpty { Menu { ... } ... }
//      }
//      .task(id: repo.fullName) { await loadLinks() }
//
//  bug 表现：即使后端 200 + 3 个 indexed，详情页右上角始终看不到 Wiki 菜单。
//  日志里也完全没有 `wiki:` 任何字样（`.task` 闭包根本没跑过）。
//
//  根因：初始 `links == []` → `Group` 内 `if false` → body **退化为 EmptyView**。
//  SwiftUI **不会**给 EmptyView 调度 `.task` / `.onAppear`（已知坑）。形成死锁：
//      links 空 → body 是 EmptyView → .task 不跑 → loadLinks 不跑 → links 永远空
//
//  v1.1 失败尝试（已废弃）：把 `.task` 挪到 `.background { Color.clear.task(...) }` 上。
//  实测**仍然不工作** —— `.background` modifier 附加在 host view 上，当 host view 退化
//  为 EmptyView 时，整个节点（含 background modifier）一起被 SwiftUI optimizer 抹掉。
//  background 并不是"独立于 host 渲染的辅助层"。教训：don't trust intuition on
//  SwiftUI optimizer behavior，必须用真实视图节点。
//
//  v1.2 修复（当前）：用 `ZStack` 包一个**始终存在**的 `Color.clear` 子节点
//  + 条件 if 渲染 Menu。`ZStack` 是真实容器，永远有节点；`Color.clear` 是真实视图
//  （非 EmptyView），`.task` 必然被 SwiftUI 调度。代价：HStack(spacing: 8) 会把
//  ZStack 看作真实子项，links 空时仍占一个 0×0 槽位（视觉效果：Wiki 跟旁边按钮之间
//  多 8pt spacing；最坏情况是 Hero action 行整体向左挪 8pt）。这点视觉代价远小于
//  "按钮永远不显示"的体验损失。
//
//  备选方案为什么没选：
//  - 把 `.task` 上推到 RepoDetailScaffold：破坏 RepoWikiMenu 自治性，父视图要持有
//    wiki 状态机，4 个详情页都得改。
//  - `.onAppear + .onChange`：同样附加在 view 上，EmptyView 上不会触发，同样 bug。
//  - `.background` / `.overlay` modifier：v1.1 已实测无效（见上）。
//
//  教训：任何形如 `Group { if ... }.task` 的 SwiftUI 代码都要警惕这个坑，要么
//  保证 if 条件初始为 true，要么用 `ZStack { Color.clear; if ... { ... } }` 这种
//  **永远有真实子节点的容器**承载 `.task`。`.background` / `.overlay` modifier 在
//  host 为 EmptyView 时同样会被 optimizer 抹掉，不能用作 "兜底持有 .task"。
//

import SwiftUI

/// 详情页 toolbar 的 Wiki 下拉菜单。
struct RepoWikiMenu: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @State private var links: [WikiLink] = []

    var body: some View {
        // v1.2（2026-06-12）：ZStack 是真实容器永远在视图树里；Color.clear 是真实视图节点
        // （非 EmptyView），保证 .task 必然被 SwiftUI 调度。详见文件头 v1.2 修订段。
        ZStack {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            if !links.isEmpty {
                menuButton
            }
        }
        .task(id: repo.fullName) {
            await loadLinks()
        }
    }

    /// v1.3 / v1.4（2026-06-12）：按钮视觉对齐 `RepoShareButton` —— Capsule outlined +
    /// HStack(spacing: 6) + size 13 semibold + horizontal 12 / vertical 6 padding。
    /// 末尾加 `chevron.down` 提示这是个下拉菜单（macOS Menu 默认不画箭头）。
    ///
    /// **v1.4 关键修正**（2026-06-12，dong4j 截图反馈"风格不一样"）:
    /// 老版用 `.menuStyle(.borderlessButton)` —— 实测**会**把 label 当成系统默认按钮重画,
    /// 我们自定义的 Capsule background / horizontal+vertical padding / chevron.down 全部
    /// 被吃掉,导致 Wiki 按钮在视觉上是"光秃秃的图标+文字",跟旁边 [分享] / [AI] 完全不一致。
    /// 改用 `.menuStyle(.button)`(macOS 13+ 才有,但项目 macOS 15+ 没问题),它把 menu 当
    /// 自定义 button 渲染,**完整保留 label 内的所有 view 装饰**,Capsule 边框 / padding /
    /// chevron 才能正确显示出来。
    ///
    /// **教训**:macOS SwiftUI Menu 自定义 label 视觉时,**绝对不要**用
    /// `.menuStyle(.borderlessButton)`,它会无情吃掉所有自定义装饰。`.menuStyle(.button)`
    /// 才是"我自己画 label 你别动"的正确选择。
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
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("wiki.menu.title")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.primary)
            .background(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .menuStyle(.button) // v1.4 关键修正：从 .borderlessButton 改 .button，保留 label 装饰
        .menuIndicator(.hidden) // 我们自己画的 chevron.down 已经表达了"下拉"语义
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text("wiki.menu.help"))
        .fixedSize()
    }

    /// 每次 repo 变化先清掉旧菜单，随后查询单仓库状态；失败只记日志并保持隐藏。
    private func loadLinks() async {
        links = []
        do {
            let items = try await dependencies.wikiAPI.fetchStatus(owner: repo.owner, repo: repo.name)
            guard !Task.isCancelled else { return }
            links = RepoWikiMenuState.make(items: items)
        } catch is CancellationError {
            // SwiftUI 切换 repo 的正常取消，不记录成网络错误。
        } catch {
            AppLog.network.warning(
                "wiki: lookup failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Wiki 来源图标的统一容器。
///
/// 各家 logo 原图的留白、背景和边框差异很大；菜单里直接压到 10pt 会导致 DeepWiki /
/// ZRead / CodeWiki 看起来大小不一。这里固定 16pt 圆角底 + 10pt logo，让品牌图只负
/// 责识别，视觉尺寸由容器统一控制。
private struct WikiSourceIcon: View {
    let source: WikiSource

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 0.5)
                }

            if let name = source.assetName {
                Image(name)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 10, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            } else {
                Image(systemName: source.fallbackSFSymbol)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}
