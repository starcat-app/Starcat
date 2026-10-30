//
//  DailyRadarPreviewWorkspace.swift
//  Starcat
//
//  每日热点专题首页、文章上滑与相关项目返回。
//  首页和文章在上层路由打开时保留挂载，依靠各自 ScrollView 保存滚动位置；
//  文稿读取独立日报 API；相关项目不更改主窗口仓库选择。
//

import SwiftUI

/// 在主窗口中右联合区域内运行的日报工作区。
struct DailyRadarPreviewWorkspace: View {
    let onExit: () -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var model = DailyRadarWorkspaceViewModel()
    @State private var project: DailyRadarReport.Project?
    @State private var projectStore = DailyRadarProjectStore()
    @State private var translationVM: ReadmeTranslationViewModel
    @FocusState private var workspaceFocused: Bool

    /// 翻译状态独立于主窗口原选中仓库；宿主在文章与项目往返时保持稳定。
    init(readmeTranslationService: ReadmeTranslationService, onExit: @escaping () -> Void) {
        self.onExit = onExit
        _translationVM = State(initialValue: ReadmeTranslationViewModel(service: readmeTranslationService))
    }

    private var stories: [DailyRadarReport] { model.stories }
    private var olderStories: [DailyRadarReport] { model.olderStories }
    private var story: DailyRadarReport? { model.selection }
    private var workspaceScope: String {
        "\(dependencies.databaseScopeRevision)|\(dependencies.dailyRadarConfigurationRevision)|\(locale.identifier)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                home(width: geometry.size.width)
                    .allowsHitTesting(story == nil)
                    .disabled(story != nil)
                    .accessibilityHidden(story != nil)

                if let story {
                    DailyRadarPreviewReader(
                        story: story, detail: model.detail, failed: model.detailFailed,
                        projectStore: projectStore,
                        retry: { Task { await model.open(story) } },
                        onClose: closeStory, onProject: openProject
                    )
                        .id(story.contentIdentity)
                        .allowsHitTesting(project == nil)
                        .disabled(project != nil)
                        .accessibilityHidden(project != nil)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                }

                if let project {
                    // 遮罩只覆盖中右内容区；文章保持挂载，关闭后继续原来的阅读位置。
                    Button(action: closeProject) {
                        Color.black.opacity(0.10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel(Text("dailyRadar.backToStory"))
                    .transition(.opacity)
                    .zIndex(2)

                    DailyRadarPreviewProjectView(project: project, store: projectStore, onBack: closeProject)
                        .id(project.id)
                        .frame(width: projectSheetWidth(in: geometry.size.width), height: geometry.size.height)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .zIndex(3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipped()
        }
        .focusable()
        .focusEffectDisabled()
        .focused($workspaceFocused)
        .onAppear { workspaceFocused = true }
        .task(id: workspaceScope) {
            project = nil
            model.configure(repository: dependencies.dailyRadarRepository, scope: workspaceScope, locale: locale)
        }
        .task(id: model.identity) {
            guard !model.scope.isEmpty else { return }
            await model.reload()
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32), value: model.selection?.contentIdentity)
        .onExitCommand(perform: goBack)
        // 分享任务与翻译付费墙属于整个热点工作区，关闭一个项目不会销毁分享宿主。
        .environment(translationVM)
        .modifier(RepoShareHost())
        .sheet(item: Binding(
            get: { translationVM.paywallContext },
            set: { if $0 == nil { translationVM.dismissPaywall() } }
        )) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
    }

    /// 标准宽度保留两侧文章，宽屏不无限拉伸；窄窗口仍留下边距并保证面板不越界。
    private func projectSheetWidth(in availableWidth: CGFloat) -> CGFloat {
        let preferred = min(760, max(520, availableWidth * 0.64))
        let sideInset: CGFloat = availableWidth < 600 ? 16 : 40
        return min(preferred, max(0, availableWidth - sideInset * 2))
    }

    /// 自适应列数只由可用内容宽度决定，不假设侧栏或主窗口的固定尺寸。
    private func home(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("dailyRadar.title", systemImage: "newspaper")
                    .font(scale.font(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                SyncIconButton(
                    isRefreshing: model.isLoading, disabled: model.isLoading,
                    tooltip: String.l10n("settings.general.shortcuts.refreshCurrentContent.title")
                ) { Task { await model.reload(force: true) } }
                SheetCloseButton(action: onExit, helpKey: "dailyRadar.close")
                    .accessibilityLabel(Text("dailyRadar.close"))
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            Divider()

            ScrollView {
                // 首页包含专题卡与可无限增长的历史行；惰性容器确保未滚到的
                // 历史行不实体化，也不会用 onAppear 提前触发下一页。
                LazyVStack(alignment: .leading, spacing: 24) {
                    heading
                    filters
                    if model.failed {
                        HStack {
                            Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("action.retry") { Task { await model.reload(force: true) } }
                        }
                        .font(scale.font(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    if let featured = stories.first {
                        DailyRadarStoryCard(story: featured, featured: true) { openStory(featured) }
                        if stories.count > 1 {
                            Text("dailyRadar.more")
                                .font(scale.font(size: 17, weight: .semibold))
                            LazyVGrid(columns: columns(width: width), spacing: 20) {
                                ForEach(stories.dropFirst()) { item in
                                    DailyRadarStoryCard(story: item, featured: false) { openStory(item) }
                                }
                            }
                        }
                    } else if model.isLoading && model.items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else if !model.failed || !model.items.isEmpty {
                        ContentUnavailableView("dailyRadar.empty", systemImage: "newspaper")
                            .frame(minHeight: 200)
                    }

                    if !olderStories.isEmpty {
                        HStack {
                            Text("dailyRadar.history")
                                .font(scale.font(size: 17, weight: .semibold))
                            Spacer()
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        // 历史行必须直接位于惰性容器中。若包在普通 VStack 里，
                        // SwiftUI 会一次实体化整页行，尾部 onAppear 会连环触发下一页。
                        LazyVStack(spacing: 0) {
                            ForEach(Array(olderStories.enumerated()), id: \.element.id) { index, item in
                                Button { openStory(item) } label: {
                                    HStack(spacing: 16) {
                                        DailyRadarCoverView(cover: item.cover)
                                            .frame(width: 88, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(verbatim: item.title.replacingOccurrences(of: "\n", with: ""))
                                                .font(scale.font(size: 14, weight: .medium))
                                                .lineLimit(1)
                                            Text(verbatim: DailyRadarDateFormatting.label(item.editionDate, locale: locale))
                                                .font(scale.font(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.forward")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .automaticListPagination(
                                    appearingIndex: index, visibleItemCount: olderStories.count,
                                    loadedItemCount: model.items.count, hasMore: model.nextCursor != nil,
                                    isLoading: model.isLoading || model.isLoadingMore || model.failed,
                                    identity: model.identity
                                ) { await model.loadMore() }
                                if item.id != olderStories.last?.id { Divider() }
                            }
                        }
                    }

                    if model.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                    Text("dailyRadar.generatedNotice")
                        .font(scale.font(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(width < 600 ? 20 : 32)
                .frame(maxWidth: .infinity)
            }
            // 只有筛选变化才重置首页滚动；打开/关闭阅读不会改变此身份。
            .id(model.identity)
            .automaticListPaginationFill(
                visibleItemCount: olderStories.count, loadedItemCount: model.items.count,
                hasMore: model.nextCursor != nil,
                isLoading: model.isLoading || model.isLoadingMore || model.failed,
                identity: model.identity
            ) { await model.loadMore() }
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: model.edition.map { DailyRadarDateFormatting.label($0, locale: locale) } ?? String.l10n("dailyRadar.title"))
                    .font(scale.font(size: 26, weight: .bold))
                    .lineLimit(1)
                Text("dailyRadar.subtitle")
                    .font(scale.font(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                Button("dailyRadar.featured") { model.selectedEdition = nil }
                ForEach(model.dates) { edition in
                    Button { model.selectedEdition = edition.date } label: {
                        Text(verbatim: DailyRadarDateFormatting.label(edition.date, locale: locale))
                    }
                }
            } label: {
                Label("dailyRadar.history", systemImage: "calendar")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("dailyRadar.history")
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                topicButton(nil)
                ForEach(model.availableCategories) { value in topicButton(value) }
                Menu {
                    Button { model.allowsFallback = true } label: { Text("dailyRadar.allTopics") }
                    ForEach(["zh-Hans", "en"], id: \.self) { language in
                        Button {
                            model.contentLanguage = language
                            model.allowsFallback = false
                        } label: {
                            Text(verbatim: locale.localizedString(forIdentifier: language) ?? language)
                        }
                    }
                } label: {
                    Text(verbatim: locale.localizedString(forIdentifier: model.contentLanguage) ?? model.contentLanguage)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func topicButton(_ value: DailyRadarCatalog.Category?) -> some View {
        Button { model.selectCategory(value?.id) } label: {
            Text(verbatim: value?.title ?? String.l10n("dailyRadar.allTopics"))
                .font(scale.font(size: 12, weight: model.category == value?.id ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(model.category == value?.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(model.category == value?.id ? Color.accentColor.opacity(0.25) : .clear))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(model.category == value?.id ? .isSelected : [])
    }

    private func columns(width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: width >= 780 ? 2 : 1)
    }

    /// 路由仅更改预览状态；底层首页和文章保持挂载以保留原位置。
    private func openStory(_ value: DailyRadarReport) {
        Task { await model.open(value) }
        workspaceFocused = true
    }

    private func closeStory() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)) { model.close() }
        workspaceFocused = true
    }

    private func openProject(_ value: DailyRadarReport.Project) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.32)) { project = value }
        workspaceFocused = true
    }

    private func closeProject() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28)) { project = nil }
        workspaceFocused = true
    }

    private func goBack() {
        if project != nil { closeProject() }
        else if story != nil { closeStory() }
        else { onExit() }
    }
}
