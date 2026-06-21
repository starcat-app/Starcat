//
//  SmartCollectionRuleEditorView.swift
//  Starcat
//
//  用户智能集合可视化规则编辑器（表单 + 实时命中预览）。
//
//  设计约束：
//  - 规则字段 AND 组合，不提供 OR / 嵌套组。
//  - 预览计数在 Sheet 内部加载，不写回 RepoListView @State（避免 sheet 闪动）。
//  - Health predicate 为 Pro 能力；免费用户可浏览但保存时弹 Paywall。
//

import SwiftUI

/// 三态 optional-Bool 过滤（不限 / 是 / 否）。
private enum SmartCollectionTriState: String, CaseIterable, Identifiable {
    case any
    case yes
    case no

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .any: return "smartCollections.editor.triState.any"
        case .yes: return "smartCollections.editor.triState.yes"
        case .no: return "smartCollections.editor.triState.no"
        }
    }

    static func from(optional value: Bool?) -> SmartCollectionTriState {
        switch value {
        case nil: return .any
        case .some(true): return .yes
        case .some(false): return .no
        }
    }

    var optionalBool: Bool? {
        switch self {
        case .any: return nil
        case .yes: return true
        case .no: return false
        }
    }
}

struct SmartCollectionRuleEditorSheet: View {
    enum Mode: Equatable {
        case create(defaultName: String, initialRule: SmartCollectionRule)
        case edit(UserSmartCollection)
    }

    let mode: Mode
    let onCancel: () -> Void
    let onSaved: () -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(\.locale) private var locale

    @State private var draft: SmartCollectionRule
    @State private var name: String
    @State private var matchCount: Int?
    @State private var isLoadingCount = false
    @State private var saveError: String?
    @State private var paywallContext: ProPaywallContext?

    init(mode: Mode, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.mode = mode
        self.onCancel = onCancel
        self.onSaved = onSaved
        switch mode {
        case .create(_, let rule):
            _draft = State(initialValue: rule)
            _name = State(initialValue: "")
        case .edit(let collection):
            _draft = State(initialValue: collection.rule ?? SmartCollectionRule.fallback)
            _name = State(initialValue: collection.name)
        }
    }

    private var summaryContext: SmartCollectionRuleSummary.Context {
        viewModel.smartCollectionSummaryContext()
    }

