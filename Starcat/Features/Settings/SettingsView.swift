//
//  SettingsView.swift
//  Starcat
//
//  macOS 标准设置窗口（Cmd+,）。
//
//  Week 3 范围：
//  - General 标签：列表密度
//
//  Week 4+ 计划新增：
//  - Sync 标签：自动同步频率、同步范围
//  - AI 标签：BYOK key、模型选择
//  - About 标签：版本、许可、致谢
//
//  设计约束：
//  - 用 macOS 原生 TabView + Form，配 .formStyle(.grouped) 自动获得分组卡片样式
//  - 控件直接绑定到 AppSettings 的 @Observable 属性，写入即落盘
//

import SwiftUI

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("settings.general.title", systemImage: "gearshape")
                }
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
                .tabItem {
                    Label("settings.storage.title", systemImage: "internaldrive")
                }
        }
        .frame(width: 520, height: 360)
        .scenePadding()
    }

    private var generalTab: some View {
        @Bindable var settings = settings

        return Form {
            Section("settings.general.appearance") {
                Picker("settings.general.listDensity", selection: $settings.listDensity) {
                    ForEach(RepoListDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)

                Text("settings.general.listDensity.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - W4-4 D4：存储 Tab

/// 缓存统计与清理面板。
///
/// 独立 View 是为了把 CacheCleaner 的生命周期收敛在 Tab 内:
/// - Tab 出现时 onAppear 加载统计
/// - 用户清理后立即重新加载,UI 立刻反映新状态
///
/// 清理操作有 confirmationDialog 兜底,避免误点。
private struct StorageSettingsTab: View {

    let readmeRepository: ReadmeRepository

    @State private var stats: CacheStatistics = .empty
    @State private var isWorking: Bool = false
    /// 当前显示的确认弹窗类型;nil 表示不显示。
    @State private var pendingAction: PendingAction?

    /// 清理操作类型。每种类型有不同的确认文案与执行路径。
    private enum PendingAction: Identifiable {
        case readme, image, all
        var id: String {
            switch self {
            case .readme: return "readme"
            case .image:  return "image"
            case .all:    return "all"
            }
        }
        var confirmTitleKey: String {
            switch self {
            case .readme: return "settings.storage.clearReadme.confirm"
            case .image:  return "settings.storage.clearImage.confirm"
            case .all:    return "settings.storage.clearAll.confirm"
            }
        }
        var confirmMessageKey: String {
            switch self {
            case .readme: return "settings.storage.clearReadme.message"
            case .image:  return "settings.storage.clearImage.message"
            case .all:    return "settings.storage.clearAll.message"
            }
        }
    }

    var body: some View {
        let cleaner = CacheCleaner(readmeRepository: readmeRepository)
        return Form {
            Section("settings.storage.cacheUsage") {
                LabeledContent("settings.storage.readme") {
                    Text("\(stats.readmeCount) 条 · \(stats.readmeBytes.formattedByteSize)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("settings.storage.image") {
                    Text(Int64(stats.imageDiskBytes).formattedByteSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("settings.storage.log") {
                    Text("settings.storage.logDescription")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
                .help("Starcat 通过 OSLog 写日志,清理与查询请用 macOS 自带的 Console.app")
            }

            Section("settings.storage.clear") {
                Button("settings.storage.clearReadme") { pendingAction = .readme }
                    .disabled(isWorking || stats.readmeCount == 0)
                Button("settings.storage.clearImage") { pendingAction = .image }
                    .disabled(isWorking || stats.imageDiskBytes == 0)
                Button("settings.storage.clearAll", role: .destructive) { pendingAction = .all }
                    .disabled(isWorking || stats.totalBytes == 0)
            }

            if isWorking {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("settings.storage.clearing")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            stats = await cleaner.loadStatistics()
        }
        .confirmationDialog(
            pendingAction?.confirmTitleKey ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button("general.clear", role: .destructive) {
                Task { await perform(action: action, using: cleaner) }
            }
            Button("general.cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.confirmMessageKey)
        }
    }

    /// 执行清理 + 重新加载统计。UI state 全程在 main actor。
    @MainActor
    private func perform(action: PendingAction, using cleaner: CacheCleaner) async {
        isWorking = true
        switch action {
        case .readme: await cleaner.clearReadmes()
        case .image:  await cleaner.clearImageCache()
        case .all:    await cleaner.clearAll()
        }
        stats = await cleaner.loadStatistics()
        isWorking = false
        pendingAction = nil
    }
}
