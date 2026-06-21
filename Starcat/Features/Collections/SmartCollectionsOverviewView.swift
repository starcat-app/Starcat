//
//  SmartCollectionsOverviewView.swift
//  Starcat
//
//  Manage 内的 Smart Collections 总览页。
//
//  设计约束：
//  - 这里只做入口总览，不直接渲染 repo list。
//  - 点击系统集合后把 HomeViewModel.selection 切到 `.smartCollection(kind)`，
//    后续列表 / 详情 / 多选全部复用 Manage 既有管线。
//

import SwiftUI

struct SmartCollectionsOverviewView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var viewModel

    @State private var systemCounts: [SmartCollectionKind: Int] = [:]
    @State private var userCounts: [String: Int] = [:]
    @State private var isLoading = false
    @State private var deleteError: String?
    @State private var renameTarget: UserSmartCollection?
    @State private var renameError: String?

    private var summaryContext: SmartCollectionRuleSummary.Context {
        viewModel.smartCollectionSummaryContext()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("smartCollections.builtIn.title")
                    .font(.headline)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(SmartCollectionKind.allCases) { kind in
                        systemCollectionCard(kind)
                    }
                }
                .padding(.horizontal, 16)

                Text("smartCollections.mine.title")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                if viewModel.userSmartCollections.isEmpty {
                    Text("smartCollections.mine.empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(viewModel.userSmartCollections) { collection in
                            userCollectionCard(collection)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if let deleteError {
                    Text(deleteError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
        }
        .task {
            await reloadCounts()
        }
        .sheet(item: $renameTarget) { collection in
            RenameSmartCollectionSheet(
                currentName: collection.name,
                errorMessage: renameError,
                onCancel: {
                    renameTarget = nil
                    renameError = nil
                },
                onConfirm: { newName in
                    Task { await rename(collection, to: newName) }
                }
            )
            .appLocaleEnvironment()
        }
    }

    private func systemCollectionCard(_ kind: SmartCollectionKind) -> some View {
        Button {
            viewModel.selectSidebar(.smartCollection(kind))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(kind.tint)
                        .frame(width: 28, height: 28)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Text(verbatim: "\(systemCounts[kind] ?? 0)")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }

                Text(kind.titleKey)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(kind.subtitleKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(kind.tint.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
    }

    private func userCollectionCard(_ collection: UserSmartCollection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: collection.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text(verbatim: "\(userCounts[collection.id] ?? 0)")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 6) {
                Text(collection.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button {
                    renameError = nil
                    renameTarget = collection
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("smartCollections.rename.help")
                Button {
                    Task { await delete(collection) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("smartCollections.delete")
            }

            if let rule = collection.rule {
                Text(verbatim: SmartCollectionRuleSummary.compact(rule: rule, context: summaryContext))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            } else {
                Text("smartCollections.mine.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            viewModel.selectSidebar(.userSmartCollection(collection.id))
        }
        .pressableHover()
    }

    private func reloadCounts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let repos = try await dependencies.repoRepository.fetchAllStarred()
            async let statusMapAsync = dependencies.repoNoteRepository.fetchAllStatusMap()
            let health = try await dependencies.repoHealthRepository.snapshots(for: repos.map(\.id))
            let statusMap = (try? await statusMapAsync) ?? [:]
            var nextSystem: [SmartCollectionKind: Int] = [:]
            for kind in SmartCollectionKind.allCases {
                if kind == .noTags {
                    nextSystem[kind] = try await dependencies.repoRepository.fetchUntagged().count
                } else {
                    nextSystem[kind] = repos.filter { repo in
                        HomeViewModel.matchesSmartCollection(
                            repo: repo,
                            health: health[repo.id],
                            status: statusMap[repo.id],
                            kind: kind
                        )
                    }.count
                }
            }
            systemCounts = nextSystem

            var nextUser: [String: Int] = [:]
            for collection in viewModel.userSmartCollections {
                guard let rule = collection.rule else {
                    nextUser[collection.id] = 0
                    continue
                }
                if let count = try? await viewModel.countRepos(matching: rule) {
                    nextUser[collection.id] = count
                } else {
                    nextUser[collection.id] = 0
                }
            }
            userCounts = nextUser
        } catch {
            AppLog.database.warning("Smart Collections counts load failed: \(error.localizedDescription, privacy: .public)")
            systemCounts = [:]
            userCounts = [:]
        }
    }

    private func delete(_ collection: UserSmartCollection) async {
        do {
            try await dependencies.smartCollectionRepository.delete(id: collection.id)
            await viewModel.refreshSidebar()
            if viewModel.selection == .userSmartCollection(collection.id) {
                viewModel.selectSidebar(.smartCollectionsHome)
            }
            await reloadCounts()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func rename(_ collection: UserSmartCollection, to name: String) async {
        do {
            try await viewModel.renameUserSmartCollection(id: collection.id, name: name)
            renameTarget = nil
            renameError = nil
        } catch {
            renameError = error.localizedDescription
        }
    }
}
