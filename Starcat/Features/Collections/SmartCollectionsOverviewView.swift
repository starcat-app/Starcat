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
    @State private var isLoadingSystemCounts = false
    @State private var isLoadingUserCounts = false
    @State private var deleteError: String?
    @State private var editTarget: UserSmartCollection?
    @State private var createFromTemplateKind: SmartCollectionKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                systemCollectionsHeader

                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
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
                    LazyVGrid(
                        columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                        alignment: .leading,
                        spacing: 10
                    ) {
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
            // 进入总览页先同步 sidebar 列表，避免 userSmartCollections 仍为空/过期时
            // 用户看不到旧集合、但 create 门控仍按 DB 行数拦截。
            await viewModel.refreshSidebar()
            await reloadAllCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoLibraryStateDidChange)) { _ in
            // 入库/移出会影响「知识库」「未入库 Stars」等系统集合数量；只监听真实数据变更，
            // 不再跟随 selection/itemsRevision，避免点击集合卡片时全量重算。
            Task { await reloadAllCounts() }
        }
        .sheet(item: $editTarget) { collection in
            SmartCollectionRuleEditorSheet(
                mode: .edit(collection),
                onCancel: { editTarget = nil },
                onSaved: {
                    editTarget = nil
                    Task { await reloadUserCounts() }
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $createFromTemplateKind) { kind in
            SmartCollectionRuleEditorSheet(
                mode: .create(
                    defaultName: SmartCollectionRule.defaultName(for: kind),
                    initialRule: SmartCollectionRule.template(for: kind)
                ),
                onCancel: { createFromTemplateKind = nil },
                onSaved: {
                    createFromTemplateKind = nil
                    Task { await reloadUserCounts() }
                }
            )
            .appLocaleEnvironment()
        }
    }

    /// 内置集合标题行。数量重算不再跟随 selection/repo list 重载，避免点击集合卡片时全量刷新 counts。
    private var systemCollectionsHeader: some View {
        HStack(spacing: 8) {
            Text("smartCollections.system.title")
                .font(.headline)

            Spacer(minLength: 8)

            SyncIconButton(
                isRefreshing: isLoadingSystemCounts || isLoadingUserCounts,
                disabled: isLoadingSystemCounts || isLoadingUserCounts,
                tooltip: String.l10n("smartCollections.refresh")
            ) {
                Task { await reloadAllCounts() }
            }
        }
        .padding(.horizontal, 16)
    }

    private func systemCollectionCard(_ kind: SmartCollectionKind) -> some View {
        let isSelected = viewModel.selection == .smartCollection(kind)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(kind.iconBadgeBackground)
                        .frame(width: 30, height: 30)
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(kind.tint)
                }

                Spacer(minLength: 4)

                systemCountLabel(for: kind)

                // library_state 相关集合当前无法转换成用户规则模板，避免保存后规则语义漂移。
                if kind.supportsUserRuleTemplate {
                    Button {
                        createFromTemplateKind = kind
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("smartCollections.saveAsTemplate")
                }
            }

            Text(kind.titleKey)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(kind.subtitleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
        .padding(12)
        .background((isSelected ? kind.tint.opacity(0.18) : kind.cardBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(kind.tint)
                .frame(width: isSelected ? 3 : 0)
                .padding(.vertical, 8)
                .opacity(isSelected ? 1 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? kind.tint.opacity(0.42) : kind.cardBorder, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectSidebar(.smartCollection(kind))
        }
        .pressableHover()
    }

    @ViewBuilder
    private func systemCountLabel(for kind: SmartCollectionKind) -> some View {
        collectionCountLabel(systemCounts[kind] ?? 0, tint: kind.tint)
    }

    private func userCollectionCard(_ collection: UserSmartCollection) -> some View {
        let isSelected = viewModel.selection == .userSmartCollection(collection.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: collection.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                Spacer(minLength: 4)

                collectionCountLabel(userCounts[collection.id] ?? 0, tint: Color.accentColor)
            }

            Text(collection.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            HStack {
                Spacer(minLength: 0)
                userCollectionActions(for: collection)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(12)
        .background(Color.accentColor.opacity(isSelected ? 0.18 : 0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: isSelected ? 3 : 0)
                .padding(.vertical, 8)
                .opacity(isSelected ? 1 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(isSelected ? 0.42 : 0.22), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectSidebar(.userSmartCollection(collection.id))
        }
        .pressableHover()
    }

    /// 数量刷新时保留旧数字，只在新结果落地时更新；右上角刷新按钮负责表达刷新状态。
    private func collectionCountLabel(_ count: Int, tint: Color) -> some View {
        Text(verbatim: "\(count)")
            .font(.subheadline)
            .fontWeight(.semibold)
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.18), value: count)
    }

    /// 用户集合卡片操作：编辑规则 / 删除（重命名在规则编辑器内一并完成）。
    private func userCollectionActions(for collection: UserSmartCollection) -> some View {
        HStack(spacing: 8) {
            Button {
                editTarget = collection
            } label: {
                Label("smartCollections.editor.edit.help", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("smartCollections.editor.edit.help")

            Button {
                Task { await delete(collection) }
            } label: {
                Label("smartCollections.delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("smartCollections.delete")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func reloadAllCounts() async {
        async let system: Void = reloadSystemCounts()
        async let user: Void = reloadUserCounts()
        _ = await (system, user)
    }

    /// 内置集合计数：与删除用户集合无关，仅在首屏 / 显式刷新时重算。
    private func reloadSystemCounts() async {
        isLoadingSystemCounts = true
        defer { isLoadingSystemCounts = false }

        do {
            let repos = try await dependencies.repoRepository.fetchAllStarred()
            async let statusMapAsync = dependencies.repoNoteRepository.fetchAllStatusMap()
            let health = try await dependencies.repoHealthRepository.snapshots(for: repos.map(\.id))
            let statusMap = (try? await statusMapAsync) ?? [:]
            var nextSystem: [SmartCollectionKind: Int] = [:]
            for kind in SmartCollectionKind.allCases {
                if kind == .library {
                    nextSystem[kind] = try await dependencies.repoRepository.knowledgeCount()
                } else if kind == .outsideLibraryStars {
                    let libraryStateMap = try await dependencies.repoNoteRepository.fetchAllLibraryStateMap()
                    nextSystem[kind] = repos.filter { repo in
                        (libraryStateMap[repo.id] ?? .outsideLibrary) != .inLibrary
                    }.count
                } else if kind == .noTags {
                    nextSystem[kind] = try await dependencies.repoRepository.fetchUntagged().count
                } else if kind == .using {
                    // 与右侧详情列表的 `.smartCollection(.using)` 同源：正在使用是 repo_notes
                    // 的用户状态，不是 repo metadata；直接用状态仓库避免总览和列表口径漂移。
                    nextSystem[kind] = try await dependencies.repoNoteRepository.fetchRepos(byStatus: .using).count
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
            withAnimation(.easeInOut(duration: 0.18)) {
                systemCounts = nextSystem
            }
        } catch {
            AppLog.database.warning("Smart Collections system counts load failed: \(error.localizedDescription, privacy: .public)")
            withAnimation(.easeInOut(duration: 0.18)) {
                systemCounts = [:]
            }
        }
    }

    /// 用户集合计数：编辑规则后重算；删除时只改本地字典，不走 loading。
    private func reloadUserCounts() async {
        isLoadingUserCounts = true
        defer { isLoadingUserCounts = false }

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
        withAnimation(.easeInOut(duration: 0.18)) {
            userCounts = nextUser
        }
    }

    private func delete(_ collection: UserSmartCollection) async {
        do {
            try await dependencies.smartCollectionRepository.delete(id: collection.id)
            await viewModel.refreshSidebar()
            if viewModel.selection == .userSmartCollection(collection.id) {
                viewModel.selectSidebar(.smartCollectionsHome)
            }
            // 删除不影响内置集合命中数，只移除本地用户计数，避免整页 spinner。
            userCounts.removeValue(forKey: collection.id)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
