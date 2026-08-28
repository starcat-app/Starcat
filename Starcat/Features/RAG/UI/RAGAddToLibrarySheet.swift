//
//  RAGAddToLibrarySheet.swift
//  Starcat
//
//  RAG 工作台「从 Stars 批量加入知识库」Sheet。
//
//  为什么独立成 Sheet：
//  - 知识库为空时，KnowledgeRAGBrowser 只有已入库仓库，打开也帮不上忙；
//  - 独立工作台不能依赖跳回主窗口「未入库 Stars」完成首要任务；
//  - 入库仍走 `updateLibraryState(.inLibrary)`，自动索引由 IndexBuilder 监听
//    `.repoLibraryStateDidChange` 触发，本 Sheet 不直接调 rebuild。
//

import SwiftUI

/// 未入库 Stars 的筛选 / 候选派生，方便单测覆盖，不依赖 SwiftUI。
enum RAGAddToLibraryLogic {
    /// 列表首屏条数；之后按页追加。
    static let pageSize = 30
    /// 距当前已加载列表底部还剩这么多条时触发下一页。
    static let prefetchDistance = ListPaginationPolicy.prefetchDistance

    /// 已 star 且尚未入库（无 `repo_notes` 行按 outside 处理）。
    static func outsideLibraryStars(
        starred: [Repo],
        libraryStateMap: [Int64: LibraryState]
    ) -> [Repo] {
        starred.filter { repo in
            (libraryStateMap[repo.id] ?? .outsideLibrary) != .inLibrary
        }
    }

