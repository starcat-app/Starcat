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

    @State private var counts: [SmartCollectionKind: Int] = [:]
    @State private var isLoading = false
    @State private var deleteError: String?

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
                        Text(verbatim: "\(counts[kind] ?? 0)")
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
                Button {
                    Task { await delete(collection) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("smartCollections.delete")
            }

            Text(collection.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("smartCollections.mine.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
        // 保留删除按钮的独立点击区域，卡片本体只负责进入自定义智能集合。
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
            var next: [SmartCollectionKind: Int] = [:]
            for kind in SmartCollectionKind.allCases {
                if kind == .noTags {
                    next[kind] = try await dependencies.repoRepository.fetchUntagged().count
                } else {
                    next[kind] = repos.filter { repo in
                        HomeViewModel.matchesSmartCollection(
                            repo: repo,
                            health: health[repo.id],
                            status: statusMap[repo.id],
                            kind: kind
                        )
                    }.count
                }
            }
            counts = next
        } catch {
            AppLog.database.warning("Smart Collections counts load failed: \(error.localizedDescription, privacy: .public)")
            counts = [:]
        }
    }

    private func delete(_ collection: UserSmartCollection) async {
        do {
            try await dependencies.smartCollectionRepository.delete(id: collection.id)
            await viewModel.refreshSidebar()
            if viewModel.selection == .userSmartCollection(collection.id) {
                viewModel.selectSidebar(.smartCollectionsHome)
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
