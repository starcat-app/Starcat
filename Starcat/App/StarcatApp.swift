//
//  StarcatApp.swift
//  Starcat
//
//  @main 入口。
//
//  启动期职责：
//  1. 触发 DatabaseManager 单例初始化（含 Migration）
//  2. 跑 KeychainManager 自检
//  3. 构造 AppDependencies（API / OAuth / AuthSession / SyncManager）
//  4. 尝试从 Keychain 恢复登录态
//  5. 应用用户主题偏好（NSApp.appearance）
//

import SwiftUI
import AppKit  // W4-5 D1 follow-up：NSApp.appearance 控制主题（preferredColorScheme 在 macOS 有 nil-restore bug）

@main
struct StarcatApp: App {

    /// 应用级依赖容器，必须在 init 中创建并通过 environment 传给 ContentView。
    @State private var dependencies: AppDependencies

    // MARK: - DEBUG-only: 运行时语言切换
    //
    // dong4j 2026-06-04 需求：测试 i18n 是否完全覆盖时，希望不重启 App 也能切语言。
    // 用一个 `@State` 持有 `DebugLocaleStore.shared`（@Observable 单例），下面的
    // `WindowGroup` 通过 `.environment(\.locale, _)` 应用，菜单项在 `.commands` 里注册。
    // 整段包在 `#if DEBUG`：Release 包不存在这个状态、不显示这个菜单，零成本。
    #if DEBUG
    @State private var debugLocaleStore = DebugLocaleStore.shared
    #endif

    init() {
        Self.bootstrap()
        // 注意：AppDependencies 是 @MainActor，App init 已在 main thread
        _dependencies = State(initialValue: AppDependencies())

        // ⚠️ 不要在这里调 `Self.applyAppearance(...)` / `NSApp.appearance = ...`！
        // `NSApp` 是 implicitly unwrapped optional，`@main App.init()` 阶段
        // `NSApplication.shared` 还没被初始化 (NSApp == nil)，访问 `NSApp.appearance`
        // 会立即崩 "Unexpectedly found nil while implicitly unwrapping an Optional"。
        // 2026-06-03 23:43 dong4j 截图验证。
        //
        // 主题应用走 ContentView 的 `.onAppear` + `.onChange` 路径 —— 那时候
        // NSApp 已经初始化完成，访问 .appearance 安全。代价：冷启动 → 第一帧
        // 之间几十 ms 窗口可能闪一下系统默认外观，再切到用户选择 —— 这是
        // 可接受的权衡，不要为了消除这点闪烁再回到 init() 里调 NSApp。
    }

