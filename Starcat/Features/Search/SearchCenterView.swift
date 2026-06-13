//
//  SearchCenterView.swift
//  Starcat
//
//  主窗口级搜索浮层。结果行复用 UnifiedRepoRow，网页资料保持独立样式，避免把网页
//  结果伪装成仓库。业务动作由宿主注入，搜索模块不直接依赖 HomeViewModel。
//

import SwiftUI

struct SearchCenterView: View {
    @Bindable var viewModel: SearchCenterViewModel
    let onOpenCandidate: (SearchCandidate) -> Void
    let onOpenURL: (RepositoryCandidate) -> Void
    let onCopyURL: (RepositoryCandidate) -> Void
    let onOpenAI: (Repo) -> Void
    let onToggleStar: (Repo) -> Void
    let isStarred: (Int64) -> Bool
    let isGitHubAuthenticated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var showGitHubFilters: Bool = false
    @State private var remoteDetailRepo: Repo?

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { viewModel.dismiss() }

            VStack(spacing: 0) {
                searchHeader
                Divider()
                scopePicker
                if viewModel.scope == .all || viewModel.scope == .github {
                    githubFilterBar
                }
                Divider()
                resultContent
            }
            .frame(width: 760, height: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.35), radius: 32, y: 14)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
        }
        .onAppear { isSearchFocused = true }
        .sheet(item: $remoteDetailRepo) { repo in
            SearchRemoteRepoDetailView(
                repo: repo,
                isStarred: isStarred(repo.id),
                onToggleStar: { onToggleStar(repo) },
                onOpenAI: { onOpenAI(repo) }
            )
        }
        .onKeyPress(.upArrow) {
            viewModel.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            let normalizedDraft = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate = viewModel.selectedCandidate,
               !viewModel.lastSubmittedQuery.isEmpty,
               normalizedDraft == viewModel.lastSubmittedQuery {
                onOpenCandidate(candidate)
            } else {
                Task { await viewModel.submit() }
            }
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.dismiss()
            return .handled
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索本地 Stars、GitHub 与网页", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($isSearchFocused)
                .onSubmit { Task { await viewModel.submit() } }

            if !viewModel.query.isEmpty {
                Button { viewModel.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var scopePicker: some View {
        HStack(spacing: 8) {
            ForEach(SearchScope.allCases) { scope in
                Button {
                    Task { await viewModel.changeScope(scope) }
                } label: {
                    Text(scopeTitle(scope))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(viewModel.scope == scope ? Color.accentColor.opacity(0.24) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var githubFilterBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    showGitHubFilters.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text("GitHub 筛选")
                            .fontWeight(.semibold)
                        Image(systemName: showGitHubFilters ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Spacer()
                Label(
                    isGitHubAuthenticated ? "已登录" : "匿名搜索",
                    systemImage: isGitHubAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let summary = viewModel.githubResultSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.canLoadMoreGitHub {
                    Button("加载更多") { Task { await viewModel.loadMoreGitHub() } }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                }
            }

            if showGitHubFilters {
                VStack(spacing: 12) {
                    HStack(alignment: .bottom, spacing: 12) {
                        githubTextFilter(
                            title: "语言",
                            placeholder: "例如 Swift",
                            text: optionalBinding(\.language)
                        )
                        githubTextFilter(
                            title: "Topic",
                            placeholder: "例如 macOS",
                            text: optionalBinding(\.topic)
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            filterFieldLabel("最低 Stars")
                            TextField("不限", value: $viewModel.githubFilters.minimumStars, format: .number)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 112)
                    }

                    HStack(alignment: .bottom, spacing: 12) {
                        githubPicker(title: "排序方式", width: 130) {
                            Picker("排序方式", selection: $viewModel.githubFilters.sort) {
                                Text("最佳匹配").tag(GitHubSearchSort.bestMatch)
                                Text("Stars").tag(GitHubSearchSort.stars)
                                Text("Forks").tag(GitHubSearchSort.forks)
                                Text("最近更新").tag(GitHubSearchSort.updated)
                            }
                        }
                        githubPicker(title: "顺序", width: 90) {
                            Picker("顺序", selection: $viewModel.githubFilters.order) {
                                Text("降序").tag(SearchOrder.descending)
                                Text("升序").tag(SearchOrder.ascending)
                            }
                        }
                        githubDateFilter(title: "创建时间晚于", keyPath: \.createdAfter)
                        githubDateFilter(title: "推送时间晚于", keyPath: \.pushedAfter)
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        Button("清除日期") {
                            viewModel.githubFilters.createdAfter = nil
                            viewModel.githubFilters.pushedAfter = nil
                        }
                        .buttonStyle(.bordered)

                        Button("应用筛选") {
                            Task { await viewModel.applyGitHubFilters() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.lastSubmittedQuery.isEmpty {
            historyContent
        } else if viewModel.candidates.isEmpty, viewModel.isSearching {
            ProgressView("正在搜索…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.candidates.isEmpty {
            ContentUnavailableView(
                "没有找到结果",
                systemImage: "magnifyingglass",
                description: Text(viewModel.errorMessages.first ?? "尝试更换关键词或搜索范围")
            )
        } else {
            List(Array(viewModel.candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    if case .repository(let repository) = candidate,
                       repository.localRepo == nil,
                       let remoteRepo = repository.remoteRepo {
                        remoteDetailRepo = remoteRepo
                    } else {
                        onOpenCandidate(candidate)
                    }
                } label: {
                    candidateRow(candidate, isSelected: index == viewModel.selectedIndex)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .contextMenu {
                    if case .repository(let repository) = candidate {
                        Button("在 GitHub 打开") { onOpenURL(repository) }
                        Button("复制 URL") { onCopyURL(repository) }
                        if let repo = repository.displayRepo {
                            Divider()
                            Button("Ask / AI 摘要") { onOpenAI(repo) }
                            Button(isStarred(repo.id) ? "取消 Star" : "Star") { onToggleStar(repo) }
                        }
                    } else if case .reference(let reference) = candidate {
                        Button("在浏览器打开") { NSWorkspace.shared.open(reference.originalURL) }
                        Button("复制 URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reference.originalURL.absoluteString, forType: .string)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.inset)
            .overlay(alignment: .bottomLeading) {
                if let message = viewModel.errorMessages.first {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
            }
        }
    }

    private var historyContent: some View {
        Group {
            if viewModel.history.isEmpty {
                ContentUnavailableView("搜索 Starcat", systemImage: "sparkle.magnifyingglass", description: Text("输入关键词后按 Return"))
            } else {
                List(viewModel.history, id: \.self) { entry in
                    Button { Task { await viewModel.useHistory(entry) } } label: {
                        Label(entry, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: SearchCandidate, isSelected: Bool) -> some View {
        switch candidate {
        case .repository(let repo):
            UnifiedRepoRow(
                card: repo.card,
                // 搜索结果不复用主列表的整行选中底色。浮层在浅色主题下面积更大，
                // 蓝色铺底会压低文本对比度；键盘当前位置改由左侧细条表达。
                isSelected: false,
                showStarredCheckmark: true
            )
            .overlay(alignment: .leading) { searchSelectionIndicator(isSelected) }
        case .reference(let reference):
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.title).font(.headline).lineLimit(1)
                    Text(reference.snippet ?? reference.originalURL.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(reference.domain).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(10)
            .overlay(alignment: .leading) { searchSelectionIndicator(isSelected) }
        }
    }

    /// 搜索浮层只用轻量位置提示承载键盘选择，不再给结果卡片铺色。
    /// 3pt 指示条在亮/暗主题下都清晰，也不会改变 repo/reference 两类内容的底色。
    private func searchSelectionIndicator(_ isSelected: Bool) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: 34)
            .opacity(isSelected ? 1 : 0)
            .padding(.leading, 2)
    }

    private func scopeTitle(_ scope: SearchScope) -> String {
        switch scope {
        case .all: return "全部"
        case .local: return "本地"
        case .github: return "GitHub"
        case .web: return "网页"
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<GitHubSearchFilters, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.githubFilters[keyPath: keyPath] ?? "" },
            set: { value in
                viewModel.githubFilters[keyPath: keyPath] = value.isEmpty ? nil : value
            }
        )
    }

    private func githubTextFilter(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private func filterFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

    /// Picker 的标题放到控件上方，避免 macOS 自动把 label 挤在选择框左侧，造成
    /// “排序 Best m…”这类横向截断。调用方仍传原生 Picker，交互行为不变。
    private func githubPicker<Content: View>(
        title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(title)
            content()
                .labelsHidden()
        }
        .frame(width: width, alignment: .leading)
    }

    /// Optional Date 需要把“是否启用”显式展示出来。旧 UI 在 nil 时也显示今天，
    /// 用户会误以为日期已加入 query；checkbox 关闭时 DatePicker 仅作预览且不生效。
    private func githubDateFilter(
        title: String,
        keyPath: WritableKeyPath<GitHubSearchFilters, Date?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(title)
            HStack(spacing: 5) {
                Toggle("", isOn: optionalDateEnabledBinding(keyPath))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                DatePicker(
                    title,
                    selection: optionalDateBinding(keyPath),
                    displayedComponents: .date
                )
                .labelsHidden()
                .disabled(viewModel.githubFilters[keyPath: keyPath] == nil)
            }
        }
        .frame(width: 140, alignment: .leading)
    }

    private func optionalDateEnabledBinding(
        _ keyPath: WritableKeyPath<GitHubSearchFilters, Date?>
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel.githubFilters[keyPath: keyPath] != nil },
            set: { enabled in
                viewModel.githubFilters[keyPath: keyPath] = enabled ? Date() : nil
            }
        )
    }

    private func optionalDateBinding(_ keyPath: WritableKeyPath<GitHubSearchFilters, Date?>) -> Binding<Date> {
        Binding(
            get: { viewModel.githubFilters[keyPath: keyPath] ?? Date() },
            set: { viewModel.githubFilters[keyPath: keyPath] = $0 }
        )
    }
}

/// GitHub 搜索结果的会话级详情，不写数据库；只有用户执行 Star 后才通过
/// StarActionService 进入本地事实源。
private struct SearchRemoteRepoDetailView: View {
    let repo: Repo
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onOpenAI: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.fullName).font(.title2.bold())
                    Text(repo.description ?? "暂无描述").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }
            HStack(spacing: 18) {
                Label(repo.language ?? "Unknown", systemImage: "chevron.left.forwardslash.chevron.right")
                Label("\(repo.starsCount)", systemImage: "star")
                Label("\(repo.forksCount)", systemImage: "tuningfork")
                if let license = repo.license { Label(license, systemImage: "doc.text") }
            }
            .foregroundStyle(.secondary)
            HStack {
                Button(isStarred ? "取消 Star" : "Star") { onToggleStar() }
                    .buttonStyle(.borderedProminent)
                Button("Ask / AI 摘要") { onOpenAI() }
                Button("在 GitHub 打开") {
                    if let url = URL(string: repo.htmlUrl) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 260)
    }
}
