//
//  WeeklyContentView.swift
//  Starcat
//
//  Activity 页 `weekly` 分类的中栏视图 + ViewModel。
//
//  数据源：阮一峰周刊（ruanyf/weekly）通过独立 Go 后端服务暴露的 REST API。
//  契约见 `WeeklyAPI.swift` / 后端仓库 README。
//
//  设计约束：
//  - 不复用 ActivityViewModel 的本地聚合逻辑：weekly 是远端分页 + 筛选 + 排序，
//    塞进 ActivityViewModel 会污染其"本地缓存聚合"语义。
//  - 列表点击 → 写入 `WeeklySelectionService.selectedProject`，由 HomeView 详情区
//    路由到 `WeeklyDetailView`（不再直接外链）。详情页内才提供"在 GitHub 打开"按钮。
//    这次改动前是 `NSWorkspace.open(project.url)` 直接跳浏览器，被反馈无法预览所以
//    重新接回 detail pane；新建 `WeeklyDetailView` 而非复用 `ActivityDetailView`，
//    因为 weekly 还要展示期号 / 周刊原文等专属字段。
//  - 分页是"无限滚动"：到达列表底部时自动加载下一页；不放手动"加载更多"按钮，
//    与 macOS 上 List 的自然滚动体验一致。
//  - 列表顶部 toolbar 只保留"筛选 + 刷新"，移除了"x 项"文本——计数挪到 sidebar 的
//    周刊分类右侧徽章（仿 manage Languages 计数样式），见 `WeeklySelectionService`。
//

import SwiftUI
import AppKit

// MARK: - View