    var body: some Scene {
        WindowGroup("Starcat") {
            contentRoot
                .environment(dependencies)
                .environment(dependencies.authSession)
                .environment(dependencies.syncManager)
                .environment(dependencies.settings)
                // W4-5 D1 follow-up（2026-06-03 23:26）：用户主题应用到全 App。
                //
                // 为什么不用 SwiftUI `.preferredColorScheme(_:)` 而用 AppKit 的
                // `NSApp.appearance` ——
                // dong4j 验收（截图：light → system 时主窗口左半浅色 / 右半深色）
                // 暴露 SwiftUI on macOS 的已知 bug：`.preferredColorScheme(nil)`
                // 不能可靠地"撤销"之前强制过的非 nil 值，导致内部 view tree 的
                // colorScheme state 部分卡住、部分更新（截图里 sidebar / 列表
                // 浅色但右侧详情区深色就是 SwiftUI 没完成传播的中间态）。
                //
                // AppKit 标准做法：`NSApp.appearance = nil` 干净地撤销强制外观，
                // 所有 NSWindow（主窗口 + Settings + About）的 effectiveAppearance
                // 自动跟随系统切换；SwiftUI 通过 environment(\.colorScheme) 接收
                // NSWindow.effectiveAppearance 也会同步更新视图层。
                //
                // 实现：① `.onAppear` 启动时根据当前 settings 应用一次（处理冷启动
                // 恢复 + Window 重建场景）② `.onChange` 监听 settings.appearanceMode
                // 变化（兜底所有切主题入口，无论从 Picker / 菜单 / 快捷键还是未来的
                // URL scheme，只要 settings 改了就触发应用）。
                .onAppear {
                    applyAppearance(dependencies.settings.appearanceMode)
                }
                .onChange(of: dependencies.settings.appearanceMode) { _, newMode in
                    applyAppearance(newMode)
                }
                // W4-5 D1 follow-up：隐式动画兜底。SettingsView 的 Picker 已经在
                // setter 里包了 `withAnimation(.easeInOut(0.3))`，这里再挂一道
                // `.animation(_:value:)` 让 colorScheme 相关的视图重渲染都自动
                // 0.3s 淡变，覆盖未来其他入口（菜单 / 快捷键 / URL scheme）。
                //
                // 关键约束：macOS NSWindow titlebar / chrome 由 AppKit 即时切换
                // effectiveAppearance，SwiftUI 动画系统覆盖不到，所以 titlebar
                // 仍是瞬切；视图内容区（动态色 / 材质 / 文字色）会跟随过渡。
                .animation(.easeInOut(duration: 0.3), value: dependencies.settings.appearanceMode)
                .task {
                    await dependencies.authSession.restoreSessionIfAvailable()
                }
        }
        .commands {
            // 替换系统默认的"关于 Starcat"菜单项，打开自定义 SwiftUI 关于窗口。
            CommandGroup(replacing: .appInfo) {
                Button("app.about") {
                    AboutPanelController.show()
                }
                .keyboardShortcut("I", modifiers: .command)
            }

            // DEBUG-only 菜单：当前只承载语言切换，未来可继续追加其他调试入口
            // （例如清缓存、强制制造网络错误、Dump 数据库等）。
            // Release 包整段不存在；菜单本身的标题 / 选项标签都用 verbatim 文本，
            // 不进入 String Catalog——避免"切到英文后调试菜单也变英文"的循环噩梦。
            #if DEBUG
            DebugMenuCommands(localeStore: debugLocaleStore)
            #endif
        }

        // macOS 原生 Settings 窗口（Cmd+,）
        Settings {
            SettingsView()
                .environment(dependencies)        // W4-4 D4：StorageSettingsTab 需要 readmeRepository
                .environment(dependencies.settings)
                // W4-5 D1 follow-up：Settings 窗口不需要再调 NSApp.appearance —
                // 主窗口的 onAppear / onChange 已经设置了**全局** NSApp.appearance，
                // Settings 窗口是 NSApp 的子窗口，effectiveAppearance 自动跟随。
                // 但还是挂一道 `.animation(_:value:)` 让 Settings 内部视图
                // 颜色变化跟主窗口节奏一致（0.3s easeInOut）。
                .animation(.easeInOut(duration: 0.3), value: dependencies.settings.appearanceMode)
        }
    }

    // MARK: - 内容根视图

    /// 包了一层 builder 是为了让 DEBUG-only 的 `.environment(\.locale, _)` 修饰符
    /// 不污染 Release 构建——`#if DEBUG` 在 ViewBuilder 内部合法，但放在 `.modifier`
    /// 链上不行。
    ///
    /// 语义：DEBUG 时按 `debugLocaleStore.selection.effectiveLocale` 覆盖 environment
    /// locale；`.system` 选项对应 `Locale.autoupdatingCurrent`，与不设置等价。
    @ViewBuilder
    private var contentRoot: some View {
        #if DEBUG
        ContentView()
            .environment(\.locale, debugLocaleStore.selection.effectiveLocale)
            // 给 SwiftUI 一个 identity 提示：当 selection 改变时强制重建 ContentView
            // 视图层级，避免某些缓存了 Locale 的子视图（例如 RelativeDateTimeFormatter）
            // 在不重启 App 的情况下也能立刻刷新。代价是切语言时整个 ContentView
            // 重新渲染一次——dong4j 截图反馈"切语言后部分时间格式没变"就是少了这一行。
            .id(debugLocaleStore.selection)
        #else
        ContentView()
        #endif
    }

    // MARK: - 主题应用

