//
//  ExternalLinksMenu.swift
//  Starcat
//
//  顶部 toolbar 「在 GitHub 打开 / 复制 clone URL」下拉菜单。
//
//  原归属：`RepoListView.externalLinksMenu(repo:)`（仅 Manage 路径，闭包内直接读
//  `viewModel.selectedRepo`）。W12 toolbar 专项 PR-1 抽出到本组件，由调用方传入
//  `ToolbarRepoSelection`，让 Trending / Weekly / Activity 也能直接复用。
//
//  2026-09-03：原独立 `CloneMenu`（link.circle）并入本菜单末尾独立分区，减少
//  toolbar 图标占用；复制成功 toast 仍由调用方通过 `onCloneCopied` 弹出。
//
//  关键约束：
//  - 主操作（primaryAction）= 打开 repo 主页；菜单内的 issues / pulls / releases /
//    homepage 都是辅助跳转，按 GitHub 子页面规则纯字符串拼，所以 trending /
//    weekly 这种没有本地 Repo 对象的场景也能用。
//  - CodeFlow 需要完整 `Repo` 才能下载 ZIP，因此仅 Manage 公开仓库传入
//    `codeFlowRepo`。它是主推功能，固定放在菜单第一组；无 CodeFlow 时走标准 Menu。
//  - clone HTTPS / Git SSH 固定在菜单最后一组：只展示协议名、不展示完整 URL，
//    长 URL 会撑宽菜单；URL 已在 `ToolbarRepoSelection` 构造时算好。
//  - homepage 现在 4 场景都可能有值：Manage 走 Repo.homepage / Trending 走
//    TrendingRepo.homepage（R-05 起 trending-api enricher 已拉满）/ Weekly 走
//    WeeklyFeedItem.card.homepage / Activity-repo-backed 走本地 Repo.homepage。
//    selection 没拼出有效 URL 时整组隐藏 Divider，避免单独剩一条 homepage。
//  - **Homepage Button label 必须只放一个 Label，不要追加 Text(homepage.absoluteString)**：
//    SwiftUI Menu Button 的 label slot 收多视图时会竖排，导致 ① house 图标相对整块
//    内容居中而错位（Manage 图 1 表现）② 长 URL 撑出大空隙（Activity 图 2 表现）。
//    dong4j 2026-06-12 验收要求菜单项**不展示 URL**，跳转目标由 Tooltip 化或
//    primaryAction 配合 hover 状态展示，菜单项纯粹保留语义入口。
//

import SwiftUI
import AppKit

/// 顶部 toolbar 「在 GitHub 打开」菜单（含复制 clone URL）。
///
/// `selection` 由调用方按当前页面选中项构造；nil 时菜单整组隐藏（toolbar 调用方
/// 在外层自己 `if let selection { ... }`，本组件不再做 nil 守卫，让职责更纯）。
struct ExternalLinksMenu: View {

    let selection: ToolbarRepoSelection
    let codeFlowRepo: Repo?
    let codebaseMemoryRepo: Repo?
    /// 由稳定的页面根视图承载 CodeFlow sheet；toolbar 组件只发送打开请求。
    ///
    /// 历史坑（dong4j 2026-06-14 验收反馈）：原本用 `@State isCodeFlowPresented: Bool`
    /// + `.sheet(isPresented:)`，从 toolbar 打开 CodeFlow 再点右上角 ✕ 关闭时，
    /// sheet 会"关闭 → 短暂再次出现 → 再关闭"。
    ///
    /// 根因：本组件嵌在 `RepoListView` toolbar trailing 闭包里，会随
    /// `viewModel.selectedRepo` / `starredRegistry` / `authSession` 等任意状态变化
    /// 被频繁重建。`dismiss()` 触发 sheet 关闭时，SwiftUI 内部 sheet state 与外部
    /// `$isCodeFlowPresented` binding 的更新存在 1 帧时序差；这一帧里如果父视图正好
    /// 重建，**新创建的 binding 实例**让 sheet "复活" 1 帧后才真正关闭 —— 视觉上就是闪现一次。
    ///
    /// 仅把 Bool 改成 item 仍不够：如果 `.sheet(item:)` 继续挂在 toolbar 子树上，
    /// `AnyView` 重建时 presentation host 本身仍会被替换，关闭期间可能再次挂载。
    /// 因此由 `RepoListView` 持有 item 并在稳定根节点呈现，本组件不保存 sheet 状态。
    let onOpenCodeFlow: (Repo) -> Void
    let onOpenCodebaseMemory: (Repo) -> Void
    /// 复制 clone URL 成功后的 toast key；由调用方挂稳定 toast，避免本组件持有 @State。
    let onCloneCopied: (String) -> Void

