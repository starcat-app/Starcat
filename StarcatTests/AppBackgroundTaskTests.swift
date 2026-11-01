//
//  AppBackgroundTaskTests.swift
//  StarcatTests
//
//  任务卡片的只读投影、按类型操作能力及 18 语言资源和离屏布局契约，不操作桌面或启动任务。
//

import SwiftUI
import Testing
@testable import Starcat

/// 状态与计数先验证纯值，再验证真实编译资源；不能让英语回退掩盖缺译。
@MainActor
@Suite("Background task overview")
struct AppBackgroundTaskTests {
    @Test("完全空闲没有可展开任务或窗口目标")
    func idleHasNoDestination() {
        let snapshot = AppBackgroundTaskSnapshot(tasks: [])
        #expect(snapshot.count == 0)
        #expect(!snapshot.isRunning)
        #expect(!snapshot.needsAttention)
        #expect(snapshot.captionKey == "toolbar.status.tasks.idleCaption")
        for kind in AppBackgroundTask.Kind.allCases { #expect(snapshot.task(kind) == nil) }
        #expect(AppBackgroundTask.organization(.idle, kind: .tags, canCancel: true, opensWindow: true) == nil)
    }

    @Test("任务数不随仓库数量变化，暂停和待确认也保留入口")
    func countMeansTaskBatches() throws {
        let paused = try #require(AppBackgroundTask.organization(.paused(processed: 76, total: 323), kind: .grouping,
                                                                 canCancel: true, opensWindow: true))
        let review = try #require(AppBackgroundTask.organization(.review(count: 2_054), kind: .tags,
                                                                 canCancel: false, opensWindow: true))
        let snapshot = AppBackgroundTaskSnapshot(tasks: [paused, review])
        #expect(snapshot.count == 2)
        #expect(!snapshot.isRunning)
        #expect(snapshot.needsAttention)
        #expect(snapshot.task(.grouping)?.phase == .paused)
        #expect(snapshot.task(.tags)?.phase == .review)
        #expect(snapshot.tasks.allSatisfy { $0.opensWindow })
    }

    @Test("应用阶段拥有独立计数，不能退回空闲或允许取消写入")
    func applicationIsNotAnalysisCompletion() throws {
        for kind in [AppBackgroundTask.Kind.grouping, .tags] {
            let task = try #require(AppBackgroundTask.organization(.applying(processed: 53, total: 149), kind: kind,
                                                                   canCancel: true, opensWindow: true))
            #expect(task.phase == .applying)
            #expect(task.detail == .progress(processed: 53, total: 149))
            #expect(!task.canCancel)
            #expect(task.opensWindow)
            #expect(AppBackgroundTaskSnapshot(tasks: [task]).isRunning)
        }
        #expect(AppBackgroundTask.Detail.progress(processed: 0, total: 0).text(locale: Locale(identifier: "en")) == nil)
    }

    @Test("首次预热的 README 子工作合并，但不能隐藏独立预取")
    func warmupReadmeIsCountedOnce() {
        let warmup = AppBackgroundTask(id: .warmup, phase: .running)
        let readme = AppBackgroundTask(id: .readme, phase: .running)
        let health = AppBackgroundTask(id: .health, phase: .running)
        #expect(AppBackgroundTaskSnapshot(tasks: [warmup, readme, health], warmupOwnsReadme: true).tasks == [warmup, health])
        #expect(AppBackgroundTaskSnapshot(tasks: [warmup, readme, health]).count == 3)
        #expect(AppBackgroundTaskSnapshot(tasks: [readme], warmupOwnsReadme: true).tasks == [readme])
    }

    @Test("具体任务的操作能力互不串用，已结束任务不可再从旧行打开")
    func operationsStayTaskSpecific() {
        let grouping = AppBackgroundTask(id: .grouping, phase: .running, canCancel: true, opensWindow: true)
        let readme = AppBackgroundTask(id: .readme, phase: .running, canCancel: true)
        let snapshot = AppBackgroundTaskSnapshot(tasks: [grouping, readme])
        #expect(snapshot.task(.grouping)?.opensWindow == true)
        #expect(snapshot.task(.readme)?.opensWindow == false)
        #expect(snapshot.task(.tags) == nil)
        let finished = AppBackgroundTaskSnapshot(tasks: [readme])
        #expect(finished.task(.grouping) == nil)
        #expect(finished.task(.readme)?.canCancel == true)
        let automatic = AppBackgroundTask.organization(.applying(processed: 0, total: 0), kind: .grouping,
                                                        canCancel: true, opensWindow: false)
        #expect(automatic?.opensWindow == false)
        #expect(automatic?.canCancel == false)
        #expect(automatic?.detail.text(locale: Locale(identifier: "en")) == nil)
    }

    @Test("等待与暂停不能显示为运行，失败和待确认显示需要处理")
    func phasesHaveAccurateCaptions() {
        for phase in AppBackgroundTask.Phase.allCases {
            let snapshot = AppBackgroundTaskSnapshot(tasks: [.init(id: .tags, phase: phase)])
            #expect(snapshot.isRunning == [.preparing, .running, .applying].contains(phase))
            #expect(snapshot.needsAttention == [.review, .failed].contains(phase))
            let expectedCaption = switch phase {
            case .preparing, .running, .applying: "toolbar.backgroundTasks.running"
            case .paused: "toolbar.backgroundTasks.paused"
            case .review: "toolbar.backgroundTasks.review"
            case .failed: "toolbar.backgroundTasks.failed"
            case .waiting: "toolbar.backgroundTasks.waiting"
            }
            #expect(snapshot.captionKey == expectedCaption)
        }
    }

    @Test("全部支持语言的目标资源含真实译文", arguments: AppLocale.allCases.filter { $0 != .system })
    func compiledTranslationsAreComplete(locale: AppLocale) throws {
        let source = try stringsTable(.english)
        let target = try stringsTable(locale)
        let keys = source.keys.filter { $0.hasPrefix("toolbar.backgroundTasks.") }
        #expect(keys.count == 13)
        let usedKeys = Set(keys + AppBackgroundTask.Kind.allCases.map(\.titleKey) + [
            "toolbar.status.tasks.countFormat", "toolbar.status.tasks.emptyShort", "toolbar.status.tasks.idleCaption",
            "aiOrganization.banner.viewTask", "aiOrganization.banner.pendingFormat", "aiOrganization.banner.failedFormat"
        ])
        for key in usedKeys {
            let value = try #require(target[key], "\(locale.rawValue) 缺少 \(key)")
            let original = try #require(source[key])
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(value != key)
            #expect(!value.contains("\n") && !value.contains("\r"))
            if locale != .english, keys.contains(key) { #expect(value != original) }
            // 复用的计数、待确认及失败文案也要在目标资源中存在，且参数类型/编号一致。
            let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ll|l)?[diu@]"#)
            func placeholders(_ text: String) -> [String] {
                let string = text as NSString
                return expression.matches(in: text, range: NSRange(location: 0, length: string.length))
                    .map { string.substring(with: $0.range) }.sorted()
            }
            #expect(placeholders(value) == placeholders(original))
        }
    }

    @Test("多语言任务行始终固定高度，窄宽与 RTL 不撑宽", arguments: AppLocale.allCases.filter { $0 != .system }, [CGFloat(240), 384])
    func localizedRowsStayBounded(locale: AppLocale, width: CGFloat) throws {
        try withLanguage(locale) {
            for scale in InterfaceScale.allCases {
                for phase in AppBackgroundTask.Phase.allCases {
                    let task = AppBackgroundTask(id: .tags, phase: phase,
                                                 detail: .progress(processed: 1_234_567, total: 2_000_000_000),
                                                 canCancel: true, opensWindow: true)
                    let view = AppBackgroundTaskRow(task: task, onOpen: {}, onCancel: {})
                        .environment(\.locale, locale.effectiveLocale)
                        .environment(\.starcatInterfaceScale, scale)
                    let size = try measuredSize(view, width: width)
                    #expect(size.width <= width)
                    #expect(size.height == scale.scaled(52))
                }
            }
        }
    }

    @Test("任务超过四行后列表高度不再增长", arguments: [ColorScheme.light, .dark])
    func taskListHeightIsBounded(colorScheme: ColorScheme) throws {
        for count in [1, 4, 7] {
            let tasks = AppBackgroundTask.Kind.allCases.prefix(count).map { AppBackgroundTask(id: $0, phase: .running) }
            let size = try measuredSize(AppBackgroundTaskList(tasks: tasks, onOpen: { _ in }, onCancel: { _ in })
                .environment(\.colorScheme, colorScheme).environment(\.starcatInterfaceScale, InterfaceScale.standard), width: 384)
            #expect(size.width <= 384)
            #expect(size.height <= 4 * 52 + 3)
        }
    }

    /// 直读 lproj，禁止 Bundle 的 fallback 行为让缺译也能通过测试。
    private func stringsTable(_ locale: AppLocale) throws -> [String: String] {
        let resources = try #require(Bundle.main.resourceURL)
        let url = resources.appendingPathComponent("\(locale.rawValue).lproj/Localizable.strings")
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    /// String.l10n 按持久化语言选资源；同步主线程测量后恢复偏好，不能仅改变数字 locale。
    private func withLanguage(_ locale: AppLocale, body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "AppLocaleOverride")
        defaults.set(locale.rawValue, forKey: "AppLocaleOverride")
        defer {
            if let previous { defaults.set(previous, forKey: "AppLocaleOverride") }
            else { defaults.removeObject(forKey: "AppLocaleOverride") }
        }
        try body()
    }

    /// 离屏测量不建立 NSWindow、不读屏幕，不代替真实的点击验收。
    private func measuredSize<Content: View>(_ view: Content, width: CGFloat) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }
}
