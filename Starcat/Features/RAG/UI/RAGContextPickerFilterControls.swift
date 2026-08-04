//
//  RAGContextPickerFilterControls.swift
//  Starcat
//
//  知识库仓库列表的排序 / 筛选控件。
//  Composer「+」面板与知识库浏览器共用；语言名单复用 AppSettings.interestedLanguages。
//

import AppKit
import SwiftUI

/// 排序 + 筛选；搜索框由调用方并排放置。
struct RAGContextPickerFilterControls: View {
    @Environment(AppSettings.self) private var settings

    @Binding var sortOption: RepoSortOption
    @Binding var filters: RAGComposerMentionFilters
    @Binding var isFilterPresented: Bool
    @Binding var isLanguageAddPresented: Bool
    /// `false`：只暴露 SQL 可下推条件（星标 / 状态 / 语言 / 归档 / Fork），供知识库浏览器使用。
    var includeSignalFilters: Bool
    /// Agent 目录没有知识库专属分数，调用方可收窄为真实可用的排序项。
    var sortOptions: [RepoSortOption]
    /// 调用方特有的筛选分组直接并入同一个漏斗面板，避免再套一层独立菜单。
    var additionalFilterItems: [FilterMenuItem]
    var isAdditionalFilterActive: Bool
    var onReset: () -> Void

    @State private var draftLanguage = ""

    init(
        sortOption: Binding<RepoSortOption>,
        filters: Binding<RAGComposerMentionFilters>,
        isFilterPresented: Binding<Bool>,
        isLanguageAddPresented: Binding<Bool>,
        includeSignalFilters: Bool = true,
        sortOptions: [RepoSortOption] = RepoSortOption.manageOptions,
        additionalFilterItems: [FilterMenuItem] = [],
        isAdditionalFilterActive: Bool = false,
        onReset: @escaping () -> Void
    ) {
        self._sortOption = sortOption
        self._filters = filters
        self._isFilterPresented = isFilterPresented
        self._isLanguageAddPresented = isLanguageAddPresented
        self.includeSignalFilters = includeSignalFilters
        self.sortOptions = sortOptions
        self.additionalFilterItems = additionalFilterItems
        self.isAdditionalFilterActive = isAdditionalFilterActive
        self.onReset = onReset
    }

    /// Composer「+」面板：绑定工作台 mention 排序 / 筛选（含 Wiki / Health / OpenSSF）。
    init(viewModel: KnowledgeRAGWorkspaceViewModel) {
        self.init(
            sortOption: Binding(
                get: { viewModel.mentionSortOption },
                set: { viewModel.mentionSortOption = $0 }
            ),
            filters: Binding(
                get: { viewModel.mentionFilters },
                set: { viewModel.mentionFilters = $0 }
            ),
            isFilterPresented: Binding(
                get: { viewModel.isContextPickerFilterPresented },
                set: { viewModel.isContextPickerFilterPresented = $0 }
            ),
            isLanguageAddPresented: Binding(
                get: { viewModel.isContextPickerLanguageAddPresented },
                set: { viewModel.isContextPickerLanguageAddPresented = $0 }
            ),
            includeSignalFilters: true,
            onReset: { viewModel.resetMentionFilters() }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            UnifiedSortMenu(
                selection: $sortOption,
                options: sortOptions,
                displayName: { $0.displayName },
                systemImage: { $0.systemImage },
                dividerBefore: {
                    $0.isManageSpecificSort
                        && $0 == RepoSortOption.manageOptions.first(where: \.isManageSpecificSort)
                }
            )

            UnifiedFilterMenu(
                items: filterItems,
                isAnyFilterActive: isAnyFilterActive,
                accessibilityLabel: "list.filter.status",
                helpKey: "list.filter.hint",
                isPresented: $isFilterPresented,
                onReset: onReset
            )
            .onChange(of: isFilterPresented) { _, open in
                if !open {
                    isLanguageAddPresented = false
                }
            }
        }
    }