    /// 把 `AppearanceMode` 写到 `NSApp.appearance`。
    ///
    /// 设计：
    /// - `.system` → `nil`：AppKit 标准的"清除强制外观"，所有 NSWindow 回退跟随系统
    /// - `.light` → `NSAppearance(named: .aqua)`：强制浅色
    /// - `.dark` → `NSAppearance(named: .darkAqua)`：强制深色
    ///
    /// 为什么放在 @MainActor func 而不是 AppearanceMode 的 computed property：
    /// - `AppearanceMode` 在 `AppSettings.swift` 中只 import SwiftUI，
    ///   保持平台无关；NSAppearance 是 AppKit 类型，放在使用点（StarcatApp）
    ///   更符合分层
    /// - 集中在一个 helper，未来如果切到不同主题机制（如自定义 NSAppearance bundle）
    ///   只改这一处
    @MainActor
    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Bootstrap

    private static func bootstrap() {
        AppLog.general.info("Starcat starting (bundle=\(AppConstants.bundleIdentifier, privacy: .public))")
        DatabaseManager.bootstrap()

        // 测试期跳过 Keychain 自检：ad-hoc 签名 + ACL 不匹配会触发 GUI 授权弹窗，
        // 测试 host 主线程被对话框阻塞 → testmanagerd 永远连不上 App。
        // 详见 docs/工程进度/2026-05-30-Keychain-临时绕过方案.md
        if TestEnvironment.isRunning {
            AppLog.general.info("Test host detected, skipping Keychain self-check")
        } else {
            do {
                try KeychainManager.shared.ping()
            } catch {
                AppLog.keychain.error("Keychain self-check failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLog.general.info("Starcat bootstrap complete")
    }
}

// MARK: - DEBUG-only 菜单

#if DEBUG
/// DEBUG 菜单聚合（顶部菜单栏出现一个 `Debug` 入口）。
///
/// 设计：
/// - 用 `Commands` 协议而不是直接写在 `.commands` 里——把所有调试入口聚拢到一个
///   独立类型，未来要加新调试项（清数据库 / Dump 偏好 / 强制限流等）就在这个
///   类型里加 `CommandGroup` / `CommandMenu`，主 `StarcatApp.body` 不会被撑大
/// - `CommandMenu("Debug")` 在 menubar 上插入一个顶级菜单（位置由 SwiftUI 决定，
///   一般在 View 菜单之后），不与系统标准菜单冲突
/// - 语言切换走 SwiftUI 原生 `Picker` —— SwiftUI 会自动把它渲染成菜单内的
///   一组可勾选项（带 checkmark），不需要手动维护选中态
struct DebugMenuCommands: Commands {

    /// 直接拿 store 而不是再包一层 binding——`@Bindable` 在 macOS 15 SwiftUI
    /// commands 上下文里可用（Commands 内部能正确订阅 @Observable）。
    @Bindable var localeStore: DebugLocaleStore

    var body: some Commands {
        // 第一个菜单：Debug
        // 注意菜单标题用 verbatim 字面量（避免被 String Catalog 提取后跟随
        // .environment(\.locale, _) 切换），保证不管当前 locale 是什么，开发者
        // 都能在菜单栏看到固定的"Debug"字样找到入口。
        CommandMenu("Debug") {
            languageSubmenu
            // 占位：未来追加其他调试入口（清缓存 / Dump DB / 强制 429 等）
        }
    }

    /// 语言切换子菜单——用 `Picker` 让 SwiftUI 自动渲染成"radio 组"。
    ///
    /// Picker 在 CommandMenu 里的行为：菜单项前会出现一个 ✓ 标记表示选中项；
    /// 点击其他项立即触发 `selection` 写入。比手写多个 Button + checkmark 简洁。
    ///
    /// `pickerStyle(.inline)` 让选项平铺在 Debug 菜单第一层，而不是嵌套子菜单——
    /// 调试场景下"少一次点击"比"菜单整洁"更重要。
    @ViewBuilder
    private var languageSubmenu: some View {
        Section("Language / 语言") {
            Picker(selection: $localeStore.selection) {
                ForEach(DebugLocale.allCases) { option in
                    Text(verbatim: option.displayName).tag(option)
                }
            } label: {
                Text(verbatim: "Locale Override")
            }
            .pickerStyle(.inline)
        }
    }
}
#endif
