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

@MainActor
struct SmartCollectionsOverviewView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var systemCounts: [SmartCollectionKind: Int] = [:]
    @State private var userCounts: [String: Int] = [:]
    /// 当前 userCounts 对应的集合定义快照，用于侧栏刷新后的增量判定：
    /// 定义未变的集合沿用已有计数，只补算新增或规则变化的卡片。
    @State private var countedUserCollections: [UserSmartCollection] = []
    @State private var isLoadingSystemCounts = false
    @State private var isLoadingUserCounts = false
    @State private var deleteError: String?
    @State private var editTarget: UserSmartCollection?
    @State private var createFromTemplateKind: SmartCollectionKind?
    @State private var showCreateCollectionSheet = false
    @State private var hoveredSystemCollection: SmartCollectionKind?

    var body: some View {
        let systemCollections = SmartCollectionKind.allCases
        // 总览重进时由视图生命周期播放入场，计数发布和切换卡片选中项不重播。
        let revealSnapshotID = 0

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                systemCollectionsHeader

                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(Array(systemCollections.enumerated()), id: \.element.id) { index, kind in
                        systemCollectionCard(kind)
                            .listRowReveal(index: index, snapshotID: revealSnapshotID)
                    }
                }
                .padding(.horizontal, 16)

                mineCollectionsHeader

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
                        ForEach(Array(viewModel.userSmartCollections.enumerated()), id: \.element.id) { index, collection in
                            userCollectionCard(collection)
                                .listRowReveal(index: systemCollections.count + index, snapshotID: revealSnapshotID)
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
            // 卡片用已有数据先展示，缓存和真实计数都不必等完整侧栏刷新。
            applyCachedCountsIfAvailable()
            await reloadAllCounts()
            guard !Task.isCancelled else { return }

            // 同步「我的集合」的定义，避免列表过期而新建门控已按 DB 行数生效。
            // 同步后只补算新增或定义变化的集合；未变的集合沿用进入时已算好的计数，
            // 避免用户规则在进入路径上全量算第二遍（主线程卡顿的历史原因之一）。
            await viewModel.refreshSidebar()
            guard !Task.isCancelled else { return }
            await publishUserCountsIfDefinitionsChanged()
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
        // 「我的集合」标题行的 +：不带模板，从空规则基线新建。
        // 编辑器保存后会自行 refreshSidebar + 处理付费墙，这里只负责刷新计数。
        .sheet(isPresented: $showCreateCollectionSheet) {
            SmartCollectionRuleEditorSheet(
                mode: .create(
                    defaultName: String.l10n("smartCollections.new.defaultName"),
                    initialRule: .baseline
                ),
                onCancel: { showCreateCollectionSheet = false },
                onSaved: {
                    showCreateCollectionSheet = false
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

    /// 「我的集合」标题行 + 新建集合入口（dong4j 2026-09-04：入口从 Manage toolbar
    /// 收紧到特定分类后，总览页需要 own 的新建按钮，否则智能集合首页无显式新建入口）。
    /// 图标语言对齐 sidebar 分组 header：`plus.circle.fill` + hierarchical + .secondary。
    private var mineCollectionsHeader: some View {
        HStack(spacing: 8) {
            Text("smartCollections.mine.title")
                .font(.headline)

            Spacer(minLength: 8)

            Button {
                showCreateCollectionSheet = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("smartCollections.editor.help"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func systemCollectionCard(_ kind: SmartCollectionKind) -> some View {
        let isSelected = viewModel.selection == .smartCollection(kind)
        let isHovered = hoveredSystemCollection == kind
        let backgroundColor = isSelected
            ? kind.tint.opacity(isHovered ? 0.22 : 0.18)
            : (isHovered ? kind.tint.opacity(0.15) : kind.cardBackground)
        let borderColor = isSelected
            ? kind.tint.opacity(isHovered ? 0.56 : 0.42)
            : (isHovered ? kind.tint.opacity(0.36) : kind.cardBorder)
        let hoverAnimation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.15)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(kind.iconBadgeBackground)
                        .frame(width: 30, height: 30)
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(kind.tint)
                }

                Text(kind.titleKey)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

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

            Text(kind.subtitleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(kind.tint)
                .frame(width: isSelected ? 3 : 0)
                .padding(.vertical, 8)
                .opacity(isSelected ? 1 : 0)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(isHovered ? 0.16 : 0),
            radius: isHovered ? 6 : 0,
            x: 0,
            y: isHovered ? 3 : 0
        )
        .offset(y: isHovered && !reduceMotion ? -1 : 0)
        .zIndex(isHovered ? 1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectSidebar(.smartCollection(kind))
        }
        // `pressableHover` 的 1.06 放大与 0.7 透明度适合 hero / avatar；紧凑网格卡片改用
        // 不改变布局尺寸的提亮与轻阴影，避免 hover 时压到相邻卡片。Reduce Motion 下仅保留颜色反馈。
        .onHover { hovering in
            if hovering {
                hoveredSystemCollection = kind
            } else if hoveredSystemCollection == kind {
                hoveredSystemCollection = nil
            }
        }
        .animation(hoverAnimation, value: isHovered)
    }

    @ViewBuilder
    private func systemCountLabel(for kind: SmartCollectionKind) -> some View {
        // nil = 计数尚未就绪（无缓存且未发布），显示骨架占位；
        // 字典缺失与真实 0 由 Optional 区分，不再合并成 "0" 直接显示。
        collectionCountLabel(systemCounts[kind], tint: kind.tint)
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

                collectionCountLabel(userCounts[collection.id], tint: Color.accentColor)
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

    /// 数字槽位：`nil` 表示计数尚未就绪，显示静态骨架占位；就绪后在发布处的
    /// `withAnimation` 内做 ~180ms 淡化交接。已有数字的重算保持旧值，
    /// 新结果落地时走 `numericText` 过渡。缓存命中时首帧直出数字，不闪骨架。
    private func collectionCountLabel(_ count: Int?, tint: Color) -> some View {
        Group {
            if let count {
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
            } else {
                CountSlotPlaceholder()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: count == nil)
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

            DestructiveIconButton(
                help: Text("smartCollections.delete"),
                font: .callout
            ) {
                Task { await delete(collection) }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func reloadAllCounts() async {
        guard !isLoadingSystemCounts, !isLoadingUserCounts else { return }
        isLoadingSystemCounts = true
        isLoadingUserCounts = true
        defer {
            isLoadingSystemCounts = false
            isLoadingUserCounts = false
        }

        // 系统计数与用户规则相互独立，各自就绪即发布；不再互相等待，
        // 先算完的一组数字先上屏（配合数字槽位的骨架 → 数字过渡）。
        async let systemPublish: Void = publishSystemCounts()
        async let userPublish: Void = publishUserCounts(for: viewModel.userSmartCollections)
        _ = await (systemPublish, userPublish)
    }

    /// 内置集合计数：一次数据库事务读取保证八张卡片属于同一数据快照；
    /// 纯 CPU 求值下放到并发执行器，回主 actor 后才发布。
    private func publishSystemCounts() async {
        do {
            let snapshot = try await SmartCollectionSystemCountsLoader.load(database: dependencies.database)
            guard !Task.isCancelled else { return }
            let nextSystem = await SmartCollectionSystemCountsLoader.counts(from: snapshot)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                systemCounts = nextSystem
            }
            storeCountSnapshot()
        } catch {
            // SWR 失败保留已有快照；清空会让短暂数据库故障退化成整页 0。
            AppLog.database.warning("Smart Collections counts load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 求值并发布用户集合计数。
    /// 传当前全量集合时整体覆盖；传变化子集时增量合并，未变集合沿用旧值，
    /// 已删除集合的旧计数由 validIDs 过滤清理。
    private func publishUserCounts(for collections: [UserSmartCollection]) async {
        let nextUser = await loadUserCounts(for: collections)
        guard !Task.isCancelled else { return }
        let validIDs = Set(viewModel.userSmartCollections.map(\.id))
        withAnimation(.easeInOut(duration: 0.18)) {
            for (id, count) in nextUser {
                userCounts[id] = count
            }
            userCounts = userCounts.filter { validIDs.contains($0.key) }
        }
        countedUserCollections = viewModel.userSmartCollections
        storeCountSnapshot()
    }

    /// 侧栏刷新后的增量补算入口：只对新增或定义（规则/元数据）变化的集合重新求值，
    /// 定义全部未变时只清理已删除集合的旧计数。
    private func publishUserCountsIfDefinitionsChanged() async {
        guard !isLoadingUserCounts else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: countedUserCollections.map { ($0.id, $0) })
        let changed = viewModel.userSmartCollections.filter { previousByID[$0.id] != $0 }
        if changed.isEmpty {
            let validIDs = Set(viewModel.userSmartCollections.map(\.id))
            let pruned = userCounts.filter { validIDs.contains($0.key) }
            if pruned.count != userCounts.count {
                withAnimation(.easeInOut(duration: 0.18)) {
                    userCounts = pruned
                }
                storeCountSnapshot()
            }
            return
        }
        isLoadingUserCounts = true
        defer { isLoadingUserCounts = false }
        await publishUserCounts(for: changed)
    }

    /// 用户集合计数：编辑规则后重算；删除时只改本地字典，不走 loading。
    private func reloadUserCounts() async {
        guard !isLoadingUserCounts else { return }
        isLoadingUserCounts = true
        defer { isLoadingUserCounts = false }

        await publishUserCounts(for: viewModel.userSmartCollections)
    }

    private func loadUserCounts(for collections: [UserSmartCollection]) async -> [String: Int] {
        var nextUser: [String: Int] = [:]
        for collection in collections {
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
        return nextUser
    }

    private func applyCachedCountsIfAvailable() {
        guard let cached = SmartCollectionOverviewCountCache.shared.snapshot(
            accountID: dependencies.database.currentUserId,
            collections: viewModel.userSmartCollections
        ) else { return }
        systemCounts = cached.systemCounts
        userCounts = cached.userCounts
        // 缓存签名已按当前集合定义校验通过，视为已按当前定义计数过，
        // 侧栏刷新后的增量补算才能正确跳过未变化集合。
        countedUserCollections = viewModel.userSmartCollections
    }

    private func storeCountSnapshot() {
        SmartCollectionOverviewCountCache.shared.store(
            systemCounts: systemCounts,
            userCounts: userCounts,
            accountID: dependencies.database.currentUserId,
            collections: viewModel.userSmartCollections
        )
    }

    private func removeCachedUserCount(id: String) {
        userCounts.removeValue(forKey: id)
        storeCountSnapshot()
    }

    private func applyDeletedCollection(_ collection: UserSmartCollection) {
        removeCachedUserCount(id: collection.id)
        if viewModel.selection == .userSmartCollection(collection.id) {
            viewModel.selectSidebar(.smartCollectionsHome)
        }
    }

    private func delete(_ collection: UserSmartCollection) async {
        do {
            try await dependencies.smartCollectionRepository.delete(id: collection.id)
            await viewModel.refreshSidebar()
            // 删除不影响内置集合命中数，只移除本地用户计数，避免整页 spinner。
            applyDeletedCollection(collection)
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

/// 数字槽位的首载占位：静态圆角块，尺寸贴近 subheadline 数字。
///
/// 有意不做 shimmer：骨架 shimmer 依赖 `SkeletonAnimatedPhase` 的 TimelineView 时钟，
/// 卡片网格里每张卡各挂一个时钟违背骨架体系"共享单时钟"的设计约束，
/// 而计数首载通常不足一秒，静态块已足够表达"数字尚未就绪"。
/// 明暗主题配色复用 `SkeletonPalette`；不拦截点击、不被 VoiceOver 朗读。
private struct CountSlotPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(SkeletonPalette.forColorScheme(colorScheme).base)
            .frame(width: 26, height: 13)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