    private var previewTaskID: String {
        (try? SmartCollectionRule.encode(draft)) ?? UUID().uuidString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(modeTitleKey)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                Form {
                    Section("smartCollections.editor.section.name") {
                        TextField("smartCollections.save.name", text: $name)
                    }

                    Section("smartCollections.editor.section.scope") {
                        scopePicker
                    }

                    Section("smartCollections.editor.section.search") {
                        TextField("smartCollections.editor.search.placeholder", text: searchQueryBinding)
                        Picker("smartCollections.editor.search.mode", selection: $draft.searchModeRaw) {
                            ForEach(SmartSearchMode.allCases) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                    }

                    Section("smartCollections.editor.section.filters") {
                        HStack {
                            Spacer()
                            Button("smartCollections.editor.importFromToolbar") {
                                importFromCurrentToolbar()
                            }
                            .disabled(viewModel.makeRuleFromCurrentManageFilters() == nil)
                        }
                        Picker("list.filter.status", selection: statusBinding) {
                            Label("general.all", systemImage: "tray.full").tag(Optional<RepoStatus>.none)
                            ForEach(RepoStatus.allCases, id: \.self) { status in
                                Label(status.displayName, systemImage: statusIcon(for: status))
                                    .tag(Optional<RepoStatus>.some(status))
                            }
                        }
                        Toggle("settings.general.hideArchived", isOn: $draft.hideArchived)
                        Toggle("settings.general.hideForks", isOn: $draft.hideForks)
                        Picker("list.sort", selection: $draft.sortRaw) {
                            ForEach(RepoSortOption.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        }
                    }

                    if !viewModel.tags.isEmpty {
                        Section("smartCollections.editor.section.tags") {
                            ForEach(viewModel.tags) { tag in
                                Toggle(tag.name, isOn: tagToggleBinding(tag.id))
                            }
                        }
                    }

                    Section("smartCollections.editor.section.advanced") {
                        optionalIntRow(
                            titleKey: "smartCollections.editor.starsMin",
                            value: $draft.starsMin,
                            range: 0...1_000_000
                        )
                        optionalIntRow(
                            titleKey: "smartCollections.editor.starsMax",
                            value: $draft.starsMax,
                            range: 0...1_000_000
                        )
                        optionalIntRow(
                            titleKey: "smartCollections.editor.pushedWithinDays",
                            value: $draft.pushedWithinDays,
                            range: 1...3_650
                        )
                        optionalIntRow(
                            titleKey: "smartCollections.editor.pushedOlderDays",
                            value: $draft.pushedOlderThanDays,
                            range: 1...3_650
                        )
                        if dependencies.entitlementGate.isProUser {
                            optionalIntRow(
                                titleKey: "smartCollections.editor.healthMin",
                                value: $draft.healthScoreMin,
                                range: 0...100
                            )
                            optionalIntRow(
                                titleKey: "smartCollections.editor.healthMax",
                                value: $draft.healthScoreMax,
                                range: 0...100
                            )
                        } else {
                            Text("smartCollections.editor.health.proLocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        triStatePicker(
                            titleKey: "smartCollections.editor.license",
                            value: $draft.requireLicense
                        )
                        triStatePicker(
                            titleKey: "smartCollections.editor.topics",
                            value: $draft.requireTopics
                        )
                        triStatePicker(
                            titleKey: "smartCollections.editor.note",
                            value: $draft.requireNote
                        )
                    }

                    Section {
                        SmartCollectionRuleSummaryView(
                            lines: SmartCollectionRuleSummary.lines(rule: draft, context: summaryContext)
                        )
                        SmartCollectionMatchCountRow(matchCount: matchCount, isLoadingCount: isLoadingCount)
                    } header: {
                        Text("smartCollections.editor.section.preview")
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 8)
            }

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("general.cancel", action: onCancel)
                Button(saveButtonKey, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            if case .create(let defaultName, _) = mode, name.isEmpty {
                name = defaultName
            }
        }
        .task(id: previewTaskID) {
            await reloadPreviewCount()
        }
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
    }

    private var modeTitleKey: LocalizedStringKey {
        switch mode {
        case .create: return "smartCollections.editor.title.create"
        case .edit: return "smartCollections.editor.title.edit"
        }
    }

    private var saveButtonKey: LocalizedStringKey {
        switch mode {
        case .create: return "smartCollections.save.confirm"
        case .edit: return "smartCollections.editor.saveChanges"
        }
    }

    private var scopePicker: some View {
        Picker("smartCollections.editor.scope", selection: scopeSelectionBinding) {
            Text("smartCollections.rule.scope.allStars").tag(ScopeSelection.allStars)
            Text("smartCollections.rule.scope.untagged").tag(ScopeSelection.untagged)
            ForEach(viewModel.languageStats, id: \.language) { stat in
                Text(LanguageDisplayName.shortened(for: stat.language))
                    .tag(ScopeSelection.language(stat.language))
            }
            ForEach(viewModel.tags) { tag in
                Text(tag.name).tag(ScopeSelection.tag(tag.id))
            }
        }
    }

    private enum ScopeSelection: Hashable {
        case allStars
        case untagged
        case language(String)
        case tag(String)
    }

    private var scopeSelectionBinding: Binding<ScopeSelection> {
        Binding(
            get: {
                switch draft.scope {
                case .allStars: return .allStars
                case .untagged: return .untagged
                case .language(let lang): return .language(lang ?? "")
                case .tag(let id): return .tag(id)
                }
            },
            set: { selection in
                switch selection {
                case .allStars: draft.scope = .allStars
                case .untagged: draft.scope = .untagged
                case .language(let lang):
                    draft.scope = .language(lang.isEmpty ? nil : lang)
                case .tag(let id): draft.scope = .tag(id)
                }
            }
        )
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { draft.query ?? "" },
            set: { draft.query = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private var statusBinding: Binding<RepoStatus?> {
        Binding(
            get: { draft.status },
            set: { draft.statusRaw = $0?.rawValue }
        )
    }

    private func tagToggleBinding(_ tagID: String) -> Binding<Bool> {
        Binding(
            get: { draft.selectedTagIDs.contains(tagID) },
            set: { isOn in
                if isOn {
                    if !draft.selectedTagIDs.contains(tagID) {
                        draft.selectedTagIDs.append(tagID)
                    }
                } else {
                    draft.selectedTagIDs.removeAll { $0 == tagID }
                }
            }
        )
    }

    private func triStatePicker(titleKey: LocalizedStringKey, value: Binding<Bool?>) -> some View {
        Picker(titleKey, selection: Binding(
            get: { SmartCollectionTriState.from(optional: value.wrappedValue) },
            set: { value.wrappedValue = $0.optionalBool }
        )) {
            ForEach(SmartCollectionTriState.allCases) { state in
                Text(state.labelKey).tag(state)
            }
        }
    }

    private func optionalIntRow(
        titleKey: LocalizedStringKey,
        value: Binding<Int?>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(titleKey)
            Spacer()
            TextField("smartCollections.editor.optionalPlaceholder", text: optionalIntTextBinding(value, range: range))
                .textFieldStyle(.roundedBorder)
                .frame(width: 88)
                .multilineTextAlignment(.trailing)
        }
    }

    private func optionalIntTextBinding(_ value: Binding<Int?>, range: ClosedRange<Int>) -> Binding<String> {
        Binding(
            get: {
                value.wrappedValue.map(String.init) ?? ""
            },
            set: { newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(8))
                if filtered.isEmpty {
                    value.wrappedValue = nil
                    return
                }
                if let parsed = Int(filtered) {
                    value.wrappedValue = min(max(parsed, range.lowerBound), range.upperBound)
                }
            }
        )
    }

    private func statusIcon(for status: RepoStatus) -> String {
        switch status {
        case .unread: return "envelope.badge"
        case .read: return "envelope.open"
        case .using: return "checkmark.seal"
        }
    }

    private func reloadPreviewCount() async {
        isLoadingCount = true
        defer { isLoadingCount = false }
        matchCount = try? await viewModel.countRepos(matching: draft)
    }

    /// 用 Manage toolbar 当前筛选覆盖 scope / 搜索 / 状态 / 标签 / 隐藏项 / 排序；保留高级 predicate。
    private func importFromCurrentToolbar() {
        guard let toolbarRule = viewModel.makeRuleFromCurrentManageFilters() else { return }
        draft = toolbarRule.mergingAdvanced(from: draft)
    }

    private func save() {
        if draft.usesHealthPredicates {
            do {
                try dependencies.entitlementGate.requirePro(.repoHealth)
            } catch let error as EntitlementGateError {
                paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
                return
            } catch {
                saveError = error.localizedDescription
                return
            }
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        Task {
            do {
                switch mode {
                case .create:
                    let now = ISO8601DateFormatter.shared.string(from: Date())
                    let collection = UserSmartCollection(
                        id: UUID().uuidString,
                        name: trimmedName,
                        icon: "line.3.horizontal.decrease.circle",
                        color: nil,
                        ruleJSON: try SmartCollectionRule.encode(draft),
                        sortOrder: viewModel.userSmartCollections.count,
                        createdAt: now,
                        updatedAt: now
                    )
                    try await dependencies.smartCollectionRepository.create(collection)
                case .edit(let collection):
                    try await viewModel.updateUserSmartCollectionRule(id: collection.id, rule: draft)
                    if collection.name != trimmedName {
                        try await viewModel.renameUserSmartCollection(id: collection.id, name: trimmedName)
                    }
                }
                await viewModel.refreshSidebar()
                onSaved()
            } catch let error as EntitlementGateError {
                paywallContext = ProPaywallContext(feature: error.feature, message: error.localizedDescription)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - 共享命中数行（SmartCollectionSheets 亦使用）

struct SmartCollectionMatchCountRow: View {
    let matchCount: Int?
    let isLoadingCount: Bool

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .opacity(isLoadingCount ? 1 : 0)
                .frame(width: 16, height: 16)

            if let matchCount, !isLoadingCount {
                Text(String(format: String.l10n("smartCollections.rule.matchCountFormat"), locale: locale, matchCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 22, alignment: .leading)
    }
}

private extension SmartCollectionRule {
    static var fallback: SmartCollectionRule {
        SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue,
            starsMin: nil,
            starsMax: nil,
            pushedWithinDays: nil,
            pushedOlderThanDays: nil,
            healthScoreMin: nil,
            healthScoreMax: nil,
            requireLicense: nil,
            requireTopics: nil,
            requireNote: nil
        )
    }
}
