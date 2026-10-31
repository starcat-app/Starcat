//
//  ExploreCatalogSettingsSection.swift
//  Starcat
//
//  通用设置中的探索内容配置：紧凑分类行、选择摘要和自适应子项网格。
//  原生复选框直接修改长期偏好；来源目录只读缓存，不触发 bulk 下载。
//

import SwiftUI

/// 分类启用与展开分开处理：关闭父项保留子选择，重新启用即可恢复。
struct ExploreCatalogSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    /// 展开是临时编辑状态；只保留一个分组，避免两个目录同时撑长通用设置。
    @State private var expandedGroup: String?
    @State private var weeklySources: [WeeklySourceDescriptor] = []
    @State private var dailyRadarCategories: [DailyRadarCatalog.Category] = []

    private var sourceFilters: [WeeklySourceFilter] {
        weeklySources.isEmpty
            ? WeeklySourceFilter.defaultFilters.filter { $0 != .all }
            : weeklySources.map(WeeklySourceFilter.init(descriptor:))
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.explore.content.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(ExploreCatalogPreferences.groupIDs, id: \.self) { id in
                            groupRow(id)
                            if id != ExploreCatalogPreferences.groupIDs.last {
                                Divider()
                            }
                        }
                    }
                    Text("settings.explore.content.minimum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "safari")
                        .font(SettingsIconMetrics.smallGlyph)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    summaryLabel(
                        Text("settings.explore.content.title").font(.body.weight(.semibold)),
                        summary: String(
                            format: String.l10n("settings.explore.content.enabledCountFmt"),
                            locale: locale,
                            settings.exploreCatalogPreferences.visibleGroupIDs.count,
                            ExploreCatalogPreferences.groupIDs.count
                        )
                    )
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.explore.content.title")
            ))
        }
        .task(id: dependencies.databaseScopeRevision) {
            let sources = await dependencies.weeklyBulkRepository.cachedSources()
            guard !Task.isCancelled else { return }
            weeklySources = sources
        }
        .task(id: "\(dependencies.databaseScopeRevision):\(dependencies.dailyRadarConfigurationRevision)") {
            // 设置页只读目录缓存，不为了展示偏好配置触发 bulk 下载。
            let parameters = [
                URLQueryItem(name: "language", value: "en"),
                URLQueryItem(name: "fallback", value: "true")
            ]
            let cached = await dependencies.dailyRadarRepository.cached(
                DailyRadarCatalog.self,
                path: "\(DailyRadarWorkspaceViewModel.root)/catalog",
                parameters: parameters
            )
            guard !Task.isCancelled else { return }
            dailyRadarCategories = cached?.value.categories ?? []
        }
    }

    /// 展开标题与复选框是相邻的独立点击区，避免点击勾选时同时折叠。
    private func groupRow(_ id: String) -> some View {
        let enabled = settings.exploreCatalogPreferences.isGroupEnabled(id)
        let toggle = Toggle(isOn: groupBinding(id)) { Text(verbatim: groupTitle(id)) }
            .toggleStyle(.checkbox)
            .disabled(enabled && settings.exploreCatalogPreferences.visibleGroupIDs.count == 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if id == "discover" || id == "weekly" || id == "dailyRadar" {
                    toggle.labelsHidden()
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            expandedGroup = expandedGroup == id ? nil : id
                        }
                    } label: {
                        HStack(spacing: 8) {
                            summaryLabel(Text(verbatim: groupTitle(id)), summary: groupSummary(id))
                            Image(systemName: expandedGroup == id ? "chevron.down" : "chevron.forward")
                                .font(SettingsIconMetrics.smallGlyph)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel(Text(verbatim: groupTitle(id)))
                    .accessibilityHint(Text(verbatim: groupSummary(id)))
                    .accessibilityValue(Text(expandedGroup == id
                                             ? "settings.general.disclosure.expanded"
                                             : "settings.general.disclosure.collapsed"))
                } else {
                    toggle
                    Spacer(minLength: 8)
                    if id == "awesome" {
                        Button("settings.explore.content.manageSources") {
                            Task { await dependencies.awesomeStore.presentSourceManager() }
                        }
                        .help(Text("settings.explore.content.awesomeHint"))
                        .disabled(!dependencies.authSession.state.isAuthenticated)
                    }
                }
            }
            .frame(minHeight: 36)
            if expandedGroup == id {
                groupChildren(id)
                    .padding(.leading, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .disabled(!enabled)
            }
        }
    }

    /// 长译文或大字号放不下时将摘要移到下一行，不缩小字号或截断计数。
    private func summaryLabel(_ title: Text, summary: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title.fixedSize()
                Spacer(minLength: 0)
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(verbatim: summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 摘要从当前目录和同一份偏好计算；后台新增目录项后数量会自动更新。
    private func groupSummary(_ id: String) -> String {
        let preferences = settings.exploreCatalogPreferences
        if id == "discover" {
            let topics = dependencies.exploreCatalogStore.displayTopics.filter {
                !preferences.hiddenDiscoverTopics.contains($0.code)
            }.count
            let platforms = dependencies.exploreCatalogStore.displayPlatforms.filter {
                !preferences.hiddenDiscoverPlatforms.contains($0.code)
            }.count
            return String(format: String.l10n("settings.explore.content.discoveryCountFmt"),
                          locale: locale, topics, platforms)
        }
        if id == "dailyRadar" {
            let categories = dailyRadarCategories.filter {
                !settings.exploreCatalogPreferences.hiddenDailyRadarCategories.contains($0.id)
            }.count
            guard !dailyRadarCategories.isEmpty else { return String.l10n("settings.explore.content.sourceCountUnavailable") }
            return String(format: String.l10n("settings.explore.content.sourceCountFmt"),
                          locale: locale, categories, dailyRadarCategories.count)
        }
        let sources = sourceFilters.filter { !preferences.hiddenWeeklySources.contains($0.rawValue) }.count
        return String(format: String.l10n("settings.explore.content.sourceCountFmt"),
                      locale: locale, sources, sourceFilters.count)
    }

    /// 网格按可用宽度减列，标签允许自然换行，兼顾窄窗口和较长译文。
    @ViewBuilder
    private func groupChildren(_ id: String) -> some View {
        if id == "discover" {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.explore.content.topics").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12, alignment: .leading)],
                              alignment: .leading, spacing: 8) {
                        ForEach(dependencies.exploreCatalogStore.displayTopics) { topic in
                            let title = ExploreNavigationPresentation.localizedTopicTitle(
                                code: topic.code, fallback: topic.label
                            )
                            Toggle(isOn: childBinding(topic.code, in: \.hiddenDiscoverTopics,
                                                      available: dependencies.exploreCatalogStore.displayTopics.map(\.code))) {
                                Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(isLastChild(topic.code, in: \.hiddenDiscoverTopics,
                                                  available: dependencies.exploreCatalogStore.displayTopics.map(\.code)))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("explore.sidebar.platforms").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12, alignment: .leading)],
                              alignment: .leading, spacing: 8) {
                        ForEach(dependencies.exploreCatalogStore.displayPlatforms) { platform in
                            Toggle(isOn: childBinding(platform.code, in: \.hiddenDiscoverPlatforms,
                                                      available: dependencies.exploreCatalogStore.displayPlatforms.map(\.code))) {
                                Text(verbatim: platform.label).fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(isLastChild(platform.code, in: \.hiddenDiscoverPlatforms,
                                                  available: dependencies.exploreCatalogStore.displayPlatforms.map(\.code)))
                        }
                    }
                }
                Text("settings.explore.content.discoveryHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if id == "weekly" {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(sourceFilters) { source in
                        Toggle(isOn: childBinding(source.rawValue, in: \.hiddenWeeklySources,
                                                  available: sourceFilters.map(\.rawValue))) {
                            Text(verbatim: source.localizedTitle).fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(isLastChild(source.rawValue, in: \.hiddenWeeklySources,
                                              available: sourceFilters.map(\.rawValue)))
                    }
                }
                Text("settings.explore.content.weeklyHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if id == "dailyRadar" {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16, alignment: .leading)],
                          alignment: .leading, spacing: 8) {
                    ForEach(dailyRadarCategories) { category in
                        Toggle(isOn: childBinding(category.id, in: \.hiddenDailyRadarCategories,
                                                  available: dailyRadarCategories.map(\.id))) {
                            Text(verbatim: category.title).fixedSize(horizontal: false, vertical: true)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(isLastChild(category.id, in: \.hiddenDailyRadarCategories,
                                              available: dailyRadarCategories.map(\.id)))
                    }
                }
                Text("settings.explore.content.dailyRadarHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func groupTitle(_ id: String) -> String {
        id == "linuxDo" ? "Linux.do" : ExploreMode(rawValue: id)?.localizedTitle ?? String.l10n("dailyRadar.title")
    }

    /// 最后一项保留选中并置灰，让约束在点击前可见。
    private func isLastChild(
        _ code: String,
        in keyPath: KeyPath<ExploreCatalogPreferences, Set<String>>,
        available: [String]
    ) -> Bool {
        let hidden = settings.exploreCatalogPreferences[keyPath: keyPath]
        return !hidden.contains(code) && available.filter { !hidden.contains($0) }.count == 1
    }

    /// 不联动清空子项；关闭父分组只负责导航显隐。
    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.exploreCatalogPreferences.isGroupEnabled(id) },
            set: { enabled in
                guard enabled || settings.exploreCatalogPreferences.visibleGroupIDs.count > 1 else { return }
                if enabled { settings.exploreCatalogPreferences.hiddenModes.remove(id) }
                else { settings.exploreCatalogPreferences.hiddenModes.insert(id) }
            }
        )
    }

    /// 同组至少保留一项；写回前重新读取偏好，连续点击不会覆盖其它组的选择。
    private func childBinding(
        _ code: String,
        in keyPath: WritableKeyPath<ExploreCatalogPreferences, Set<String>>,
        available: [String]
    ) -> Binding<Bool> {
        Binding(
            get: { !settings.exploreCatalogPreferences[keyPath: keyPath].contains(code) },
            set: { enabled in
                var preferences = settings.exploreCatalogPreferences
                if enabled {
                    preferences[keyPath: keyPath].remove(code)
                } else {
                    guard available.contains(where: {
                        $0 != code && !preferences[keyPath: keyPath].contains($0)
                    }) else { return }
                    preferences[keyPath: keyPath].insert(code)
                }
                settings.exploreCatalogPreferences = preferences
            }
        )
    }
}