    /// 按 fullName / description / language 做不区分大小写包含匹配。
    static func filter(_ repos: [Repo], query: String) -> [Repo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return repos }
        return repos.filter { repo in
            let haystack = [
                repo.fullName,
                repo.description ?? "",
                repo.language ?? ""
            ].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// 当前应渲染的窗口；`displayedLimit` 由滚动分页递增。
    static func displayedRepos(_ filtered: [Repo], limit: Int) -> [Repo] {
        Array(filtered.prefix(max(limit, 0)))
    }

    /// 滚动到「距已加载尾部 <= prefetchDistance」时加载下一页。
    static func shouldPrefetchNextPage(
        appearingIndex: Int,
        displayedLimit: Int,
        filteredCount: Int
    ) -> Bool {
        let displayedCount = min(displayedLimit, filteredCount)
        return ListPaginationPolicy.shouldPrefetch(
            appearingIndex: appearingIndex,
            itemCount: displayedCount,
            hasMore: displayedLimit < filteredCount
        )
    }

    static func nextDisplayLimit(current: Int, filteredCount: Int) -> Int {
        min(current + pageSize, filteredCount)
    }
}

/// RAG 工作台空库时的批量入库 Sheet。
struct RAGAddToLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AppDependencies.self) private var dependencies

    @State private var candidates: [Repo] = []
    @State private var selectedIDs: Set<Int64> = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var loadError: String?
    /// 区分「本地还没有任何 Star」与「Stars 都已入库」。
    @State private var starredTotalCount = 0
    /// 当前已加载到列表的条数窗口；搜筛选变化时重置为首屏。
    @State private var displayedLimit = RAGAddToLibraryLogic.pageSize

    private var filteredCandidates: [Repo] {
        RAGAddToLibraryLogic.filter(candidates, query: searchText)
    }

    private var displayedCandidates: [Repo] {
        RAGAddToLibraryLogic.displayedRepos(filteredCandidates, limit: displayedLimit)
    }

    private var selectedRepos: [Repo] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(14)) {
            header
            searchField
            selectionToolbar
            Divider()
            listBody
            Divider()
            footer
        }
        .padding(interfaceScale.scaled(20))
        .frame(
            width: 560 * interfaceScale.multiplier,
            height: 560 * interfaceScale.multiplier
        )
        .appLocaleEnvironment()
        .task { await loadCandidates() }
        .onChange(of: searchText) { _, _ in
            // 筛选条件变了：回到首屏窗口，避免 limit 卡在旧结果长度上。
            displayedLimit = RAGAddToLibraryLogic.pageSize
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: interfaceScale.scaled(12)) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.12))
                Image(systemName: "heart.fill")
                    .font(interfaceScale.font(size: 17, weight: .semibold))
                    // 与 LibraryToggleButton 入库心同款红；外框仍走 tint 淡底。
                    .foregroundStyle(Color.fromHex6(0xE11D48))
            }
            .frame(
                width: interfaceScale.scaled(36),
                height: interfaceScale.scaled(36)
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("rag.workspace.addToLibrary.title")
                    .font(interfaceScale.font(.panelTitle, weight: .semibold))
                Text("rag.workspace.addToLibrary.subtitle")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            SheetCloseButton(
                action: { dismiss() },
                iconFont: interfaceScale.font(size: 18, weight: .medium),
                frameSize: interfaceScale.scaled(24)
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(interfaceScale.font(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                String.l10n("rag.workspace.addToLibrary.searchPlaceholder"),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(interfaceScale.font(.body))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(interfaceScale.font(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.mention.clearFilter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var selectionToolbar: some View {
        HStack(spacing: 10) {
            Text(
                String(
                    format: String.l10n("rag.workspace.addToLibrary.stats"),
                    selectedIDs.count,
                    displayedCandidates.count
                )
            )
            .font(interfaceScale.font(.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                selectAllVisible()
            } label: {
                Text("rag.workspace.addToLibrary.selectVisible")
                    .font(interfaceScale.font(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.accentColor)
            .disabled(displayedCandidates.isEmpty || isSubmitting)

            Button {
                selectedIDs.removeAll()
            } label: {
                Text("rag.workspace.addToLibrary.clearSelected")
                    .font(interfaceScale.font(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
            .disabled(selectedIDs.isEmpty || isSubmitting)
        }
    }

    @ViewBuilder
    private var listBody: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "rag.workspace.addToLibrary.loadFailed",
                subtitleText: loadError,
                spacing: 12
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            EmptyStateView(
                systemImage: starredTotalCount == 0 ? "star" : "checkmark.circle",
                title: starredTotalCount == 0
                    ? "rag.workspace.addToLibrary.emptyStars"
                    : "rag.workspace.addToLibrary.emptyCandidates",
                subtitle: starredTotalCount == 0
                    ? "rag.workspace.addToLibrary.emptyStarsSubtitle"
                    : "rag.workspace.addToLibrary.emptyCandidatesSubtitle",
                spacing: 12,
                subtitleHorizontalPadding: 24
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredCandidates.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "rag.workspace.addToLibrary.emptyFilter",
                subtitle: "rag.workspace.addToLibrary.emptyFilterSubtitle",
                spacing: 12
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayedCandidates.enumerated()), id: \.element.id) { index, repo in
                        repoRow(repo, rowIndex: index)
                            .onAppear {
                                prefetchIfNeeded(appearingIndex: index)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func repoRow(_ repo: Repo, rowIndex: Int) -> some View {
        let isSelected = selectedIDs.contains(repo.id)
        return Button {
            toggle(repo)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(interfaceScale.font(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12, alignment: .center)

                RemoteAvatar(
                    urlString: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner),
                    size: interfaceScale.scaled(18),
                    showBorder: false
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.fullName)
                        .font(interfaceScale.font(.bodyEmphasis))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    // 与 `@` mention 候选同构：语言色点 + 星标，不用纯文字副行。
                    HStack(spacing: 8) {
                        if let language = repo.language?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !language.isEmpty {
                            LanguageBadge(language: language, style: .compact)
                        }
                        StarsBadge(count: repo.starsCount, style: .compact)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.12)
                    : zebraBackground(rowIndex: rowIndex)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isSubmitting)
        .help(repo.fullName)
    }

    /// 与 `@` mention / 分片列表同一套斑马纹：奇数行极淡 primary。
    private func zebraBackground(rowIndex: Int) -> Color {
        rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
    }

    /// 滚近已加载窗口尾部时追加一页，避免一次渲完几百行。
    private func prefetchIfNeeded(appearingIndex: Int) {
        let filteredCount = filteredCandidates.count
        guard RAGAddToLibraryLogic.shouldPrefetchNextPage(
            appearingIndex: appearingIndex,
            displayedLimit: displayedLimit,
            filteredCount: filteredCount
        ) else { return }
        displayedLimit = RAGAddToLibraryLogic.nextDisplayLimit(
            current: displayedLimit,
            filteredCount: filteredCount
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("common.cancel") {
                dismiss()
            }
            .font(interfaceScale.font(.body))
            .controlSize(.small)
            .disabled(isSubmitting)

            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(
                        String(
                            format: String.l10n("rag.workspace.addToLibrary.confirmFormat"),
                            selectedIDs.count
                        )
                    )
                }
            }
            .font(interfaceScale.font(.body))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedIDs.isEmpty || isSubmitting)
        }
    }

    private func toggle(_ repo: Repo) {
        if selectedIDs.contains(repo.id) {
            selectedIDs.remove(repo.id)
        } else {
            selectedIDs.insert(repo.id)
        }
    }

    private func selectAllVisible() {
        // 「全选可见」= 当前已加载窗口，不是全量筛选结果。
        for repo in displayedCandidates {
            selectedIDs.insert(repo.id)
        }
    }

    private func loadCandidates() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            async let starred = dependencies.repoRepository.fetchAllStarred()
            async let libraryMap = dependencies.repoNoteRepository.fetchAllLibraryStateMap()
            let starredRepos = try await starred
            starredTotalCount = starredRepos.count
            candidates = RAGAddToLibraryLogic.outsideLibraryStars(
                starred: starredRepos,
                libraryStateMap: try await libraryMap
            )
            displayedLimit = RAGAddToLibraryLogic.pageSize
        } catch {
            loadError = error.localizedDescription
            AppLog.ui.error("RAG add-to-library load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 逐条写入库状态；每条都会触发 IndexBuilder 的 library-add 索引，无需手动 rebuild。
    private func submit() async {
        let targets = selectedRepos
        guard !targets.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            for repo in targets {
                try await dependencies.repoNoteRepository.updateLibraryState(
                    repoId: repo.id,
                    state: .inLibrary
                )
            }
            dismiss()
        } catch {
            loadError = error.localizedDescription
            AppLog.ui.error("RAG add-to-library submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
