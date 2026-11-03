//
//  SearchIndexSettingsView.swift
//  Starcat
//
//  搜索与索引设置：共享模型只展示摘要，两类索引分别管理。
//  本页仅重组现有配置与构建入口，不改变索引范围、权限或差异判断算法。
//

import SwiftUI

/// 原生分组表单承载已确认的设计；深链继续定位仓库或知识库索引。
struct SearchIndexSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @SceneStorage("settings.ai.aiIndex.advancedExpanded") private var thresholdsExpanded = false

    private static let repositoryAnchor = "settings.ai.index"
    private static let knowledgeAnchor = "settings.ai.knowledgeIndex"

    private var hasAIConfigurationAccess: Bool {
        dependencies.entitlementGate.isProUser || LocalAIHardwareSupport.isLocalAIAvailable
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                SettingsPageIntroduction(
                    title: "settings.navigation.item.searchIndex",
                    systemImage: "magnifyingglass",
                    description: "settings.searchIndex.introduction.description",
                    context: "settings.searchIndex.introduction.context"
                )
                sharedModelSection
                if hasAIConfigurationAccess {
                    RepositoryIndexSettingsSection()
                        .id(Self.repositoryAnchor)
                }
                Section {
                    KnowledgeRAGIndexSettingsSummary(showsControls: true)
                } header: {
                    HStack {
                        SettingsSectionHeader("settings.searchIndex.knowledge.title", systemImage: "books.vertical")
                        Spacer(minLength: 8)
                        Text("settings.searchIndex.layout.knowledgeTagline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("settings.searchIndex.knowledge.help")
                }
                .id(Self.knowledgeAnchor)
                if hasAIConfigurationAccess {
                    resultsSection
                    generationSection
                }
                relatedSection
            }
            .formStyle(.grouped)
            .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIIndexSection)) { _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.repositoryAnchor, anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToKnowledgeIndexSection)) { _ in
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.knowledgeAnchor, anchor: .top)
                }
            }
        }
    }

    /// 不在第二处编辑模型；解析使用与索引器相同的选择逻辑，包含自定义模型。
    private var sharedModelSection: some View {
        let selection = try? settings.resolveEmbeddingSelection()
        return Section {
            // LabeledContent 在 grouped Form 中按首行基线排版；这里显式按整行中心对齐。
            HStack(alignment: .center, spacing: 12) {
                Text("settings.ai.models.embedding.model")
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(selection?.modelName ?? String.l10n("settings.retrieval.index.noModel"))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .help(selection?.modelName ?? String.l10n("settings.retrieval.index.noModel"))
                    if let selection {
                        Text(selection.profile.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .help(selection.profile.displayName)
                    }
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 8)
                Button("settings.ai.taskModels.title") { openSettings("ai.embedding") }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        } header: {
            SettingsSectionHeader("settings.ai.models.embedding.title", systemImage: "cpu")
        } footer: {
            Text("settings.ai.models.embedding.help")
        }
    }

    private var resultsSection: some View {
        Section {
            sliderRow(
                "settings.searchIndex.results.minimumScore",
                value: Binding(
                    get: { settings.aiSemanticSearchScoreThreshold },
                    set: { settings.aiSemanticSearchScoreThreshold = min(1, max(0.10, $0)) }
                ),
                range: 0.10...1,
                step: 0.01,
                readout: percentage(settings.aiSemanticSearchScoreThreshold)
            )
        } header: {
            SettingsSectionHeader("settings.searchIndex.results.title", systemImage: "line.3.horizontal.decrease.circle")
        } footer: {
            Text("settings.aiIndex.scoreThreshold.hint")
        }
    }

    private var generationSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("settings.aiIndex.autoPrefetch", isOn: $settings.aiIndexAutoPrefetchEnabled)
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 6) {
                sliderRow(
                    "settings.aiIndex.truncateLength",
                    value: Binding(
                        get: { Double(settings.aiReadmeTruncateLength) },
                        set: { settings.aiReadmeTruncateLength = min(32000, max(2000, Int($0.rounded()))) }
                    ),
                    range: 2000...32000,
                    step: 1000,
                    readout: settings.aiReadmeTruncateLength.formatted(.number.locale(locale))
                )
                Text("settings.aiIndex.truncateLength.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.searchIndex.rules.title")
                    Text("settings.searchIndex.rules.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(Text("settings.searchIndex.rules.help"))
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                // 与任务选择行一致：按文案测量分段宽度，长译文放不下时在原位使用菜单。
                ViewThatFits(in: .horizontal) {
                    rebuildPresetPicker
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    rebuildPresetPicker
                        .pickerStyle(.menu)
                }
            }
            DisclosureGroup(isExpanded: $thresholdsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if settings.aiIndexPreset != .custom {
                        Text("settings.aiIndex.advanced.lockedHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    sliderRow(
                        "settings.aiIndex.bodyThreshold",
                        value: ratioBinding(isBody: true),
                        range: 0.01...0.90,
                        step: 0.01,
                        readout: percentage(settings.aiIndexThresholds.bodyDiffRatio)
                    )
                    .disabled(settings.aiIndexPreset != .custom)
                    Divider()
                    sliderRow(
                        "settings.aiIndex.notesThreshold",
                        value: ratioBinding(isBody: false),
                        range: 0.01...0.90,
                        step: 0.01,
                        readout: percentage(settings.aiIndexThresholds.notesDiffRatio)
                    )
                    .disabled(settings.aiIndexPreset != .custom)
                    Text("settings.searchIndex.thresholds.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                HStack(spacing: 8) {
                    Text("settings.searchIndex.thresholds.title")
                    Spacer(minLength: 8)
                    Text("\(percentage(settings.aiIndexThresholds.bodyDiffRatio)) / \(percentage(settings.aiIndexThresholds.notesDiffRatio))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.searchIndex.thresholds.title")
            ))
        } header: {
            SettingsSectionHeader("settings.searchIndex.generation.title", systemImage: "slider.horizontal.3")
        }
        .onAppear {
            if settings.aiIndexPreset == .custom { thresholdsExpanded = true }
        }
        .onChange(of: settings.aiIndexPreset) { _, preset in
            if preset == .custom { thresholdsExpanded = true }
        }
    }

    /// 只调整控件呈现；预设应用和自定义阈值自动展开继续使用原绑定。
    private var rebuildPresetPicker: some View {
        Picker("settings.searchIndex.rules.title", selection: Binding(
            get: { settings.aiIndexPreset },
            set: { preset in
                settings.applyAIIndexPreset(preset)
                if preset == .custom { thresholdsExpanded = true }
            }
        )) {
            ForEach(AIIndexPreset.allCases, id: \.self) { preset in
                Text(LocalizedStringKey(preset.displayNameKey)).tag(preset)
            }
        }
        .labelsHidden()
    }

    private var relatedSection: some View {
        Section {
            relatedRow(
                "rag.workspace.settings.section.retrieval",
                hint: "settings.searchIndex.related.retrieval",
                systemImage: "magnifyingglass",
                target: "rag.retrieval"
            )
            relatedRow(
                "ai.context.settings.title",
                hint: "settings.searchIndex.related.context",
                systemImage: "chevron.left.forwardslash.chevron.right",
                target: "ai.repoContext"
            )
        } header: {
            SettingsSectionHeader("settings.searchIndex.related.title", systemImage: "link")
        }
    }

    /// 与其他主设置页共用同行滑条和读数列，保持同组轨道长度一致。
    private func sliderRow(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        readout: String
    ) -> some View {
        SettingsSliderRow(title: title, value: value, range: range, step: step, readout: readout)
    }

    /// 非自定义预设只读，避免显示固定预设时写入一份不生效的自定义数字。
    private func ratioBinding(isBody: Bool) -> Binding<Double> {
        Binding(
            get: {
                isBody ? settings.aiIndexThresholds.bodyDiffRatio : settings.aiIndexThresholds.notesDiffRatio
            },
            set: { value in
                guard settings.aiIndexPreset == .custom else { return }
                let value = min(0.90, max(0.01, value))
                if isBody { settings.aiIndexBodyDiffRatio = value }
                else { settings.aiIndexNotesDiffRatio = value }
            }
        )
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// 使用现有设置路由，保留各目标页面的定位和生命周期。
    private func openSettings(_ target: String) {
        NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: target)
    }

    private func relatedRow(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey,
        systemImage: String,
        target: String
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("settings.searchIndex.related.open") { openSettings(target) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
        }
    }
}