    /// 浏览器 SQL-only 模式不把 Wiki / Health / OpenSSF 算进激活态。
    private var isAnyFilterActive: Bool {
        (includeSignalFilters ? filters.isActive : filters.isSQLOnlyActive)
            || isAdditionalFilterActive
    }

    private var filterItems: [FilterMenuItem] {
        var items = additionalFilterItems
        if !additionalFilterItems.isEmpty {
            items.append(.divider(id: "after-additional-filters"))
        }
        items.append(contentsOf: [
            .content(id: "starStatus", view: AnyView(starFilterSection)),
            .divider(id: "after-star"),
            .content(id: "status", view: AnyView(statusFilterSection)),
            .divider(id: "after-status"),
            .content(id: "language", view: AnyView(languageFilterSection)),
        ])
        if includeSignalFilters {
            items.append(contentsOf: [
                .divider(id: "after-language"),
                .content(id: "wiki", view: AnyView(
                    availabilityPicker(
                        title: "list.filter.wikiAvailability",
                        icon: "doc.text.magnifyingglass",
                        keyPath: \.wikiAvailability
                    )
                )),
                .content(id: "health", view: AnyView(
                    availabilityPicker(
                        title: "list.filter.healthAvailability",
                        icon: "heart.text.square",
                        keyPath: \.healthAvailability
                    )
                )),
                .content(id: "openssf", view: AnyView(
                    availabilityPicker(
                        title: "list.filter.openSSFAvailability",
                        icon: "checkmark.shield",
                        keyPath: \.openSSFAvailability
                    )
                )),
                .divider(id: "after-signals"),
            ])
        } else {
            items.append(.divider(id: "after-language"))
        }
        items.append(contentsOf: [
            .toggle(
                id: "hideArchived",
                label: "settings.general.hideArchived",
                icon: "archivebox",
                isOn: filterBinding(\.hideArchived)
            ),
            .toggle(
                id: "hideForks",
                label: "settings.general.hideForks",
                icon: "tuningfork",
                isOn: filterBinding(\.hideForks)
            ),
        ])
        return items
    }

