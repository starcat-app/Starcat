//
//  BatchActionBar.swift
//  Starcat
//
//  多选模式底部浮动操作栏（W4 A5）。
//
//  组件结构（同文件三层）：
//  - `BatchActionBar`      底栏 UI：选中数 + 操作按钮 + 退出多选
//  - `BatchTagSheet`       批量打标签 sheet：选标签 → 触发 batchAddTag
//  - `BatchTagSheetViewModel` 内部状态：tags / selection / 提交状态
//
//  设计约束：
//  - 用 .safeAreaInset(.bottom) 嵌入 RepoListView 底部，背景做 Material 模糊
//  - 批量打标签走"先选 1 个 tag → batchAddTag(repoIds, tagId)"流程
//    （MVP 简化：一次只能给所选 repos 加一个 tag，不做"替换式批量改标签"
//     ——那语义太重，会清掉用户在每个 repo 上已有的其它标签）
//  - 完成后自动退出多选模式 + 给个 transient 提示
//

import SwiftUI

// MARK: - BatchActionBar

struct BatchActionBar: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppDependencies.self) private var dependencies

    @State private var showTagSheet: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(String(localized: "batch.selectedCount \(viewModel.multiSelectedRepoIDs.count)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button {
                showTagSheet = true
            } label: {
                Label("batch.addTags", systemImage: "tag.fill")
            }
            .disabled(viewModel.multiSelectedRepoIDs.isEmpty)
            .help("给所有选中的仓库添加同一个标签")

            Button {
                viewModel.exitMultiSelectMode()
            } label: {
                Label("batch.exitMultiSelect", systemImage: "xmark.circle")
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $showTagSheet) {
            BatchTagSheet(
                repoIds: viewModel.multiSelectedRepoIDs,
                tagRepository: dependencies.tagRepository,
                repoTagRepository: dependencies.repoTagRepository,
                onCompleted: {
                    showTagSheet = false
                    viewModel.exitMultiSelectMode()
                    // W4-4 D4：批量打标签后，刷新 Sidebar 计数 + 列表
                    Task {
                        await viewModel.refreshSidebar()
                        await viewModel.reloadItems()
                    }
                }
            )
        }
    }
}

// MARK: - BatchTagSheet

/// 批量打标签 sheet：选一个 tag → 应用到所有 selected repos。
private struct BatchTagSheet: View {

    let repoIds: Set<Int64>
    let tagRepository: any TagRepositoryProtocol
    let repoTagRepository: any RepoTagRepositoryProtocol
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm: BatchTagSheetViewModel?
    @State private var query: String = ""
    @State private var selectedTagId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("batch.addTags")
                    .font(.headline)
                Spacer()
                Text(String(localized: "batch.applyToRepos \(repoIds.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("batch.searchTags", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

            if let vm {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let tags = filteredTags(vm.tags)
                        if tags.isEmpty {
                            Text(vm.tags.isEmpty ? "batch.noTags" : "batch.noMatch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(tags) { tag in
                                row(tag: tag)
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
            }

            if let err = vm?.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("general.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("action.apply") {
                    Task {
                        guard let tid = selectedTagId else { return }
                        let ok = await vm?.apply(repoIds: repoIds, tagId: tid) ?? false
                        if ok { onCompleted() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTagId == nil || (vm?.isApplying ?? false))
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            if vm == nil {
                vm = BatchTagSheetViewModel(
                    tagRepository: tagRepository,
                    repoTagRepository: repoTagRepository
                )
            }
            await vm?.loadTags()
        }
    }

    private func filteredTags(_ tags: [Tag]) -> [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.name.lowercased().contains(q) }
    }

    private func row(tag: Tag) -> some View {
        let selected = (selectedTagId == tag.id)
        return Button {
            selectedTagId = selected ? nil : tag.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Circle()
                    .fill(Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor)
                    .frame(width: 8, height: 8)
                if let icon = tag.icon {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(tag.name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - BatchTagSheetViewModel

@MainActor
@Observable
final class BatchTagSheetViewModel {

    private(set) var tags: [Tag] = []
    private(set) var isApplying: Bool = false
    private(set) var errorMessage: String?

    private let tagRepository: any TagRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol

    init(
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol
    ) {
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
    }

    func loadTags() async {
        do {
            tags = try await tagRepository.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = "batch.loadTagsFailed"
        }
    }

    /// 把 tagId 加到 repoIds 中每一个 repo。
    /// - Returns: 成功 true 让 UI 关闭 sheet；失败 false（errorMessage 已写）。
    @discardableResult
    func apply(repoIds: Set<Int64>, tagId: String) async -> Bool {
        isApplying = true
        defer { isApplying = false }
        do {
            try await repoTagRepository.batchAddTag(repoIds: Array(repoIds), tagId: tagId)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "batch.addTagsFailed"
            return false
        }
    }
}