    init(
        selection: ToolbarRepoSelection,
        codeFlowRepo: Repo? = nil,
        codebaseMemoryRepo: Repo? = nil,
        onOpenCodeFlow: @escaping (Repo) -> Void = { _ in },
        onOpenCodebaseMemory: @escaping (Repo) -> Void = { _ in },
        onCloneCopied: @escaping (String) -> Void = { _ in }
    ) {
        self.selection = selection
        self.codeFlowRepo = codeFlowRepo
        self.codebaseMemoryRepo = codebaseMemoryRepo
        self.onOpenCodeFlow = onOpenCodeFlow
        self.onOpenCodebaseMemory = onOpenCodebaseMemory
        self.onCloneCopied = onCloneCopied
    }

    var body: some View {
        let currentCodeFlowRepo = codeFlowRepo
        let currentCodebaseMemoryRepo = codebaseMemoryRepo

        Group {
            if codeFlowRepo != nil || codebaseMemoryRepo != nil {
                FeaturedExternalLinksControl(
                    selection: selection,
                    onOpenCodeFlow: {
                        if let repo = currentCodeFlowRepo {
                            AppLog.ui.info("Toolbar CodeFlow action selection=\(selection.fullName, privacy: .public) repo=\(repo.fullName, privacy: .public) id=\(repo.id, privacy: .public)")
                            onOpenCodeFlow(repo)
                        }
                    },
                    codebaseMemoryRepo: currentCodebaseMemoryRepo,
                    onOpenCodebaseMemory: {
                        if let repo = currentCodebaseMemoryRepo {
                            AppLog.ui.info("Toolbar CodebaseMemory action selection=\(selection.fullName, privacy: .public) repo=\(repo.fullName, privacy: .public) id=\(repo.id, privacy: .public)")
                            onOpenCodebaseMemory(repo)
                        }
                    },
                    onCloneCopied: onCloneCopied
                )
                .id(featuredControlIdentity)
            } else {
                standardMenu
            }
        }
        .help("externalLinks.hint")
    }

    /// 没有 CodeFlow 的场景保持系统 Menu，避免为了统一外观扩大自绘范围。
    private var standardMenu: some View {
        Menu {
            Button {
                open(RepoExternalLinks.issues(owner: selection.owner, name: selection.name))
            } label: {
                Label("externalLinks.issues", systemImage: "exclamationmark.bubble")
            }

            Button {
                open(RepoExternalLinks.pulls(owner: selection.owner, name: selection.name))
            } label: {
                Label("externalLinks.pullRequests", systemImage: "arrow.triangle.pull")
            }

            Button {
                open(RepoExternalLinks.releases(owner: selection.owner, name: selection.name))
            } label: {
                Label("externalLinks.releases", systemImage: "tag.circle")
            }

            if let homepage = selection.homepage {
                Divider()
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Label("externalLinks.homepage", systemImage: "house")
                }
            }

            CloneURLMenuSection(selection: selection, onCloneCopied: onCloneCopied)
        } label: {
            ToolbarIcon("safari")
                .accessibilityLabel("externalLinks.openOnGithub")
        } primaryAction: {
            open(selection.htmlUrl)
        }
    }

    private func open(_ url: URL?) {
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    /// AppKit `Menu` 会跨 SwiftUI body 重算复用内部 action；identity 包含当前 repo
    /// 快照，避免切换选中仓库后菜单项仍调用上一次 repo 的闭包。
    private var featuredControlIdentity: String {
        let codeFlowIdentity = codeFlowRepo.map { "\($0.id):\($0.fullName)" } ?? "none"
        let codebaseIdentity = codebaseMemoryRepo.map { "\($0.id):\($0.fullName)" } ?? "none"
        return "\(selection.fullName)|cf=\(codeFlowIdentity)|cb=\(codebaseIdentity)"
    }
}

/// Manage 公共仓库使用的外链控制器。
///
/// Safari 主按钮保留“直接打开仓库”的 primaryAction；chevron 打开同一 Menu，
/// 内含 CodeFlow / CodebaseMemory、GitHub 子页、以及末尾的 clone URL 复制项。
private struct FeaturedExternalLinksControl: View {
    let selection: ToolbarRepoSelection
    let onOpenCodeFlow: () -> Void
    let codebaseMemoryRepo: Repo?
    let onOpenCodebaseMemory: () -> Void
    let onCloneCopied: (String) -> Void

