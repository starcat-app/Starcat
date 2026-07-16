//
//  RAGContextPickerFilterControls.swift
//  Starcat
//
//  上下文选择面板搜索行左侧的排序 / 筛选控件。
//  只改面板候选；语言名单复用 AppSettings.interestedLanguages。
//

import AppKit
import SwiftUI

/// 排序 + 筛选，放在面板搜索框前面。
struct RAGContextPickerFilterControls: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel

    @State private var draftLanguage = ""

    var body: some View {
        HStack(spacing: 6) {
            UnifiedSortMenu(
                selection: $viewModel.mentionSortOption,
                options: RepoSortOption.manageOptions,
                displayName: { $0.displayName },
                systemImage: { $0.systemImage },
                dividerBefore: {
                    $0.isManageSpecificSort
                        && $0 == RepoSortOption.manageOptions.first(where: \.isManageSpecificSort)
                }
            )

            UnifiedFilterMenu(
                items: filterItems,
                isAnyFilterActive: viewModel.mentionFilters.isActive,
                accessibilityLabel: "list.filter.status",
                helpKey: "list.filter.hint",
                isPresented: $viewModel.isContextPickerFilterPresented,
                onReset: { viewModel.resetMentionFilters() }
            )
            .onChange(of: viewModel.isContextPickerFilterPresented) { _, open in
                if !open {
                    viewModel.isContextPickerLanguageAddPresented = false
                }
            }
        }
    }

    private var filterItems: [FilterMenuItem] {
        [
            .content(id: "starStatus", view: AnyView(starFilterSection)),
            .divider(id: "after-star"),
            .content(id: "status", view: AnyView(statusFilterSection)),
            .divider(id: "after-status"),
            .content(id: "language", view: AnyView(languageFilterSection)),
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
            )
        ]
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
                    viewModel.isContextPickerLanguageAddPresented = true
                } label: {
                    // 与左侧「语言」分类 Label 同规格，禁止再缩成 caption。
                    Label("settings.filters.interestedLanguages.add", systemImage: "plus.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("settings.filters.interestedLanguages.add")
                .popover(isPresented: $viewModel.isContextPickerLanguageAddPresented, arrowEdge: .trailing) {
                    languagePickerPopover
                        .frame(width: 280, height: 300)
                        .padding(14)
                        .onExitCommand {
                            viewModel.isContextPickerLanguageAddPresented = false
                        }
                }
            }

            Text("rag.workspace.mention.languageHint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !viewModel.mentionFilters.selectedLanguages.isEmpty {
                Button {
                    viewModel.mentionFilters.selectedLanguages = []
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
            get: { viewModel.mentionFilters[keyPath: keyPath] },
            set: { viewModel.mentionFilters[keyPath: keyPath] = $0 }
        )
    }

    private var statusBinding: Binding<RepoStatus?> {
        filterBinding(\.status)
    }

    private func languageSelectionBinding(for language: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.mentionFilters.selectedLanguages.contains(language) },
            set: { isOn in
                var selected = Set(viewModel.mentionFilters.selectedLanguages)
                if isOn {
                    selected.insert(language)
                } else {
                    selected.remove(language)
                }
                viewModel.mentionFilters.selectedLanguages = selected.sorted()
            }
        )
    }

    private func addInterestedLanguage(_ language: String) {
        let normalized = AppSettings.normalizedLanguageList(
            settings.interestedLanguages + [language]
        )
        settings.interestedLanguages = normalized
        var selected = Set(viewModel.mentionFilters.selectedLanguages)
        selected.insert(language)
        viewModel.mentionFilters.selectedLanguages = selected.sorted()
    }

    private func removeInterestedLanguage(_ language: String) {
        settings.interestedLanguages = settings.interestedLanguages.filter {
            $0.caseInsensitiveCompare(language) != .orderedSame
        }
        viewModel.mentionFilters.selectedLanguages = viewModel.mentionFilters.selectedLanguages.filter {
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
