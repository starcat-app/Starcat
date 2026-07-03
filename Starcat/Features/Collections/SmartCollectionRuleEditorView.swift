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

/// 表单输入框统一宽度（label 左 / 输入框右，无 dash 分隔符）。
///
/// **为什么不用 SwiftUI Form**：`.formStyle(.grouped)` 会自动把"label Text + Control"识别为 LabeledContent
/// 并插入 dash 分隔符，该规则覆盖 `HStack` / `Grid + GridRow` 等多种容器，无法关闭。
/// 因此整个表单改用 `ScrollView + VStack + 自定义 FormSection / FormRow` 实现，
/// 完全绕开 Form 的隐式布局逻辑。
private let smartCollectionInputFieldWidth: CGFloat = 400

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
    /// 仅首次预览计数前为 true；后续 debounce 刷新静默更新数字，不再闪 spinner。
    @State private var isLoadingCount = false
    @State private var previewReloadGeneration = 0
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
            _draft = State(initialValue: collection.rule ?? SmartCollectionRule.baseline)
            _name = State(initialValue: collection.name)
        }
    }

    private var summaryContext: SmartCollectionRuleSummary.Context {
        viewModel.smartCollectionSummaryContext()
    }

    private var previewTaskID: String {
        if let encoded = try? SmartCollectionRule.encode(draft) {
            return encoded
        }
        // encode 失败时用 scope + 基础字段拼稳定 key，避免 UUID 导致 task 无限重启。
        return "\(draft.scope)-\(draft.sortRaw)-\(draft.hideArchived)-\(draft.hideForks)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(modeTitleKey)
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    // 名称：不带 Section header（label 行充当）
                    FormSection(titleKey: nil) {
                        FormRow {
                            Text("smartCollections.editor.section.name")
                                .lineLimit(1)
                        } control: {
                            TextField("smartCollections.save.name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: smartCollectionInputFieldWidth)
                        }
                    }

                    // 预设模板
                    FormSection(titleKey: "smartCollections.editor.section.presets") {
                        VStack(alignment: .leading, spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(SmartCollectionKind.allCases.filter(\.supportsUserRuleTemplate)) { kind in
                                        Button {
                                            applyPreset(kind)
                                        } label: {
                                            Text(kind.titleKey)
                                                .font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                        .focusEffectDisabled()
                                    }
                                }
                            }
                            Text("smartCollections.editor.presets.hint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                    }

                    // 范围
                    FormSection(titleKey: "smartCollections.editor.section.scope") {
                        FormRow {
                            Text("smartCollections.editor.scope")
                                .lineLimit(1)
                        } control: {
                            scopePicker
                                .labelsHidden()
                        }
                    }

                    // 搜索：不带 Section header（label 行充当）
                    FormSection(titleKey: nil) {
                        FormRow {
                            Text("smartCollections.editor.section.search")
                                .lineLimit(1)
                        } control: {
                            TextField("smartCollections.editor.search.placeholder", text: searchQueryBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: smartCollectionInputFieldWidth)
                        }
                        FormRow {
                            Text("smartCollections.editor.search.mode")
                                .lineLimit(1)
                        } control: {
                            Picker("", selection: $draft.searchModeRaw) {
                                ForEach(SmartSearchMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode.rawValue)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    // 筛选
                    FormSection(titleKey: "smartCollections.editor.section.filters") {
                        HStack {
                            Spacer()
                            Button("smartCollections.editor.importFromToolbar") {
                                importFromCurrentToolbar()
                            }
                            .disabled(viewModel.makeRuleFromCurrentManageFilters() == nil)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        FormRow {
                            Text("list.filter.status").lineLimit(1)
                        } control: {
                            Picker("", selection: statusBinding) {
                                Label("general.all", systemImage: "tray.full").tag(Optional<RepoStatus>.none)
                                ForEach(RepoStatus.allCases, id: \.self) { status in
                                    Label(status.displayName, systemImage: statusIcon(for: status))
                                        .tag(Optional<RepoStatus>.some(status))
                                }
                            }
                            .labelsHidden()
                        }
                        FormRow {
                            Text("settings.general.hideArchived").lineLimit(1)
                        } control: {
                            Toggle("", isOn: $draft.hideArchived).labelsHidden()
                        }
                        FormRow {
                            Text("settings.general.hideForks").lineLimit(1)
                        } control: {
                            Toggle("", isOn: $draft.hideForks).labelsHidden()
                        }
                        FormRow {
                            Text("list.sort").lineLimit(1)
                        } control: {
                            Picker("", selection: $draft.sortRaw) {
                                ForEach(RepoSortOption.manageOptions) { option in
                                    Text(option.displayName).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    if !viewModel.languageStats.isEmpty {
                        FormSection(titleKey: nil) {
                            SmartCollectionMultiSelectField(
                                titleKey: "smartCollections.editor.section.languages",
                                showsInlineTitle: true,
                                selectedIDs: $draft.filterLanguages,
                                options: viewModel.languageStats.map {
                                    SmartCollectionMultiSelectOption(
                                        id: $0.language,
                                        label: languageOptionLabel(for: $0)
                                    )
                                }
                            )
                        }
                    }

                    if !viewModel.tags.isEmpty {
                        FormSection(titleKey: "smartCollections.editor.section.tags") {
                            FormRow {
                                Text("smartCollections.editor.tagMatchMode").lineLimit(1)
                            } control: {
                                Picker("", selection: $draft.tagMatchModeRaw) {
                                    Text("smartCollections.editor.tagMatch.any").tag(SmartCollectionTagMatchMode.any.rawValue)
                                    Text("smartCollections.editor.tagMatch.all").tag(SmartCollectionTagMatchMode.all.rawValue)
                                }
                                .labelsHidden()
                            }
                            SmartCollectionMultiSelectField(
                                titleKey: "smartCollections.editor.tags.include",
                                selectedIDs: $draft.selectedTagIDs,
                                options: viewModel.tags.map {
                                    SmartCollectionMultiSelectOption(id: $0.id, label: $0.name)
                                }
                            )
                            SmartCollectionMultiSelectField(
                                titleKey: "smartCollections.editor.tags.exclude",
                                selectedIDs: $draft.excludedTagIDs,
                                options: viewModel.tags.map {
                                    SmartCollectionMultiSelectOption(id: $0.id, label: $0.name)
                                }
                            )
                        }
                    }

                    // 热度
                    FormSection(titleKey: "smartCollections.editor.section.popularity") {
                        optionalIntRow(titleKey: "smartCollections.editor.starsMin", value: $draft.starsMin, range: 0...1_000_000)
                        optionalIntRow(titleKey: "smartCollections.editor.starsMax", value: $draft.starsMax, range: 0...1_000_000)
                        optionalIntRow(titleKey: "smartCollections.editor.forksMin", value: $draft.forksMin, range: 0...1_000_000)
                        optionalIntRow(titleKey: "smartCollections.editor.forksMax", value: $draft.forksMax, range: 0...1_000_000)
                        optionalIntRow(titleKey: "smartCollections.editor.watchersMin", value: $draft.watchersMin, range: 0...1_000_000)
                        optionalIntRow(titleKey: "smartCollections.editor.watchersMax", value: $draft.watchersMax, range: 0...1_000_000)
                    }

                    // 活跃度
                    FormSection(titleKey: "smartCollections.editor.section.activity") {
                        optionalIntRow(titleKey: "smartCollections.editor.pushedWithinDays", value: $draft.pushedWithinDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.pushedOlderDays", value: $draft.pushedOlderThanDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.starredWithinDays", value: $draft.starredWithinDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.starredOlderDays", value: $draft.starredOlderThanDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.updatedWithinDays", value: $draft.updatedWithinDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.updatedOlderDays", value: $draft.updatedOlderThanDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.createdWithinDays", value: $draft.createdWithinDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.createdOlderDays", value: $draft.createdOlderThanDays, range: 1...3_650)
                        optionalIntRow(titleKey: "smartCollections.editor.releaseWithinDays", value: $draft.releaseWithinDays, range: 1...3_650)
                    }

                    // 内容
                    FormSection(titleKey: "smartCollections.editor.section.content") {
                        triStatePicker(titleKey: "smartCollections.editor.description", value: $draft.requireDescription)
                        triStatePicker(titleKey: "smartCollections.editor.homepage", value: $draft.requireHomepage)
                        triStatePicker(titleKey: "smartCollections.editor.license", value: $draft.requireLicense)
                        topicsRow
                        triStatePicker(titleKey: "smartCollections.editor.note", value: $draft.requireNote)
                    }

                    // 仓库健康度
                    FormSection(titleKey: "smartCollections.editor.section.repoHealth") {
                        if dependencies.entitlementGate.isProUser {
                            optionalIntRow(titleKey: "smartCollections.editor.healthMin", value: $draft.healthScoreMin, range: 0...100)
                            optionalIntRow(titleKey: "smartCollections.editor.healthMax", value: $draft.healthScoreMax, range: 0...100)
                            SmartCollectionGradePicker(selectedGrades: $draft.healthGrades)
                        } else {
                            Text("smartCollections.editor.health.proLocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }

                    // 质量
                    FormSection(titleKey: "smartCollections.editor.section.quality") {
                        if dependencies.entitlementGate.isProUser {
                            optionalIntRow(titleKey: "smartCollections.editor.maintenanceMin", value: $draft.maintenanceScoreMin, range: 0...100)
                            optionalIntRow(titleKey: "smartCollections.editor.popularityHealthMin", value: $draft.popularityScoreMin, range: 0...100)
                            optionalIntRow(titleKey: "smartCollections.editor.qualityMin", value: $draft.qualityScoreMin, range: 0...100)
                            optionalIntRow(titleKey: "smartCollections.editor.securityMin", value: $draft.securityScoreMin, range: 0...100)
                        } else {
                            Text("smartCollections.editor.qualityDimensions.proLocked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                        optionalIntRow(titleKey: "smartCollections.editor.openSSFMin", value: $draft.openSSFScoreMin, range: 0...10)
                    }

                    if draft.searchMode == .semantic {
                        FormSection(titleKey: "smartCollections.editor.section.semantic") {
                            optionalIntRow(titleKey: "smartCollections.editor.semanticMin", value: $draft.semanticScoreMin, range: 0...100)
                        }
                    }

                    // 预览
                    FormSection(titleKey: "smartCollections.editor.section.preview") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(SmartCollectionRuleValidation.warnings(for: draft), id: \.self) { warning in
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            SmartCollectionRuleSummaryView(
                                lines: SmartCollectionRuleSummary.lines(rule: draft, context: summaryContext)
                            )
                            SmartCollectionMatchCountRow(
                                matchCount: matchCount,
                                isLoadingCount: isLoadingCount
                            )
                        }
                        .padding(12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
        .frame(width: 560, height: 720)
        .onAppear {
            if case .create(let defaultName, _) = mode, name.isEmpty {
                name = defaultName
            }
        }
        .task(id: previewTaskID) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            previewReloadGeneration += 1
            let generation = previewReloadGeneration
            await reloadPreviewCount(expectedGeneration: generation)
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
                Text(languageOptionLabel(for: stat))
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

    private var topicContainsBinding: Binding<String> {
        Binding(
            get: { draft.topicContains ?? "" },
            set: { newValue in
                let filtered = String(newValue.prefix(80))
                let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.topicContains = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var topicsRow: some View {
        FormRow {
            Text("smartCollections.editor.topics")
                .lineLimit(1)
        } control: {
            TextField("", text: topicContainsBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: smartCollectionInputFieldWidth)
        }
    }

    private func languageOptionLabel(for stat: LanguageStat) -> String {
        if stat.language.isEmpty {
            return String.l10n("smartCollections.rule.scope.uncategorizedLanguage")
        }
        return LanguageDisplayName.shortened(for: stat.language)
    }

    private func applyPreset(_ kind: SmartCollectionKind) {
        let preservedName = name
        draft = SmartCollectionRule.template(for: kind)
        if case .create = mode,
           preservedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = SmartCollectionRule.defaultName(for: kind)
        }
    }

    private func triStatePicker(titleKey: LocalizedStringKey, value: Binding<Bool?>) -> some View {
        FormRow {
            Text(titleKey).lineLimit(1)
        } control: {
            Picker("", selection: Binding(
                get: { SmartCollectionTriState.from(optional: value.wrappedValue) },
                set: { value.wrappedValue = $0.optionalBool }
            )) {
                ForEach(SmartCollectionTriState.allCases) { state in
                    Text(state.labelKey).tag(state)
                }
            }
            .labelsHidden()
        }
    }

    private func optionalIntRow(
        titleKey: LocalizedStringKey,
        value: Binding<Int?>,
        range: ClosedRange<Int>
    ) -> some View {
        FormRow {
            Text(titleKey)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } control: {
            TextField("smartCollections.editor.optionalPlaceholder", text: optionalIntTextBinding(value, range: range))
                .textFieldStyle(.roundedBorder)
                .frame(width: smartCollectionInputFieldWidth)
                .multilineTextAlignment(.trailing)
        }
    }

    private func optionalIntTextBinding(_ value: Binding<Int?>, range: ClosedRange<Int>) -> Binding<String> {
        Binding(
            get: {
                value.wrappedValue.map(String.init) ?? ""
            },
            set: { newValue in
                let maxDigits = String(range.upperBound).count
                let filtered = String(newValue.filter(\.isNumber).prefix(maxDigits))
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

    private func reloadPreviewCount(expectedGeneration: Int) async {
        guard !Task.isCancelled else { return }

        let isInitialLoad = matchCount == nil
        if isInitialLoad {
            isLoadingCount = true
        }
        defer {
            if isInitialLoad {
                isLoadingCount = false
            }
        }

        guard let count = try? await viewModel.countRepos(matching: draft) else { return }
        guard !Task.isCancelled, expectedGeneration == previewReloadGeneration else { return }
        matchCount = count
    }

    /// 用 Manage toolbar 当前筛选覆盖 scope / 搜索 / 状态 / 标签 / 隐藏项 / 排序；保留高级 predicate。
    private func importFromCurrentToolbar() {
        guard let toolbarRule = viewModel.makeRuleFromCurrentManageFilters() else { return }
        draft = toolbarRule.mergingAdvanced(from: draft)
    }

    private func save() {
        if draft.usesProPredicates {
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
                    let existing = try await dependencies.smartCollectionRepository.fetchAll()
                    let collection = UserSmartCollection(
                        id: UUID().uuidString,
                        name: trimmedName,
                        icon: "line.3.horizontal.decrease.circle",
                        color: nil,
                        ruleJSON: try SmartCollectionRule.encode(draft),
                        sortOrder: existing.count,
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

// MARK: - 自定义 Form 组件（替代 SwiftUI Form）

/// 自定义分组容器：圆角背景 + 可选 header。
///
/// **替代 SwiftUI Form 的原因**：`.formStyle(.grouped)` 自动把"label Text + Control"识别为
/// LabeledContent 并插入 dash 分隔符，该规则覆盖 `HStack` / `Grid + GridRow`，且无法关闭。
/// 自己实现 Section + Row 才能保证视觉一致。
private struct FormSection<Content: View>: View {
    let titleKey: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let titleKey {
                Text(titleKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

/// 单行：label 左 / 控件右，底部自带 Divider（被 FormSection 的 clipShape 裁掉最后一行的多余 Divider）。
private struct FormRow<Label: View, Control: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                label()
                    .frame(maxWidth: .infinity, alignment: .leading)
                control()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().padding(.leading, 12)
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
            if let matchCount {
                Text(String(format: String.l10n("smartCollections.rule.matchCountFormat"), locale: locale, matchCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.15), value: matchCount)
            } else if isLoadingCount {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 22, alignment: .leading)
    }
}