    var body: some View {
        Menu {
            Button {
                onOpenCodeFlow()
            } label: {
                Label {
                    Text("CodeFlow")
                } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
            }

            if codebaseMemoryRepo != nil {
                Button {
                    onOpenCodebaseMemory()
                } label: {
                    Label {
                        Text("CodebaseMemory")
                    } icon: {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    }
                }
            }

            Divider()

            Button {
                open(RepoExternalLinks.issues(owner: selection.owner, name: selection.name))
            } label: {
                Label("externalLinks.issues", systemImage: "exclamationmark.bubble")
            }

            Button {
                open(RepoExternalLinks.pulls(owner: selection.owner, name: selection.name))
            } label: {
                Label("externalLinks.pullRequests", systemImage: "arrow.triangle.pull")
            }

            Button {
                open(RepoExternalLinks.releases(owner: selection.owner, name: selection.name))
            } label: {
                Label("externalLinks.releases", systemImage: "tag.circle")
            }

            if let homepage = selection.homepage {
                Divider()
                Button {
                    NSWorkspace.shared.open(homepage)
                } label: {
                    Label("externalLinks.homepage", systemImage: "house")
                }
            }

            CloneURLMenuSection(selection: selection, onCloneCopied: onCloneCopied)
        } label: {
            ToolbarIcon("safari")
                .accessibilityLabel("externalLinks.openOnGithub")
        } primaryAction: {
            open(selection.htmlUrl)
        }
    }

    private func open(_ url: URL?) {
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 外链菜单末尾的 clone URL 分区（原独立 `CloneMenu` 的两项）。
///
/// 做成 View 而非自由函数：Swift 6 下 Menu Button 闭包是 main-actor，自由函数
/// 参数上的 `@escaping` 回调会被判为 task-isolated，触发 sending 数据竞争报错。
private struct CloneURLMenuSection: View {
    let selection: ToolbarRepoSelection
    let onCloneCopied: (String) -> Void

    var body: some View {
        Divider()

        Button {
            copy(selection.cloneHTTPS, toastKey: "clone.copiedHttps")
        } label: {
            Label("clone.https", systemImage: "globe")
        }

        Button {
            copy(selection.cloneSSH, toastKey: "clone.copiedGit")
        } label: {
            Label("clone.git", systemImage: "terminal")
        }
    }

    private func copy(_ string: String, toastKey: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        onCloneCopied(toastKey)
    }
}

/// 可完整控制视觉样式的 CodeFlow 主推菜单面板。
private struct ExternalLinksPopover: View {
    let selection: ToolbarRepoSelection
    let onOpenCodeFlow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            CodeFlowFeaturedTile(action: onOpenCodeFlow)

            Divider()
                .padding(.horizontal, 4)

            ExternalLinkPopoverRow(
                titleKey: "externalLinks.issues",
                systemImage: "exclamationmark.bubble",
                url: RepoExternalLinks.issues(owner: selection.owner, name: selection.name),
                onDismiss: onDismiss
            )
            ExternalLinkPopoverRow(
                titleKey: "externalLinks.pullRequests",
                systemImage: "arrow.triangle.pull",
                url: RepoExternalLinks.pulls(owner: selection.owner, name: selection.name),
                onDismiss: onDismiss
            )
            ExternalLinkPopoverRow(
                titleKey: "externalLinks.releases",
                systemImage: "tag.circle",
                url: RepoExternalLinks.releases(owner: selection.owner, name: selection.name),
                onDismiss: onDismiss
            )

            if let homepage = selection.homepage {
                Divider()
                    .padding(.horizontal, 4)
                ExternalLinkPopoverRow(
                    titleKey: "externalLinks.homepage",
                    systemImage: "house",
                    url: homepage,
                    onDismiss: onDismiss
                )
            }
        }
        .padding(7)
        .frame(width: 238)
    }
}

// MARK: - 公共子组件（toolbar / 搜索弹窗 共用）
//
// SEARCH-RICH 2026-06-14：搜索弹窗 ··· 折叠菜单要复用 toolbar 同款 popover 视觉
// （CodeFlow 渐变卡片 + 行内菜单项），抽出本组件后两边共享单一信任源；将来 toolbar
// popover 视觉调整时搜索弹窗自动同步，不会再出现"两套 UI 慢慢漂移"。

/// CodeFlow 主推菜单卡片。
///
/// 视觉是 popover 第一组的整行渐变胶囊（pink → purple → blue），用于把 CodeFlow 这
/// 个核心差异化能力推到用户视野最前。`action` 由调用方决定 sheet / panel / 回调路径。
struct CodeFlowFeaturedTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 17, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text("CodeFlow")
                        .font(.system(size: 14, weight: .bold))
                    Text("toolbar.codeFlow.subtitle")
                        .font(.system(size: 10, weight: .medium))
                        .opacity(0.82)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 46)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.25, blue: 0.58), .purple, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .shadow(color: .purple.opacity(0.22), radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Popover 内的普通外链行，使用轻量 hover 背景模拟系统菜单的指针反馈。
struct ExternalLinkPopoverRow: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let url: URL?
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onDismiss()
            if let url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(titleKey)
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                isHovering ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}