    private var starFilterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("list.filter.starStatus", icon: "star.circle")
            Picker(selection: filterBinding(\.star)) {
                ForEach(RepoStarFilter.allCases, id: \.self) { filter in
                    Label(filter.displayName, systemImage: starIcon(for: filter)).tag(filter)
                }
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private var statusFilterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("list.filter.status", icon: "tray.full")
            Picker(selection: statusBinding) {
                Label("general.all", systemImage: "tray.full").tag(RepoStatus?.none)
                ForEach(RepoStatus.allCases, id: \.self) { status in
                    Label(status.displayName, systemImage: statusIcon(for: status))
                        .tag(RepoStatus?.some(status))
                }
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private var languageFilterSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader("list.filter.language", icon: "globe")
                Spacer(minLength: 0)
                Button {
                    draftLanguage = ""
                    isLanguageAddPresented = true
                } label: {
                    // 与左侧「语言」分类 Label 同规格，禁止再缩成 caption。
                    Label("settings.filters.interestedLanguages.add", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("settings.filters.interestedLanguages.add")
                .popover(isPresented: $isLanguageAddPresented, arrowEdge: .trailing) {
                    languagePickerPopover
                        .frame(width: 280, height: 300)
                        .padding(14)
                        .onExitCommand {
                            isLanguageAddPresented = false
                        }
                }
            }

            if !filters.selectedLanguages.isEmpty {
                Button {
                    filters.selectedLanguages = []
                } label: {
                    Label("list.filter.language.clearSelection", systemImage: "xmark.circle")
                }
            }

            if settings.interestedLanguages.isEmpty {
                Text("settings.filters.interestedLanguages.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.interestedLanguages, id: \.self) { language in
                    Toggle(isOn: languageSelectionBinding(for: language)) {
                        // 与设置页感兴趣语言一致：用 LanguageIconView，不用通用 </ > SF Symbol。
                        HStack(spacing: 6) {
                            LanguageIconView(language: language, size: 14)
                            Text(LanguageDisplayName.shortened(for: language))
                        }
                    }
                }
            }
        }
    }

    private var languagePickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("settings.filters.interestedLanguages.add.placeholder", text: $draftLanguage)
                .textFieldStyle(.roundedBorder)
            let query = draftLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = LinguistLanguageCatalog.search(query)
            if query.isEmpty {
                Text("settings.filters.interestedLanguages.add.placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if results.isEmpty {
                Text("settings.filters.interestedLanguages.search.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                List(results, id: \.self) { language in
                    Button {
                        // 多选：点选只增删感兴趣语言，不关闭 popover。
                        toggleInterestedLanguage(language)
                    } label: {
                        HStack(spacing: 8) {
                            LanguageIconView(language: language, size: 16)
                            Text(language)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if isInterestedLanguage(language) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
                .listStyle(.plain)
            }
        }
    }

    private func availabilityPicker(
        title: LocalizedStringKey,
        icon: String,
        keyPath: WritableKeyPath<RAGComposerMentionFilters, RepoSignalAvailabilityFilter>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title, icon: icon)
            Picker(selection: filterBinding(keyPath)) {
                ForEach(RepoSignalAvailabilityFilter.allCases, id: \.self) { filter in
                    Label(availabilityTitle(for: filter), systemImage: availabilityIcon(for: filter, fallback: icon))
                        .tag(filter)
                }
            } label: { EmptyView() }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(.secondary)
    }

    private func filterBinding<Value>(
        _ keyPath: WritableKeyPath<RAGComposerMentionFilters, Value>
    ) -> Binding<Value> {
        Binding(
            get: { filters[keyPath: keyPath] },
            set: { filters[keyPath: keyPath] = $0 }
        )
    }

    private var statusBinding: Binding<RepoStatus?> {
        filterBinding(\.status)
    }

    private func languageSelectionBinding(for language: String) -> Binding<Bool> {
        Binding(
            get: { filters.selectedLanguages.contains(language) },
            set: { isOn in
                var selected = Set(filters.selectedLanguages)
                if isOn {
                    selected.insert(language)
                } else {
                    selected.remove(language)
                }
                filters.selectedLanguages = selected.sorted()
            }
        )
    }

    private func addInterestedLanguage(_ language: String) {
        let normalized = AppSettings.normalizedLanguageList(
            settings.interestedLanguages + [language]
        )
        settings.interestedLanguages = normalized
        var selected = Set(filters.selectedLanguages)
        selected.insert(language)
        filters.selectedLanguages = selected.sorted()
    }

    private func removeInterestedLanguage(_ language: String) {
        settings.interestedLanguages = settings.interestedLanguages.filter {
            $0.caseInsensitiveCompare(language) != .orderedSame
        }
        filters.selectedLanguages = filters.selectedLanguages.filter {
            $0.caseInsensitiveCompare(language) != .orderedSame
        }
    }

    private func isInterestedLanguage(_ language: String) -> Bool {
        settings.interestedLanguages.contains {
            $0.caseInsensitiveCompare(language) == .orderedSame
        }
    }

    /// 点选切换感兴趣语言；面板保持打开，支持连续多选。
    private func toggleInterestedLanguage(_ language: String) {
        if isInterestedLanguage(language) {
            removeInterestedLanguage(language)
        } else {
            addInterestedLanguage(language)
        }
    }

    private func starIcon(for filter: RepoStarFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .starred: return "star.fill"
        case .unstarred: return "star"
        }
    }

    private func statusIcon(for status: RepoStatus) -> String {
        switch status {
        case .unread: return "envelope"
        case .read: return "envelope.open"
        case .using: return "envelope.badge"
        }
    }

    private func availabilityTitle(for filter: RepoSignalAvailabilityFilter) -> LocalizedStringKey {
        switch filter {
        case .unknown: return "general.all"
        case .available: return "list.filter.availability.available"
        case .missing: return "list.filter.availability.missing"
        }
    }

    private func availabilityIcon(for filter: RepoSignalAvailabilityFilter, fallback: String) -> String {
        switch filter {
        case .unknown: return "tray.full"
        case .available: return fallback
        case .missing: return "nosign"
        }
    }
}
