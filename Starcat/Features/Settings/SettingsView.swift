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
                    Label("通用", systemImage: "gearshape")
                }
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
                .tabItem {
                    Label("存储", systemImage: "internaldrive")
                }
        }
        .frame(width: 520, height: 360)
        .scenePadding()
    }

    private var generalTab: some View {
        @Bindable var settings = settings

        return Form {
            Section("外观") {
                Picker("列表密度", selection: $settings.listDensity) {
                    ForEach(RepoListDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.segmented)

                Text("紧凑：单行显示更多仓库；卡片：每行带头像与描述。")
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
        var confirmTitle: String {
            switch self {
            case .readme: return "清空 README 缓存?"
            case .image:  return "清空图片缓存?"
            case .all:    return "清空全部缓存?"
            }
        }
        var confirmMessage: String {
            switch self {
            case .readme: return "下次浏览仓库时会重新从 GitHub 抓取。"
            case .image:  return "头像与缩略图会在列表滚动时重新下载。"
            case .all:    return "等同于同时清 README + 图片。"
            }
        }
    }

    var body: some View {
        let cleaner = CacheCleaner(readmeRepository: readmeRepository)
        return Form {
            Section("缓存用量") {
                LabeledContent("README 缓存") {
                    Text("\(stats.readmeCount) 条 · \(stats.readmeBytes.formattedByteSize)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("图片缓存(Kingfisher)") {
                    Text(Int64(stats.imageDiskBytes).formattedByteSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("日志") {
                    Text("由系统(Console.app)管理")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
                .help("Starcat 通过 OSLog 写日志,清理与查询请用 macOS 自带的 Console.app")
            }

            Section("清理操作") {
                Button("清理 README 缓存") { pendingAction = .readme }
                    .disabled(isWorking || stats.readmeCount == 0)
                Button("清理图片缓存") { pendingAction = .image }
                    .disabled(isWorking || stats.imageDiskBytes == 0)
                Button("清理全部缓存", role: .destructive) { pendingAction = .all }
                    .disabled(isWorking || stats.totalBytes == 0)
            }

            if isWorking {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在清理…")
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
            pendingAction?.confirmTitle ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button("清空", role: .destructive) {
                Task { await perform(action: action, using: cleaner) }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.confirmMessage)
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
