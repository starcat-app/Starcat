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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var showGitHubFilters: Bool = false

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
        .onKeyPress(.upArrow) {
            viewModel.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            if let candidate = viewModel.selectedCandidate, !viewModel.lastSubmittedQuery.isEmpty {
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
        VStack(spacing: 8) {
            HStack {
                Button {
                    showGitHubFilters.toggle()
                } label: {
                    Label("GitHub 筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Spacer()
                if viewModel.canLoadMoreGitHub {
                    Button("加载更多") { Task { await viewModel.loadMoreGitHub() } }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                }
            }

            if showGitHubFilters {
                HStack(spacing: 8) {
                    TextField("Language", text: optionalBinding(\.language))
                    TextField("Topic", text: optionalBinding(\.topic))
                    TextField("Min stars", value: $viewModel.githubFilters.minimumStars, format: .number)
                        .frame(width: 90)
                    Picker("排序", selection: $viewModel.githubFilters.sort) {
                        Text("Best match").tag(GitHubSearchSort.bestMatch)
                        Text("Stars").tag(GitHubSearchSort.stars)
                        Text("Forks").tag(GitHubSearchSort.forks)
                        Text("Updated").tag(GitHubSearchSort.updated)
                    }
                    .frame(width: 120)
                    Picker("顺序", selection: $viewModel.githubFilters.order) {
                        Text("降序").tag(SearchOrder.descending)
                        Text("升序").tag(SearchOrder.ascending)
                    }
                    .frame(width: 90)
                    Button("应用") { Task { await viewModel.applyGitHubFilters() } }
                        .buttonStyle(.borderedProminent)
                }
                .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    DatePicker(
                        "Created after",
                        selection: optionalDateBinding(\.createdAfter),
                        displayedComponents: .date
                    )
                    DatePicker(
                        "Pushed after",
                        selection: optionalDateBinding(\.pushedAfter),
                        displayedComponents: .date
                    )
                    Button("清除日期") {
                        viewModel.githubFilters.createdAfter = nil
                        viewModel.githubFilters.pushedAfter = nil
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
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
                Button { onOpenCandidate(candidate) } label: {
                    candidateRow(candidate, isSelected: index == viewModel.selectedIndex)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .contextMenu {
                    if case .repository(let repository) = candidate {
                        Button("在 GitHub 打开") { onOpenURL(repository) }
                        Button("复制 URL") { onCopyURL(repository) }
                        if let repo = repository.localRepo {
                            Divider()
                            Button("Ask / AI 摘要") { onOpenAI(repo) }
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
                isSelected: isSelected,
                showStarredCheckmark: true
            )
        case .reference(let reference):
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.title).font(.headline).lineLimit(1)
                    Text(reference.snippet ?? reference.originalURL.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(reference.domain).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
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

    private func optionalDateBinding(_ keyPath: WritableKeyPath<GitHubSearchFilters, Date?>) -> Binding<Date> {
        Binding(
            get: { viewModel.githubFilters[keyPath: keyPath] ?? Date() },
            set: { viewModel.githubFilters[keyPath: keyPath] = $0 }
        )
    }
}
