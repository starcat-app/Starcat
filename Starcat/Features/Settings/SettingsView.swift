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

    @State private var selectedTab: SettingsTab = .general

    /// Settings 各 Tab 的内容尺寸。
    ///
    /// AI 服务页已经从单 Provider 表单升级成“服务商 / 模型列表 / 任务模型 / 参数 / Prompt”
    /// 的复合配置面板。继续沿用 520×360 会让横向控件和 Prompt 编辑区明显被裁切；
    /// 但把所有 Settings Tab 永久放大会让通用 / 存储页显得空。这里按 Tab 动态给内容尺寸，
    /// 让 AI 页获得更大的默认空间，其它页保持 macOS 设置窗口的紧凑感。
    private enum SettingsTab: Hashable {
        case general
        case ai
        case storage

        var contentSize: CGSize {
            switch self {
            case .general, .storage:
                return CGSize(width: 520, height: 360)
            case .ai:
                return CGSize(width: 760, height: 760)
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label("settings.general.title", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
            AISettingsTab()
                .tabItem {
                    Label("settings.ai.title", systemImage: "sparkles")
                }
                .tag(SettingsTab.ai)
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
                .tabItem {
                    Label("settings.storage.title", systemImage: "internaldrive")
                }
                .tag(SettingsTab.storage)
        }
        .frame(width: selectedTab.contentSize.width, height: selectedTab.contentSize.height)
        .scenePadding()
        .animation(.easeInOut(duration: 0.18), value: selectedTab)
    }

    private var generalTab: some View {
        @Bindable var settings = settings

        return Form {
            Section("settings.general.appearance") {
                // W4-5 D1:主题切换(dong4j 2026-06-03 需求,默认 .dark)。
                // 用 Label + segmented 让 3 个选项的图标可见(circle.lefthalf / sun.max / moon.fill),
                // 跟 macOS "系统设置 → 外观" 的视觉语言一致,降低用户认知成本。
                //
                // 过渡动画(W4-5 D1 follow-up,2026-06-03):用自定义 binding 把 setter 包到
                // `withAnimation(.easeInOut(0.3))` transaction 里,让依赖 colorScheme 计算的
                // SwiftUI 视图(动态颜色 / 材质 / 文字色)切换时带 0.3s 淡变,而非瞬切。
                //
                // 关键约束:① macOS NSWindow titlebar / chrome 由 AppKit 即时切换,SwiftUI 动画
                // 系统覆盖不到,所以 titlebar 仍是瞬切;② 视图内容区(.background / .foregroundStyle
                // 走动态色的)会跟随 transaction 平滑过渡;③ `@Observable` 属性在 withAnimation
                // 块内修改会被收进 transaction,这与 `@Published` 的行为一致,验证过。
                Picker("settings.general.appearanceMode", selection: Binding(
                    get: { settings.appearanceMode },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.6)) {
                            settings.appearanceMode = newValue
                        }
                    }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("settings.general.appearanceMode.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

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

            // HOM-SNAKE-MODES 2026-06-05：贡献草坪贪吃蛇玩法。
            // 用 Menu 风格 Picker 而非 segmented——6 个选项 segmented 会过宽，
            // 而且每项都带 SF Symbol，菜单展开形态视觉信息密度更高。
            // 设计取舍：把贪吃蛇配置放在 General 而非新建 "Sidebar" Tab，是因为
            // 当前 Sidebar 可配置项只有这一个，单独开 Tab 显得空；后续若新增
            // sidebar 偏好（如折叠默认态、密度）再拆分。
            Section("settings.snakeStyle.section") {
                Picker(selection: $settings.snakeStyle) {
                    ForEach(SnakeStyle.allCases) { style in
                        Label(LocalizedStringKey(style.displayNameKey),
                              systemImage: style.systemImage)
                            .tag(style)
                    }
                } label: {
                    Text("settings.snakeStyle.title")
                }
                .pickerStyle(.menu)

                Text("settings.snakeStyle.description")
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
            case .readme: return String(localized: "settings.storage.clearReadme.confirm")
            case .image:  return String(localized: "settings.storage.clearImage.confirm")
            case .all:    return String(localized: "settings.storage.clearAll.confirm")
            }
        }
        var confirmMessageKey: LocalizedStringKey {
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
                    Text(readmeUsageText)
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
                .help(Text("settings.storage.logHelp"))
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
            pendingAction?.confirmTitle ?? "",
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

    private var readmeUsageText: String {
        String(
            format: String(localized: "settings.storage.readmeUsageFormat"),
            stats.readmeCount,
            stats.readmeBytes.formattedByteSize
        )
    }
}
