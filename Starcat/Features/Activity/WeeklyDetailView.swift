//
//  WeeklyDetailView.swift
//  Starcat
//
//  Activity 页 weekly 分类的右侧详情面板。
//
//  设计要点：
//  - 周刊项目没有本地 Repo 缓存记录，无法走 ActivityDetailView 的 `repoBackedDetailPage`
//    路径（依赖本地 Repo.id / 收藏状态 / topicsArray 等字段），所以单独造一个
//    metadata header；README 走 `ReadmeViewModel.loadTrending(owner:repo:isLoggedIn:)`
//    复用 Trending 详情页同款无本地 ID 的加载链路。
//  - 顶部 hero 区比 Activity / Manage 多两类信息：
//      1) 周刊期号徽章（点击跳本周刊原文）；
//      2) GitHub 跳转按钮（语言 / Stars / Issue Link 三个 chip 紧贴下面）。
//    这两类是用户反馈里明确点名要的"来源 / 期数"。
//  - readmeVM 局部持有（不复用 HomeView 全局 readmeVM）：避免周刊详情页 README
//    污染 Manage / Trending / Activity 右侧主详情页的加载状态。与 ActivityDetailView
//    的做法一致。
//

import SwiftUI
import AppKit

struct WeeklyDetailView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession

    let project: WeeklyProject?

    /// 局部 README ViewModel；首次有 project 时按需 lazy 构造。
    /// 选用局部而非全局：周刊详情页不影响 Manage / Trending 主路径的 README 状态。
    @State private var readmeVM: ReadmeViewModel?

    var body: some View {
        Group {
            if let project {
                content(project)
                    // .id 触发详情页随选中项目变化的视图重建，避免上一项的滚动位置 / readme 残留。
                    .id(project.id)
            } else {
                emptyState
            }
        }
        .task(id: project?.id) {
            await loadReadmeIfNeeded(for: project)
        }
    }

    private func content(_ project: WeeklyProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heroSection(project)

            Divider()

            readmeSection(project)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Hero

    /// 顶部 metadata 区。布局参考 Trending / Activity 详情头：
    /// avatar + 标题 + 描述 + 统计 chip 行 + 操作按钮行。
    private func heroSection(_ project: WeeklyProject) -> some View {
        let accent = accentColor(for: project)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Button {
                    NSWorkspace.shared.open(project.url)
                } label: {
                    RemoteAvatar(
                        urlString: RepoAvatarURL.from(owner: project.owner),
                        size: 64
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("weekly.detail.openOnGitHub")

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: project.fullName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let desc = project.description, !desc.isEmpty {
                        Text(verbatim: desc)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            statsRow(project)

            actionRow(project)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(
                colors: [accent.opacity(0.18), accent.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    /// 统计 chip：Stars / 语言 / 周刊期号。
    /// 周刊期号 chip 点击会调 `openIssue(project)` 跳到 ruanyf/weekly 原文。
    private func statsRow(_ project: WeeklyProject) -> some View {
        HStack(spacing: 8) {
            StarsBadge(count: project.stars, style: .full)

            if let language = project.language, !language.isEmpty {
                LanguageBadge(language: language, style: .full)
            }

            if project.firstIssue > 0 {
                Button {
                    openIssue(project)
                } label: {
                    MetaBadge(
                        systemImage: "newspaper",
                        text: String(format: String(localized: "weekly.issueLabelFormat"), project.firstIssue),
                        tint: accentColor(for: project)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("weekly.detail.openIssue")
            }
        }
    }

    /// 行动按钮行：在 GitHub 打开 + 查看周刊原文 + 复制仓库链接。
    /// 这一行不放进 `statsRow` 是为了视觉上"信息 vs 操作"分组更清晰。
    private func actionRow(_ project: WeeklyProject) -> some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(project.url)
            } label: {
                Label("weekly.detail.openOnGitHub", systemImage: "arrow.up.right.square")
            }
            .controlSize(.small)

            if project.issueURL != nil {
                Button {
                    openIssue(project)
                } label: {
                    Label("weekly.detail.openIssue", systemImage: "newspaper")
                }
                .controlSize(.small)
            }

            CopyFeedbackButton(
                providesContent: { project.url.absoluteString },
                tooltip: "weekly.detail.copyURL"
            ) { didCopy in
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .foregroundStyle(didCopy ? Color.green : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }

            Spacer()
        }
    }

    // MARK: - README

    /// README 区：完全复用 Trending 详情页的 `loadTrending` + `ReadmeStateView` 链路，
    /// 因为周刊项目同样没有本地 Repo.id，跟 Trending 是同一类"无本地缓存"用例。
    /// 不传 `translationControl`：翻译入口依赖本地 Repo（缓存 / 持久化键都是 Repo.id），
    /// 周刊场景没有这条信息，传 nil 让 footer 跳过翻译控件。
    @ViewBuilder
    private func readmeSection(_ project: WeeklyProject) -> some View {
        if let readmeVM {
            ReadmeStateView(
                state: readmeVM.state,
                baseURL: URL(string: "\(project.url.absoluteString)/blob/HEAD"),
                owner: project.owner,
                repo: project.name,
                translationControl: nil
            ) {
                readmeVM.loadTrending(
                    owner: project.owner,
                    repo: project.name,
                    isLoggedIn: authSession.state.isAuthenticated
                )
            } onLogin: {
                authSession.signIn()
            }
            .environment(readmeVM)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("readme.loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("weekly.detail.emptyTitle")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("weekly.detail.emptySubtitle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func accentColor(for project: WeeklyProject) -> Color {
        if let language = project.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return ActivityCategory.weekly.iconColor
    }

    /// 优先打开周刊原文 issue 页；缺 issueURL 时退化到仓库 URL，避免点击无响应。
    private func openIssue(_ project: WeeklyProject) {
        if let url = project.issueURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(project.url)
        }
    }

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        let model = ReadmeViewModel(api: dependencies.readmeAPI)
        readmeVM = model
        return model
    }

    private func loadReadmeIfNeeded(for project: WeeklyProject?) async {
        guard let project else {
            readmeVM?.reset()
            return
        }
        ensureReadmeViewModel().loadTrending(
            owner: project.owner,
            repo: project.name,
            isLoggedIn: authSession.state.isAuthenticated
        )
    }
}
