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

    private var filteredCandidates: [Repo] {
        RAGAddToLibraryLogic.filter(candidates, query: searchText)
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
    }

    private var header: some View {
        HStack(alignment: .center, spacing: interfaceScale.scaled(12)) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.12))
                Image(systemName: "heart.fill")
                    .font(interfaceScale.font(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
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
                    filteredCandidates.count
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
            .disabled(filteredCandidates.isEmpty || isSubmitting)

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
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredCandidates) { repo in
                        repoRow(repo)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func repoRow(_ repo: Repo) -> some View {
        let isSelected = selectedIDs.contains(repo.id)
        return Button {
            toggle(repo)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(interfaceScale.font(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)

                RemoteAvatar(
                    urlString: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner),
                    size: interfaceScale.scaled(22)
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.fullName)
                        .font(interfaceScale.font(.bodyEmphasis))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(RAGMentionPickerLogic.subtitle(for: repo))
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.10)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isSubmitting)
        .help(repo.fullName)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("common.cancel") {
                dismiss()
            }
            .font(interfaceScale.font(.body))
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
        for repo in filteredCandidates {
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