/// Activity 页 weekly 分类的内容视图。
struct WeeklyContentView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings

    @State private var viewModel: WeeklyContentViewModel?

    /// 刷新按钮转圈用的 spinning 角度（reduceMotion 时直接显示 ProgressView 替代）。
    @State private var refreshAngle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let model = ensureViewModel()
            await model.loadInitialIfNeeded()
        }
    }

    @ViewBuilder
    private func content(_ viewModel: WeeklyContentViewModel) -> some View {
        VStack(spacing: 0) {
            filterBar(viewModel)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()

            if viewModel.isLoading && viewModel.items.isEmpty {
                RepoSkeletonListView(density: settings.listDensity, rowCount: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "activity.error.title", subtitleText: error) {
                    Task { await viewModel.reload() }
                }
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: "newspaper", title: "weekly.empty.title", subtitle: "weekly.empty.subtitle") {
                    Task { await viewModel.reload() }
                }
            } else {
                projectList(viewModel)
            }
        }
    }

    // MARK: - Filter Bar

    /// 顶部筛选栏：排序 + 语言下拉。
    ///
    /// 期号筛选目前没有用 picker 暴露——后端 `/issues` 还在补，列表也不强需要；
    /// 后续要做时增加一个 Menu 即可，结构上已经在 ViewModel 留了 `selectedIssue`。
    private func filterBar(_ viewModel: WeeklyContentViewModel) -> some View {
        HStack(spacing: 10) {
            Picker(selection: Binding(
                get: { viewModel.selectedSort },
                set: { viewModel.changeSort(to: $0) }
            )) {
                ForEach(WeeklySort.allCases) { sort in
                    Text(sort.localizedTitle).tag(sort)
                }
            } label: {
                Text("weekly.filter.sort")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker(selection: Binding(
                get: { viewModel.selectedLanguage },
                set: { viewModel.changeLanguage(to: $0) }
            )) {
                ForEach(WeeklyContentViewModel.languageOptions, id: \.self) { lang in
                    Text(languageDisplayName(lang)).tag(lang)
                }
            } label: {
                Text("weekly.filter.language")
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            refreshButton(viewModel)
        }
    }

    /// 顶部刷新按钮。
    ///
    /// 视觉与 ActivityView 同款：常态显示 `arrow.triangle.2.circlepath`；
    /// 触发后整图按 0.9s 一圈匀速旋转，loading 结束角度归零。
    /// reduceMotion 时不做旋转，仅置灰禁用，避免对前庭敏感用户造成不适。
    @ViewBuilder
    private func refreshButton(_ viewModel: WeeklyContentViewModel) -> some View {
        Button {
            Task { await viewModel.reload() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .rotationEffect(.degrees(refreshAngle))
                .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: refreshAngle)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(viewModel.isLoading)
        .help("weekly.refresh")
        .onChange(of: viewModel.isLoading) { _, isLoading in
            // isLoading→true 时把角度从 0 推到 360 触发 repeatForever 循环；
            // 结束时回到 0 让动画安静收尾（隐式过渡也用同一 linear 曲线避免卡顿）。
            if isLoading {
                refreshAngle = 360
            } else {
                refreshAngle = 0
            }
        }
    }

    private func languageDisplayName(_ raw: String) -> String {
        if raw.isEmpty {
            return String(localized: "weekly.filter.allLanguages")
        }
        return raw
    }

    // MARK: - Project List

    private func projectList(_ viewModel: WeeklyContentViewModel) -> some View {
        let selection = dependencies.weeklySelectionService
        return List {
            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, project in
                Button {
                    selection.select(project)
                } label: {
                    WeeklyProjectRow(
                        project: project,
                        density: settings.listDensity,
                        isSelected: selection.selectedProject?.id == project.id
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .contextMenu {
                    Button(action: { open(project.url) }) {
                        Text("weekly.action.openRepo")
                    }
                    if let issueURL = project.issueURL {
                        Button(action: { open(issueURL) }) {
                            Text("weekly.action.openIssue")
                        }
                    }
                    Button(action: { copy(project.url.absoluteString) }) {
                        Text("weekly.action.copyURL")
                    }
                }
                .listRowReveal(index: index, snapshotID: viewModel.itemsRevision)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .onAppear {
                    // 到达接近底部时触发下一页：用倒数第 3 行作触发点，给网络一点提前量，
                    // 避免用户滚到最后一行才看到 ProgressView。
                    if viewModel.shouldTriggerLoadMore(at: index) {
                        Task { await viewModel.loadMoreIfNeeded() }
                    }
                }
            }

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    // MARK: - Helpers

    private func ensureViewModel() -> WeeklyContentViewModel {
        if let viewModel { return viewModel }
        let model = WeeklyContentViewModel(
            api: dependencies.weeklyAPI,
            selectionService: dependencies.weeklySelectionService
        )
        viewModel = model
        return model
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 空 / 错误状态视图。
    /// retry 闭包给 Button 直接调用，错误态需要"重试"，空态默认只是再刷一次。
    private func emptyState(
        systemImage: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        subtitleText: String? = nil,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if let subtitleText {
                Text(verbatim: subtitleText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Text("weekly.action.retry")
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Row

private struct WeeklyProjectRow: View {
    let project: WeeklyProject
    let density: RepoListDensity
    /// 当前行是否处于"详情页选中态"。配合 ActivityRow 的视觉语言：
    /// - 背景透明度从 0.045/0.0 抬到 0.18；
    /// - 左侧加 3pt accent 竖条 + 内容向右挪 5pt；
    /// - 标题加粗。整套样式与 `ActivityRowSurface` 对齐，给用户一致的"被选中"感知。
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accentColor: Color {
        if let language = project.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return ActivityCategory.weekly.iconColor
    }

    var body: some View {
        // R-01 §3.1.1：仅 .card 单 case 保留，紧凑布局已删。
        Group {
            switch density {
            case .card:
                card
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteAvatar(
                urlString: RepoAvatarURL.from(owner: project.owner),
                size: 40
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: project.fullName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let desc = project.description, !desc.isEmpty {
                    Text(verbatim: desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let language = project.language, !language.isEmpty {
                        LanguageBadge(language: language, style: .full)
                    }
                    StarsBadge(count: project.stars, style: .full)
                    if project.firstIssue > 0 {
                        MetaBadge(
                            systemImage: "newspaper",
                            text: String(format: String(localized: "weekly.issueLabelFormat"), project.firstIssue),
                            tint: accentColor
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .padding(.leading, isSelected ? 5 : 0)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentColor.opacity(isSelected ? 0.18 : 0.045))
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accentColor)
                .frame(width: isSelected ? 3 : 0)
                .padding(.vertical, 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor.opacity(isSelected ? 0.42 : 0.10), lineWidth: 1)
        }
    }
}

// MARK: - ViewModel

/// Weekly 分类专用 ViewModel。
///
/// 设计要点：
/// - 单一桶（sort + language 组合），切换筛选会清空当前项目并从 page=1 重新拉；
/// - 分页采用追加式：滚到底部触发 `loadMoreIfNeeded`，把新 page 追加到 items 尾部；
/// - `itemsRevision` 与 Activity / Trending 同款语义：用于 `listRowReveal` 决定是否
///   重播入场动画——筛选切换 / 重新加载时 bump，分页追加时**不** bump。
@MainActor
@Observable
final class WeeklyContentViewModel {

    /// 语言筛选选项：取 ruanyf/weekly 中常见的几种主语言；后端 lang 参数大小写敏感，
    /// 这里全部用 GitHub Linguist 规范写法。
    /// 空串代表"全部语言"，与后端 `lang` 参数留空等价。
    static let languageOptions: [String] = [
        "",
        "TypeScript",
        "JavaScript",
        "Python",
        "Go",
        "Rust",
        "Swift",
        "Java",
        "Kotlin",
        "C",
        "C++",
        "Shell"
    ]

    // MARK: - State

    private(set) var items: [WeeklyProject] = []
    private(set) var total: Int = 0
    private(set) var page: Int = 1
    private(set) var hasMore: Bool = false

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var loadError: String?
    /// 入场动画 / row-reveal 用的"身份快照"版本，仅在筛选切换 / 重新加载时 bump。
    private(set) var itemsRevision: Int = 0

    /// 排序当前值；setter 由 `changeSort(to:)` 控制以保证副作用统一。
    private(set) var selectedSort: WeeklySort = .firstIssueDesc
    private(set) var selectedLanguage: String = ""
    /// 期号筛选；目前 UI 没暴露，保留以便后续接入"按期号"侧栏交互。
    private(set) var selectedIssue: WeeklyIssueFilter = .all

    // MARK: - Dependencies

    private let api: WeeklyAPI
    /// 把 total 推到外部 sidebar 计数徽章 / detail pane 路由的共享状态。
    /// 解耦 sidebar 与列表 ViewModel：sidebar 不直接持有 ViewModel，避免双向依赖。
    private let selectionService: WeeklySelectionService?

    /// 标记当前 in-flight 请求的代次；切换筛选 / reload 时 bump，
    /// 旧请求即便回来也会因为代次不匹配而被丢弃，避免顺序错乱。
    private var generation: Int = 0

    init(api: WeeklyAPI, selectionService: WeeklySelectionService? = nil) {
        self.api = api
        self.selectionService = selectionService
    }

    // MARK: - Public

    /// 首次进入页面调用；如果已有数据就跳过，避免重新进入时把缓存丢掉。
    func loadInitialIfNeeded() async {
        guard items.isEmpty, !isLoading else { return }
        await reload()
    }

    /// 主动刷新：清空当前数据，从第一页重新拉。
    func reload() async {
        let myGen = bumpGeneration()
        isLoading = true
        isLoadingMore = false
        loadError = nil

        do {
            let result = try await api.fetchProjects(
                page: 1,
                pageSize: WeeklyAPI.defaultPageSize,
                issue: selectedIssue,
                language: selectedLanguage,
                sort: selectedSort
            )
            guard myGen == generation else { return }
            items = result.items
            total = result.total
            page = result.page
            hasMore = result.hasMore
            itemsRevision += 1
            selectionService?.applyTotal(result.total)
        } catch {
            guard myGen == generation else { return }
            loadError = error.localizedDescription
            items = []
            total = 0
            hasMore = false
        }
        if myGen == generation {
            isLoading = false
        }
    }

    /// 滚到底部触发的"加载下一页"。
    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let myGen = generation
        isLoadingMore = true
        defer {
            if myGen == generation {
                isLoadingMore = false
            }
        }

        let nextPage = page + 1
        do {
            let result = try await api.fetchProjects(
                page: nextPage,
                pageSize: WeeklyAPI.defaultPageSize,
                issue: selectedIssue,
                language: selectedLanguage,
                sort: selectedSort
            )
            guard myGen == generation else { return }
            // 同 id 项目可能因为后端排序变动并发出现重复，去一次重保险。
            let existingIDs = Set(items.map(\.id))
            let appended = result.items.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: appended)
            page = result.page
            total = result.total
            hasMore = result.hasMore
            selectionService?.applyTotal(result.total)
        } catch {
            guard myGen == generation else { return }
            loadError = error.localizedDescription
            // 分页失败保留已有数据；hasMore 暂时关掉，避免反复触发同一坏请求。
            hasMore = false
        }
    }

    func changeSort(to newValue: WeeklySort) {
        guard newValue != selectedSort else { return }
        selectedSort = newValue
        Task { await reload() }
    }

    func changeLanguage(to newValue: String) {
        guard newValue != selectedLanguage else { return }
        selectedLanguage = newValue
        Task { await reload() }
    }

    /// 给 List `.onAppear` 判断是否该触发下一页。
    /// 倒数第 3 行（或最后一行不足 3 时直接最后一行）触发，留一点网络余量。
    func shouldTriggerLoadMore(at index: Int) -> Bool {
        guard hasMore, !isLoading, !isLoadingMore else { return false }
        let threshold = max(items.count - 3, 0)
        return index >= threshold
    }

    // MARK: - Private

    private func bumpGeneration() -> Int {
        generation += 1
        return generation
    }
}

// MARK: - WeeklySort localized

extension WeeklySort {
    var localizedTitle: String {
        switch self {
        case .firstIssueDesc:
            return String(localized: "weekly.sort.latestIssue")
        case .starsDesc:
            return String(localized: "weekly.sort.starsDesc")
        }
    }
}
