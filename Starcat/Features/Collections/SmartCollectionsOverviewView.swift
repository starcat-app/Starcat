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

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(SmartCollectionKind.allCases) { kind in
                    collectionCard(kind)
                }
            }
            .padding(16)
        }
        .task {
            await reloadCounts()
        }
    }

    private func collectionCard(_ kind: SmartCollectionKind) -> some View {
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

    private func reloadCounts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let repos = try await dependencies.repoRepository.fetchAllStarred()
            let health = try await dependencies.repoHealthRepository.snapshots(for: repos.map(\.id))
            var next: [SmartCollectionKind: Int] = [:]
            for kind in SmartCollectionKind.allCases {
                if kind == .noTags {
                    next[kind] = try await dependencies.repoRepository.fetchUntagged().count
                } else {
                    next[kind] = repos.filter { repo in
                        HomeViewModel.matchesSmartCollection(
                            repo: repo,
                            health: health[repo.id],
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
}

