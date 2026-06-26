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

import AppKit
import SwiftUI

// MARK: - 跨 Tab 跳转事件
//
// 2026-06-13 Y3/Y5：AISettingsTab 的「管理已生成的上下文 →」按钮需要把
// settings 窗口从 .ai 切到 .storage。SettingsView 当前用 @State 自管
// selectedTab，没有外部入口可以直接改它的值；项目惯例（见 ReadmeViewModel /
// RepoNote）是「跨 View 通信用 Notification.Name」，于是在 settings feature
// 模块内部约定一个事件名：发起方 (AISettingsView) post，接收方 (SettingsView
// .onReceive) 读取 object: String 决定切到哪个 tag。
//
// 关键约束：
//   1. object 用 String 而不是 enum——避免 AISettingsView 反向依赖 SettingsView
//      内部的 SettingsTab（那是 private enum）；
//   2. 未识别的 object 字符串直接忽略，不 crash；
//   3. 名字加 `starcat.` 前缀防止与系统 / 三方框架冲突。
extension Notification.Name {
/// 跨 Settings Tab 跳转。`object: String` 取值：`"general"` / `"storage"` /
    /// `"pro"` / `"ai"` / `"services"` / `"integrations"` / `"diagnostics"`。
    static let starcatJumpToSettingsTab: Notification.Name = .init("starcat.settings.jumpToTab")
}

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    /// 2026-06-15:用于在主题切换的 withAnimation 处兜底跳过动画。
    /// 系统「减少动态效果」或用户「关闭应用内动画」任一为真时生效
    /// (root view 的 `AnimationOverrideModifier` 已 OR 合并)。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 2026-06-15 dong4j 需求:用户面向的语言切换状态容器。
    /// `LocaleStore` 是 `@MainActor @Observable` 单例,主窗口与 Settings 共享同一份;
    /// `@Bindable` 让下方 Picker 可以直接 `$localeStore.selection` 双向绑定。
    @State private var localeStore = LocaleStore.shared

    @State private var selectedTab: SettingsTab = .general
    /// 快捷键录制失败时只在 General 页就地提示，不修改已保存配置。
    @State private var shortcutValidationError: KeyboardShortcutConfiguration.ValidationError?

    /// Settings 各 Tab 的内容尺寸。
    ///
    /// HOM-68 follow-up v12 (dong4j 反馈 2026-06-06 00:32)：
    /// AI 页早期内容铺满（任务模型 4 行 + 模型参数 6 行 + 双 Prompt 编辑区），
    /// 一度需要单独放大到 760×760。v7–v9 把"模型配置 / 已发现模型 / Prompt"
    /// 都改成 DisclosureGroup 默认折叠 + 把"模型参数"迁到 popover 后，AI 页
    /// 折叠态高度已经收回到与通用 / 存储相当，没必要再单独占一档尺寸。统一回
    /// 520×360，与 macOS 设置窗口惯例一致；折叠组展开后 Form 自带垂直滚动，
    /// 不会被裁切。
    private enum SettingsTab: Hashable {
        case general
        case pro
        case ai
        case mcp
        /// 2026-06-08 新增：第三方 / 自建后端服务的 URL 配置。
        case services
        /// 直接嵌入 Starcat 的第三方工具，与后端服务配置分开管理。
        case integrations
        case storage
        case diagnostics
    }

    /// 统一的内容尺寸——所有 Tab 共用，避免切 Tab 时窗口尺寸跳变。
    /// 2026-06-08 调整：Services Tab 含 3 个服务卡片（每张约 130pt），加 intro 段后
    /// 360pt 已经放不下，提到 460；其它 Tab 在 460 高度下 Form 仍正常显示。
    private static let contentSize = CGSize(width: 540, height: 460)

    var body: some View {
        // 2026-06-19：Tab 顺序按"用户决策优先、底层维护靠后"重排。
        // Pro 是订阅 / 权益入口，会影响 AI、搜索增强、Release 等多处功能的可用性，
        // 因此紧跟通用设置；AI / 服务 / 集成属于能力配置；存储是低频维护项，放末尾。
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label("settings.general.title", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
            ProSettingsTab()
                .tabItem {
                    Label("Pro", systemImage: "crown.fill")
                }
                .tag(SettingsTab.pro)
            AISettingsTab()
                .tabItem {
                    Label("settings.ai.title", systemImage: "sparkles")
                }
                .tag(SettingsTab.ai)
            MCPSettingsTab()
                .tabItem {
                    Label("settings.mcp.title", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(SettingsTab.mcp)
            ServicesSettingsTab()
                .tabItem {
                    Label("settings.services.title", systemImage: "network")
                }
                .tag(SettingsTab.services)
            IntegrationSettingsTab()
                .tabItem {
                    Label("settings.integrations.title", systemImage: "puzzlepiece.extension")
                }
                .tag(SettingsTab.integrations)
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
                .tabItem {
                    Label("settings.storage.title", systemImage: "internaldrive")
                }
                .tag(SettingsTab.storage)
            DiagnosticsSettingsTab()
                .tabItem {
                    Label("settings.diagnostics.title", systemImage: "stethoscope")
                }
                .tag(SettingsTab.diagnostics)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .scenePadding()
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
            guard let target = note.object as? String else { return }
            switch target {
            case "general":      selectedTab = .general
            case "pro":          selectedTab = .pro
            case "ai":           selectedTab = .ai
            case "mcp":          selectedTab = .mcp
            case "services":     selectedTab = .services
            case "integrations": selectedTab = .integrations
            case "storage":      selectedTab = .storage
            case "diagnostics":  selectedTab = .diagnostics
            default: break
            }
        }
    }

    private var generalTab: some View {
        @Bindable var settings = settings
        // 2026-06-15:`@State` 持有的 `@Observable` 单例需要 `@Bindable` 局部转换,
        // 才能用 `$localeStore.selection` 的双向 binding 写法,与上面 settings 同款。
        @Bindable var localeStore = localeStore

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
                        // 2026-06-15:reduceMotion 兜底——主题切换的颜色淡变在
                        // 关动画时改为瞬切。`withAnimation(nil)` 让 binding 写入
                        // 不挂任何 transaction,@Observable 属性变化按默认无包裹路径。
                        if reduceMotion {
                            settings.appearanceMode = newValue
                        } else {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                settings.appearanceMode = newValue
                            }
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

                // R-01 §3.1.1（2026-06-10 P1）：列表密度 Picker 已彻底移除——
                // RepoListDensity 枚举本身也已删除（之前为保签名稳定保留单 case
                // 是「自留技术债」，现在所有 row / skeleton 视图直接用 card 密度）。
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

            Section("settings.general.detailBehavior") {
                Toggle(isOn: $settings.openFirstDetailOnCategoryChange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.openFirstDetailOnCategoryChange.title")
                        Text("settings.general.openFirstDetailOnCategoryChange.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // 2026-06-15 dong4j 需求：用户面向的语言切换。
            //
            // 设计要点：
            // 1. `LocaleStore` 是 `@MainActor @Observable` 单例，主窗口与 Settings
            //    两个 scene 共享同一份选择；切换后由 `StarcatApp` 在 `.environment(\.locale, _)`
            //    + `.id(...)` 配合下整棵 view 树立刻重建，不需要重启 App。
            // 2. 默认 `system`：跟随系统设置，`Locale.autoupdatingCurrent` 让
            //    macOS Language & Region 改变时 Starcat 自动同步。
            // 3. 选项标签 `English` / `简体中文` 故意用其原生写法（不走 i18n
            //    查表），与 macOS Language & Region 列出语言时的惯例一致——
            //    哪怕用户误切到看不懂的语言，也能从原生写法找回入口。
            // 4. 已知局限（与 DEBUG 菜单 picker 一致，写在 `LocaleStore.swift`
            //    顶部注释里）：`.environment(\.locale, _)` 只覆盖 SwiftUI 视图层
            //    `Text("key")` 等查表行为；macOS 顶部菜单栏 NSMenu 与部分
            //    AppKit 弹窗的字符串走 `Bundle.main.localized*` 在 App 启动时
            //    一次性加载，**不**会跟随 environment 切换刷新。如果用户期望连
            //    菜单栏一起切，必须重启 App（说明文字里已提示）。
            Section("settings.general.language") {
                Picker(selection: $localeStore.selection) {
                    ForEach(AppLocale.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("settings.general.language.label")
                }
                .pickerStyle(.menu)

                Text("settings.general.language.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 快捷键偏好集中在 General，都是本机交互习惯，不属于 AI 模型配置。
            Section("settings.general.shortcuts") {
                Toggle(isOn: $settings.aiChatRequiresCommandReturn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.shortcuts.aiCommandReturn.title")
                        Text("settings.general.shortcuts.aiCommandReturn.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 12) {
                    Text("settings.general.shortcuts.search.title")
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 8) {
                        ShortcutRecorderView(
                            shortcut: $settings.globalSearchShortcut,
                            onValidationError: { shortcutValidationError = $0 },
                            helpKey: "settings.general.shortcuts.search.help"
                        )
                        .onChange(of: settings.globalSearchShortcut) { _, _ in
                            shortcutValidationError = nil
                        }

                        Button {
                            settings.globalSearchShortcut = .globalSearchDefault
                            shortcutValidationError = nil
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .help(Text("settings.general.shortcuts.restoreDefault"))
                        .accessibilityLabel(Text("settings.general.shortcuts.restoreDefault"))
                    }
                }

                HStack(spacing: 12) {
                    Text("settings.general.shortcuts.regularSearch.title")
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 8) {
                        ShortcutRecorderView(
                            shortcut: $settings.regularSearchShortcut,
                            onValidationError: { shortcutValidationError = $0 },
                            helpKey: "settings.general.shortcuts.regularSearch.help"
                        )
                        .onChange(of: settings.regularSearchShortcut) { _, _ in
                            shortcutValidationError = nil
                        }

                        Button {
                            settings.regularSearchShortcut = .regularSearchDefault
                            shortcutValidationError = nil
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .help(Text("settings.general.shortcuts.restoreDefault"))
                        .accessibilityLabel(Text("settings.general.shortcuts.restoreDefault"))
                    }
                }

                Text("settings.general.shortcuts.search.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                if let shortcutValidationError {
                    Text(shortcutValidationMessageKey(shortcutValidationError))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // 2026-06-20：系统通知策略入口。
            // 通知只用于「用户离开 App 后需要回来处理」的低频事件；普通状态变化继续留在
            // toolbar 状态面板，避免把通知中心变成运行日志。
            Section("settings.notifications.title") {
                Toggle(isOn: $settings.notificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.notifications.enabled.title")
                        Text("settings.notifications.enabled.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("settings.notifications.release.title", isOn: $settings.releaseNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.batchAI.title", isOn: $settings.batchAINotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.syncIssues.title", isOn: $settings.syncIssueNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.mcpIssues.title", isOn: $settings.mcpIssueNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
            }

            // 2026-06-15 dong4j 需求：无障碍 / 动画偏好。
            //
            // 单独起一个 Section 而不是夹在「外观」里——「关闭应用内动画」
            // 是无障碍语义（与系统「辅助功能 → 减少动态效果」同源），与外观
            // 主题（视觉偏好）属于不同维度；后续若新增其它无障碍配置
            // （如字号缩放、对比度增强），都归在本 Section。
            //
            // 实现机制：toggle ON 时由 `AnimationOverrideModifier` 在 root view
            // 上覆盖 `accessibilityReduceMotion` 环境值，全工程 30+ 个已实现
            // reduceMotion 兜底路径的视图自动尊重新偏好（与系统级减少动态
            // 效果走同一套代码路径）。详见 `Shared/Components/AnimationOverrideModifier.swift`。
            Section("settings.general.accessibility") {
                Toggle(isOn: $settings.disableAnimations) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.disableAnimations.title")
                        Text("settings.general.disableAnimations.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("settings.general.other") {
                HStack {
                    Spacer()

                    Button {
                        NSApp.keyWindow?.close()
                        FirstRunOnboardingPreferences.resetForDebugReplay()
                        NotificationCenter.default.post(
                            name: FirstRunOnboardingPreferences.debugReplayNotification,
                            object: nil
                        )
                    } label: {
                        Label("settings.general.resetOnboarding", systemImage: "arrow.counterclockwise")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutValidationMessageKey(
        _ error: KeyboardShortcutConfiguration.ValidationError
    ) -> LocalizedStringKey {
        switch error {
        case .invalidKey:
            return "settings.general.shortcuts.error.invalidKey"
        case .missingModifier:
            return "settings.general.shortcuts.error.missingModifier"
        case .reserved:
            return "settings.general.shortcuts.error.reserved"
        }
    }
}

// MARK: - 诊断 Tab（2026-06-20）

/// 调试日志导出面板。
///
/// 这里不是“日志清理”功能：系统 OSLog 仍由 Console.app 管理。本 Tab 只负责把 Starcat
/// 自己记录的关键诊断事件打包，便于用户遇到外部服务不可用、AI provider 异常或本地
/// 数据问题时，把最小必要证据交给 dong4j 排查。
private struct DiagnosticsSettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var isExporting = false
    @State private var lastExportMessage: String?
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("settings.diagnostics.export.section") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        // 导出入口需要和说明文字保持同一行；窗口较窄时优先截断说明，
                        // 避免按钮被 Form 布局挤到第二行。
                        Text("settings.diagnostics.export.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        Button {
                            Task { await exportDiagnostics() }
                        } label: {
                            Label("diagnostics.export.button", systemImage: "square.and.arrow.up")
                                .lineLimit(1)
                        }
                        .disabled(isExporting)
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    if isExporting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("settings.diagnostics.export.running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let lastExportMessage {
                        Text(verbatim: lastExportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            Section("settings.diagnostics.privacy.section") {
                Text("settings.diagnostics.privacy.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .alert(
            "diagnostics.export.failed.title",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("general.ok") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @MainActor
    private func exportDiagnostics() async {
        isExporting = true
        defer { isExporting = false }

        switch await DiagnosticBundleExporter.exportFromPanel(settings: settings) {
        case .exported(_):
            // 导出器成功后已经标记诊断问题为已处理；这里用固定反馈同步告知状态已重置。
            lastExportMessage = String.l10n("settings.diagnostics.export.successMessage")
        case .cancelled:
            break
        case .failed(let message):
            exportError = message
        }
    }
}

// MARK: - 存储 Tab（HOM-68 v3 / 2026-06-15 大重构）
//
// 重构背景（dong4j 2026-06-15 拍板）：
//   原设计把"缓存用量"（只读统计）和"清理操作"（按钮列表）做成两个独立 Section，
//   导致用户必须在两个分组之间来回比对：先看用量决定要不要清，再去下一个分组找对应的按钮。
//   同时 AI 代码上下文产物管理整段又在 storage Tab 占了一大块（输出目录 + 项目列表），
//   而 CodeFlow 的同类面板放在 集成 Tab，两边职责不一致。
//
// 重构后职责划分：
//   - 存储 Tab → 缓存用量：**全局汇总 + 总闸**。每行 = 一类缓存，行内显示用量数字 +
//     "清理"按钮；底部一个"清除全部缓存" destructive 总按钮。覆盖 7 类：
//     README / 图片 / ZIP / 翻译 / AnySearch / AI 代码上下文 / CodeFlow。
//   - AI 设置 → AI 代码上下文(实验)：**这一类的精细化操作**（输出目录、单项目删除、
//     在 Finder 显示）。"一键清除"按钮搬到存储 Tab，本地不再保留。
//   - 集成 → CodeFlow：同上，"一键清除"按钮也搬到存储 Tab。
//
// 关键设计约束：
//   1. 行内"清理"按钮统一走 confirmationDialog（PendingAction enum 驱动），
//      所有类目共享一套确认/失败处理代码，避免每类一套独立 alert 像旧实现那样。
//   2. 翻译 / AnySearch 原本各自走独立 alert，本次合并到 PendingAction.translation /
//      .anySearch——视觉一致 + 代码量减半。
//   3. 日志行删除（dong4j q3 拍板）：既然系统 Console.app 管理、用户无法操作，
//      就别放在"缓存用量"里假装可清理，反而误导。
//   4. ZIP 行保留 Finder 显示按钮（dong4j q2）：放在"清理"按钮左边。
//   5. AI 上下文 / CodeFlow 行用量基于各自单例 @Observable 的 `projects.count` /
//      `totalBytes`，不再走 CacheStatistics——CacheCleaner 不感知这两类（它们各自
//      的 storage 单例管理生命周期，CacheCleaner 不应越权依赖单例）。

/// 缓存统计与清理面板。
private struct StorageSettingsTab: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession

    let readmeRepository: ReadmeRepository

    @State private var stats: CacheStatistics = .empty
    @State private var isWorking: Bool = false
    @State private var isResettingAllData: Bool = false
    /// 当前显示的确认弹窗类型；nil 表示不显示。
    @State private var pendingAction: PendingAction?
    @State private var isShowingClearAllCachesSheet = false
    @State private var resetTarget: AppDataResetTarget?
    @State private var resetDidComplete = false
    @State private var storageActionError: String?

    /// AI 代码上下文产物（精细化面板已搬到 AISettingsView，本 Tab 仅消费汇总数字
    /// + "清除全部"入口）。`@Observable` 单例直接订阅，外部 storage 写入立即反映。
    @State private var aiContextStorage = RepoContextStorage.shared

    /// CodeFlow 产物（精细化面板留在 IntegrationSettingsView，本 Tab 同 AI 上下文）。
    @State private var codeFlowStorage = CodeFlowStorage.shared

    /// 翻译磁盘缓存：`@MainActor @Observable` 单例，UI 直接读 `totalBytes` /
    /// `itemCount`。删除走默认 appSupport 路径，无 bookmark 等额外失败面，
    /// 失败极少；统一走 storageActionError。
    @State private var translationCache = DiskReadmeTranslationCache.shared

    /// AnySearch 磁盘缓存：global + ai-summary 子目录合并清除（dong4j 拍板「合并清除」），
    /// 用户心智是"清搜索缓存"而不是分别清两个子目录。
    @State private var anySearchCache = DiskAnySearchCache.shared

    /// Wiki 探测结果磁盘缓存（2026-06-15 v4.y）：DeepWiki / ZRead / CodeWiki 单仓查询
    /// 结果按 owner/repo 落盘。注入 AI Chat system prompt 的 `{starcatResources}` 段。
    @State private var wikiCache = DiskWikiCache.shared

    /// HOM-70：AI 对话历史磁盘存储（按 repo 多 session）。
    /// 设置页 Tab 仅消费汇总数字 + "清除全部"入口，单 session 删除由对话窗口自己管理。
    @State private var chatHistoryStore = DiskChatHistoryStore.shared

    /// 行内"清理"按钮的待执行动作。
    /// 单项缓存继续共用 confirmationDialog；"删除全部缓存"已经升级为危险区 sheet，
    /// 但保留 `.all` 作为执行分支，避免复制清理代码。
    private enum PendingAction: Identifiable {
        case readme, image, archive, translation, anySearch, wiki, chatHistory, aiContext, codeFlow, all
        var id: String {
            switch self {
            case .readme:       return "readme"
            case .image:        return "image"
            case .archive:      return "archive"
            case .translation:  return "translation"
            case .anySearch:    return "anySearch"
            case .wiki:         return "wiki"
            case .chatHistory:  return "chatHistory"
            case .aiContext:    return "aiContext"
            case .codeFlow:     return "codeFlow"
            case .all:          return "all"
            }
        }
        var confirmTitle: String {
            switch self {
            case .readme:       return String.l10n("settings.storage.clearReadme.confirm")
            case .image:        return String.l10n("settings.storage.clearImage.confirm")
            case .archive:      return String.l10n("settings.storage.clearArchive.confirm")
            case .translation:  return String.l10n("settings.storage.clearTranslation.confirm")
            case .anySearch:    return String.l10n("settings.storage.clearAnySearch.confirm")
            case .wiki:         return String.l10n("settings.storage.clearWiki.confirm")
            case .chatHistory:  return String.l10n("settings.storage.clearChatHistory.confirm")
            case .aiContext:    return String.l10n("settings.storage.clearAiContext.confirm")
            case .codeFlow:     return String.l10n("settings.storage.clearCodeFlow.confirm")
            case .all:          return String.l10n("settings.storage.clearAll.confirm")
            }
        }
        var confirmMessageKey: LocalizedStringKey {
            switch self {
            case .readme:       return "settings.storage.clearReadme.message"
            case .image:        return "settings.storage.clearImage.message"
            case .archive:      return "settings.storage.clearArchive.message"
            case .translation:  return "settings.storage.clearTranslation.message"
            case .anySearch:    return "settings.storage.clearAnySearch.message"
            case .wiki:         return "settings.storage.clearWiki.message"
            case .chatHistory:  return "settings.storage.clearChatHistory.message"
            case .aiContext:    return "settings.storage.clearAiContext.message"
            case .codeFlow:     return "settings.storage.clearCodeFlow.message"
            case .all:          return "settings.storage.clearAll.message"
            }
        }
    }

    /// 9 类缓存全空时,"清除全部缓存"按钮 disabled,避免无意义点击。
    /// HOM-203：AI 上下文 / CodeFlow 改读 summary.projectCount，避免触发 projects 扫描。
    private var isAllCachesEmpty: Bool {
        stats.totalBytes == 0
            && translationCache.itemCount == 0
            && anySearchCache.itemCount == 0
            && wikiCache.itemCount == 0
            && chatHistoryStore.sessionCount == 0
            && aiContextStorage.projectCount == 0
            && codeFlowStorage.projectCount == 0
    }

    private var currentResetTarget: AppDataResetTarget? {
        guard let user = authSession.state.user else { return nil }
        return AppDataResetTarget(userID: user.id, login: user.login)
    }

    private var isLoggedIn: Bool {
        currentResetTarget != nil
    }

    /// 未登录时禁止 Storage 页里的实际操作控件，但不能禁用 Form 根视图。
    /// SwiftUI 会把 `.disabled` 环境传给滚动容器；若挂在 Form 上，未登录提示页也会无法滚动。
    private var shouldDisableStorageActions: Bool {
        isResettingAllData || !isLoggedIn
    }

    var body: some View {
        let cleaner = CacheCleaner(readmeRepository: readmeRepository)
        @Bindable var settings = settings
        return Form {
            if !isLoggedIn {
                Section {
                    Text("settings.storage.loginRequired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("settings.storage.chatHistoryBackend.section") {
                Picker("settings.storage.chatHistoryBackend.title", selection: $settings.chatHistoryStorageKind) {
                    ForEach(ChatHistoryStorageKind.allCases) { kind in
                        Text(LocalizedStringKey(kind.displayNameKey))
                            .tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .disabled(shouldDisableStorageActions)

                Text("settings.storage.chatHistoryBackend.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.storage.cacheUsage") {
                usageRow(
                    titleKey: "settings.storage.readme",
                    usageText: readmeUsageText,
                    isEmpty: stats.readmeCount == 0,
                    action: .readme
                )
                usageRow(
                    titleKey: "settings.storage.image",
                    usageText: Int64(stats.imageDiskBytes).formattedByteSize,
                    isEmpty: stats.imageDiskBytes == 0,
                    action: .image
                )
                archiveUsageRow(cleaner: cleaner)
                usageRow(
                    titleKey: "settings.storage.translation",
                    usageText: translationUsageText,
                    isEmpty: translationCache.itemCount == 0,
                    action: .translation,
                    helpKey: "settings.storage.translation.help"
                )
                usageRow(
                    titleKey: "settings.storage.anySearch",
                    usageText: anySearchUsageText,
                    isEmpty: anySearchCache.itemCount == 0,
                    action: .anySearch,
                    helpKey: "settings.storage.anySearch.help"
                )
                usageRow(
                    titleKey: "settings.storage.wiki",
                    usageText: wikiUsageText,
                    isEmpty: wikiCache.itemCount == 0,
                    action: .wiki,
                    helpKey: "settings.storage.wiki.help"
                )
                usageRow(
                    titleKey: "settings.storage.chatHistory",
                    usageText: chatHistoryUsageText,
                    isEmpty: chatHistoryStore.sessionCount == 0,
                    action: .chatHistory,
                    helpKey: "settings.storage.chatHistory.help"
                )
                usageRow(
                    titleKey: "settings.storage.aiContext",
                    usageText: aiContextUsageText,
                    isEmpty: aiContextStorage.projectCount == 0,
                    action: .aiContext
                )
                usageRow(
                    titleKey: "settings.storage.codeFlow",
                    usageText: codeFlowUsageText,
                    isEmpty: codeFlowStorage.projectCount == 0,
                    action: .codeFlow
                )
            }

            Section("settings.storage.dangerZone") {
                dangerActionBlock(
                    descriptionKey: "settings.storage.clearAll.description",
                    buttonTint: Color(nsColor: .systemYellow),
                    buttonForeground: .black,
                    isDisabled: shouldDisableStorageActions || isWorking || isAllCachesEmpty
                ) {
                    Button {
                        isShowingClearAllCachesSheet = true
                    } label: {
                        Label("settings.storage.clearAll", systemImage: "exclamationmark.triangle.fill")
                    }
                }

                dangerActionBlock(
                    descriptionKey: "settings.storage.resetAll.description",
                    buttonTint: .red,
                    buttonForeground: .white,
                    isDisabled: isWorking || isResettingAllData || currentResetTarget == nil
                ) {
                    Button(role: .destructive) {
                        resetTarget = currentResetTarget
                    } label: {
                        Label("settings.storage.resetAll", systemImage: "trash")
                    }
                }
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
        .task(id: isLoggedIn) {
            guard isLoggedIn else {
                stats = .empty
                return
            }
            stats = await cleaner.loadStatistics()
        }
        .task(id: isLoggedIn) {
            guard isLoggedIn else { return }
            // Tab 出现时强制重扫描全部产物 / 缓存目录，让用户刚生成的内容立即可见。
            aiContextStorage.reload()
            codeFlowStorage.reload()
            translationCache.reload()
            anySearchCache.reload()
            chatHistoryStore.reload()
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
        .alert(
            "settings.storage.actionFailed",
            isPresented: Binding(
                get: { storageActionError != nil },
                set: { if !$0 { storageActionError = nil } }
            )
        ) {
            Button("general.ok") { storageActionError = nil }
        } message: {
            Text(storageActionError ?? "")
        }
        .sheet(isPresented: $isShowingClearAllCachesSheet) {
            StorageClearAllCachesSheet(
                isClearing: isWorking,
                onCancel: {
                    isShowingClearAllCachesSheet = false
                },
                onConfirm: {
                    Task {
                        await perform(action: .all, using: cleaner)
                        isShowingClearAllCachesSheet = false
                    }
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $resetTarget) { target in
            StorageResetAllDataSheet(
                target: target,
                isResetting: isResettingAllData,
                didComplete: resetDidComplete,
                onCancel: {
                    resetTarget = nil
                    resetDidComplete = false
                },
                onConfirm: {
                    Task { await performResetAllData(target: target) }
                },
                onQuit: {
                    quitAfterResetCompletion()
                },
                onRestart: {
                    restartAfterResetCompletion()
                }
            )
            .appLocaleEnvironment()
        }
    }

    // MARK: - 行视图 helpers

    /// 危险区操作块：说明在左，按钮右对齐。黄色缓存删除与红色本地数据重置共用布局，
    /// 避免两个高风险入口在同一分组里产生不同的视觉节奏。
    private func dangerActionBlock<Action: View>(
        descriptionKey: LocalizedStringKey,
        buttonTint: Color,
        buttonForeground: Color,
        isDisabled: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(descriptionKey)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                action()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .font(.headline)
                    .tint(buttonTint)
                    .foregroundStyle(buttonForeground)
                    .disabled(isDisabled)
            }
        }
    }

    /// 标准用量行：`<标题>     <用量>  [清理]`。
    /// `isEmpty == true` 时清理按钮 disabled（避免空缓存触发"删空目录"等无意义操作）。
    private func usageRow(
        titleKey: LocalizedStringKey,
        usageText: String,
        isEmpty: Bool,
        action: PendingAction,
        helpKey: LocalizedStringKey? = nil
    ) -> some View {
        let row = LabeledContent {
            HStack(spacing: 8) {
                Text(usageText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("settings.storage.action.clear") {
                    pendingAction = action
                }
                .controlSize(.small)
                .disabled(shouldDisableStorageActions || isWorking || isEmpty)
            }
        } label: {
            Text(titleKey)
        }

        return Group {
            if let helpKey {
                row.help(Text(helpKey))
            } else {
                row
            }
        }
    }

    /// ZIP 行（额外多一个 Finder 显示按钮）。
    /// 单独抽出来，避免 `usageRow` 通用 helper 变成多参数泥潭。
    private func archiveUsageRow(cleaner: CacheCleaner) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(archiveUsageText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    do {
                        try cleaner.revealArchiveDirectory()
                    } catch {
                        storageActionError = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("settings.storage.archive.revealHelp"))
                .disabled(shouldDisableStorageActions || isWorking)
                Button("settings.storage.action.clear") {
                    pendingAction = .archive
                }
                .controlSize(.small)
                .disabled(shouldDisableStorageActions || isWorking || stats.archiveCount == 0)
            }
        } label: {
            Text("settings.storage.archive")
        }
    }

    // MARK: - 清理执行

    /// 执行清理 + 重新加载统计。UI state 全程在 main actor。
    ///
    /// 失败处理：每个 throws 调用独立 catch，互不阻断。多类同时失败时只显示**第一个**
    /// 错误（避免连弹多个 alert）；这是设置页"清理"动作可接受的简化——失败极少，
    /// 用户重试即可，没必要做错误聚合。
    @MainActor
    private func perform(action: PendingAction, using cleaner: CacheCleaner) async {
        guard isLoggedIn else { return }
        isWorking = true
        switch action {
        case .readme:
            await cleaner.clearReadmes()
        case .image:
            await cleaner.clearImageCache()
        case .archive:
            cleaner.clearArchives()
        case .translation:
            do { try await translationCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .anySearch:
            do { try await anySearchCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .wiki:
            do { try wikiCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .chatHistory:
            do { try chatHistoryStore.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .aiContext:
            do { try aiContextStorage.deleteAllProjects() }
            catch { storageActionError = error.localizedDescription }
        case .codeFlow:
            do { try codeFlowStorage.deleteAllProjects() }
            catch { storageActionError = error.localizedDescription }
        case .all:
            await cleaner.clearAll()
            // 4 处独立 try：互不阻断；首个失败的 description 留在 storageActionError，
            // 后续若再失败则丢弃（避免连弹多个 alert，dong4j 反馈"重试一遍即可"）。
            do { try await translationCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
            do { try await anySearchCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try wikiCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try chatHistoryStore.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try aiContextStorage.deleteAllProjects() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try codeFlowStorage.deleteAllProjects() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
        }
        stats = await cleaner.loadStatistics()
        isWorking = false
        pendingAction = nil
    }

    /// 执行“本机恢复出厂”。真正的删除逻辑在 AppDependencies / AppDataResetService；
    /// Settings 页只负责收集用户确认并展示完成状态，避免 UI 层直接拼路径删文件。
    @MainActor
    private func performResetAllData(target: AppDataResetTarget) async {
        guard isLoggedIn else {
            storageActionError = AppDataResetError.notAuthenticated.localizedDescription
            return
        }
        isResettingAllData = true
        do {
            try await dependencies.resetLocalAppData(for: target)
            stats = .empty
            translationCache.reload()
            anySearchCache.reload()
            wikiCache.reload()
            chatHistoryStore.reload()
            aiContextStorage.reload()
            codeFlowStorage.reload()
            resetDidComplete = true
        } catch {
            storageActionError = error.localizedDescription
        }
        isResettingAllData = false
    }

    /// reset 完成态需要先让 SwiftUI sheet 正常退场，再在下一轮 main queue 发退出请求。
    ///
    /// 直接在 sheet button action 里 `terminate` 容易被当前 modal 事务吞掉；把关闭
    /// sheet 与 AppKit 生命周期动作拆成两步，用户点击后才会稳定退出 / 重启。
    private func quitAfterResetCompletion() {
        dismissResetCompletionSheet()
        DispatchQueue.main.async {
            StorageResetAppLifecycle.quit()
        }
    }

    private func restartAfterResetCompletion() {
        dismissResetCompletionSheet()
        DispatchQueue.main.async {
            StorageResetAppLifecycle.restart()
        }
    }

    private func dismissResetCompletionSheet() {
        resetTarget = nil
        resetDidComplete = false
    }

    // MARK: - 用量文案

    private var readmeUsageText: String {
        String(
            format: String.l10n("settings.storage.readmeUsageFormat"),
            stats.readmeCount,
            stats.readmeBytes.formattedByteSize
        )
    }

    private var archiveUsageText: String {
        String(
            format: String.l10n("settings.storage.archiveUsageFormat"),
            stats.archiveCount,
            stats.archiveBytes.formattedByteSize
        )
    }

    /// 翻译磁盘缓存用量行文案：`X 项 · YY KB`。空缓存显示"未生成"。
    private var translationUsageText: String {
        if translationCache.itemCount == 0 {
            return String.l10n("settings.storage.translation.empty")
        }
        return String(
            format: String.l10n("settings.storage.translationUsageFormat"),
            translationCache.itemCount,
            translationCache.totalBytes.formattedByteSize
        )
    }

    /// AnySearch 磁盘缓存用量行文案（global + ai-summary 合计）。
    private var anySearchUsageText: String {
        if anySearchCache.itemCount == 0 {
            return String.l10n("settings.storage.anySearch.empty")
        }
        return String(
            format: String.l10n("settings.storage.anySearchUsageFormat"),
            anySearchCache.itemCount,
            anySearchCache.totalBytes.formattedByteSize
        )
    }

    /// Wiki 探测结果磁盘缓存用量行文案。数据极小（每个 repo < 1KB），格式与
    /// translation / anySearch 同款（`X 项 · YY KB`）保持视觉一致。
    private var wikiUsageText: String {
        if wikiCache.itemCount == 0 {
            return String.l10n("settings.storage.wiki.empty")
        }
        return String(
            format: String.l10n("settings.storage.wikiUsageFormat"),
            wikiCache.itemCount,
            wikiCache.totalBytes.formattedByteSize
        )
    }

    /// AI 对话历史用量行文案：`X 场对话 · YY 个仓库 · ZZ KB`。空显示"未生成"。
    private var chatHistoryUsageText: String {
        if chatHistoryStore.sessionCount == 0 {
            return String.l10n("settings.storage.chatHistory.empty")
        }
        return String(
            format: String.l10n("settings.storage.chatHistoryUsageFormat"),
            chatHistoryStore.sessionCount,
            chatHistoryStore.repoCount,
            chatHistoryStore.totalBytes.formattedByteSize
        )
    }

    /// AI 代码上下文用量：`X 项 · YY KB`。空显示"未生成"。
    /// HOM-203：直接读 summary 的 projectCount / totalBytes，避免遍历 projects 数组。
    private var aiContextUsageText: String {
        if aiContextStorage.projectCount == 0 {
            return String.l10n("settings.storage.aiContext.empty")
        }
        return String(
            format: String.l10n("settings.storage.aiContextUsageFormat"),
            aiContextStorage.projectCount,
            aiContextStorage.totalBytes.formattedByteSize
        )
    }

    /// CodeFlow 用量：同 AI 上下文格式。
    private var codeFlowUsageText: String {
        if codeFlowStorage.projectCount == 0 {
            return String.l10n("settings.storage.codeFlow.empty")
        }
        return String(
            format: String.l10n("settings.storage.codeFlowUsageFormat"),
            codeFlowStorage.projectCount,
            codeFlowStorage.totalBytes.formattedByteSize
        )
    }
}

/// Storage 页“删除全部缓存”的确认 sheet。
///
/// 这个操作会删除可重建的文件型缓存和生成物，但不会碰本地 SQLite 用户数据或凭据。
/// 独立成 sheet 是为了让“全部缓存”与危险区语义一致，同时区别于真正的本地数据重置。
private struct StorageClearAllCachesSheet: View {
    let isClearing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            warningContent
            footer
        }
        .padding(24)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Color(nsColor: .systemYellow))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text("settings.storage.clearAll.sheet.title")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("settings.storage.clearAll.sheet.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.storage.clearAll.scope.title")
                    .font(.headline)
                    .foregroundStyle(.primary)

                ForEach(clearAllCacheScopeItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "smallcircle.filled.circle")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("settings.storage.clearAll.sheet.note")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("general.cancel", role: .cancel) {
                onCancel()
            }
            .disabled(isClearing)

            Button {
                onConfirm()
            } label: {
                if isClearing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.storage.clearAll.clearing")
                    }
                } else {
                    Text("settings.storage.clearAll.confirmAction")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: .systemYellow))
            .foregroundStyle(.black)
            .disabled(isClearing)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var clearAllCacheScopeItems: [String] {
        [
            "settings.storage.clearAll.scope.readme",
            "settings.storage.clearAll.scope.media",
            "settings.storage.clearAll.scope.searchWiki",
            "settings.storage.clearAll.scope.generated",
            "settings.storage.clearAll.scope.localDataSafe"
        ]
    }
}

/// Storage 页“清空所有数据”的二次确认 sheet。
///
/// 这个视图只负责把破坏性操作讲清楚并收集 GitHub username 确认；
/// 真正删除由 AppDataResetService 执行，避免 UI 层掌握本机路径删除细节。
private struct StorageResetAllDataSheet: View {
    let target: AppDataResetTarget
    let isResetting: Bool
    let didComplete: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onQuit: () -> Void
    let onRestart: () -> Void

    @State private var confirmationText = ""
    @FocusState private var isInputFocused: Bool

    private var normalizedInput: String {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var normalizedLogin: String {
        target.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canConfirm: Bool {
        !didComplete && !isResetting && normalizedInput == normalizedLogin
    }

    private var usernamePrompt: Text {
        Text("settings.storage.resetAll.usernamePromptPrefix")
            .foregroundStyle(.secondary)
        + Text(verbatim: target.login)
            .fontWeight(.semibold)
            .foregroundStyle(Color(nsColor: .systemOrange))
        + Text("settings.storage.resetAll.usernamePromptSuffix")
            .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if didComplete {
                completionContent
            } else {
                warningContent
            }

            footer
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            isInputFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: didComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(didComplete ? .green : .red)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(didComplete ? "settings.storage.resetAll.completed.title" : "settings.storage.resetAll.sheet.title")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(didComplete ? "settings.storage.resetAll.completed.message" : "settings.storage.resetAll.sheet.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.storage.resetAll.scope.title")
                    .font(.headline)
                    .foregroundStyle(.primary)

                ForEach(resetScopeItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "smallcircle.filled.circle")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                usernamePrompt
                    .font(.callout)

                TextField("settings.storage.resetAll.usernamePlaceholder", text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .disabled(isResetting)
            }
        }
    }

    private var completionContent: some View {
        Text("settings.storage.resetAll.completed.detail")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if didComplete {
                Button("settings.storage.resetAll.quit") {
                    onQuit()
                }

                Button("settings.storage.resetAll.restart") {
                    onRestart()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("general.cancel", role: .cancel) {
                    onCancel()
                }
                .disabled(isResetting)

                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    if isResetting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("settings.storage.resetAll.resetting")
                        }
                    } else {
                        Text("settings.storage.resetAll.confirm")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resetScopeItems: [String] {
        [
            "settings.storage.resetAll.scope.database",
            "settings.storage.resetAll.scope.caches",
            "settings.storage.resetAll.scope.generated",
            "settings.storage.resetAll.scope.settings",
            "settings.storage.resetAll.scope.credentials",
            "settings.storage.resetAll.scope.remoteSafe"
        ]
    }
}

/// Storage reset 完成后的 AppKit 生命周期桥接。
///
/// SwiftUI 只表达用户意图；退出 / 重启是应用级 imperative 行为，集中在这个小 helper
/// 里，避免 sheet 视图直接散落 `NSWorkspace` / `Process` 细节。
private enum StorageResetAppLifecycle {
    static func quit() {
        NSApplication.shared.terminate(nil)
    }

    static func restart() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                AppLog.general.error("Restart Starcat failed via NSWorkspace: \(error.localizedDescription, privacy: .public)")
                restartWithOpenCommand(appURL: appURL)
            }

            DispatchQueue.main.async {
                quit()
            }
        }
    }

    /// `NSWorkspace` 启动失败时兜底调用系统 `open -n`。
    ///
    /// 这条路径只负责尽量拉起新实例；无论兜底是否成功，当前实例都会退出，避免 reset 后
    /// 用户继续停留在已清空本机状态的进程里操作旧 UI。
    private static func restartWithOpenCommand(appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]

        do {
            try process.run()
        } catch {
            AppLog.general.error("Restart Starcat fallback failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
