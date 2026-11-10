//
//  AppStoreToDirectImport.swift
//  Starcat
//
//  Direct 正式版 / Debug 第一次打开时，把本机 App Store 正式容器里的数据拷到 Direct。
//
//  关键约束：
//  - 拷贝来源只认 `com.starcat.app.store`，忽略 `.store.debug` 和任何 Direct 容器；
//  - Debug Direct 可以弹窗，方便本机验证；生产用户仍走正式 Direct；
//  - 用户数据只拷不共用：两边目录仍然独立，App Store 原数据不删；本地 AI 模型
//    不走本导入链，由共享模型协调器迁入 App Group，避免复制数 GB 权重；
//  - 必须用户确认；选「不拷贝」后不再追问；
//  - Apple 订阅 / StoreKit 镜像不迁，避免 Direct 出现假 Pro。
//

import AppKit
import Foundation

/// 正式渠道的固定标识。
///
/// Direct Debug 允许弹窗，方便本机走同一条导入链；商店 Debug 仍然排除，
/// 避免把开发容器误当成用户数据源。
enum AppStoreToDirectImportIdentity {
    static let officialAppStoreBundleID = "com.starcat.app.store"
    static let officialDirectBundleID = "com.starcat.app.direct"
    static let debugDirectBundleID = "com.starcat.app.direct.debug"
    static let storeWidgetGroupID = "group.com.starcat.app.store.widgets"
    static let directWidgetGroupID = "8WCUMGCWMB.com.starcat.app.direct.widgets"
    static let kingfisherCacheFolderName = "com.onevcat.Kingfisher.ImageCache.default"
    static let storePreferencesFileName = "com.starcat.app.store.plist"
    static let productSupportFolderName = "Starcat"
    static let decisionDefaultsKey = "launch.directImport.fromAppStore.decision.v1"
    static let debugReplayNotification = Notification.Name("starcat.debug.replayAppStoreImport")
}

/// 用户对首次导入弹窗的选择。
enum AppStoreToDirectImportDecision: String, Equatable, Sendable {
    case skipped
    case imported
}

/// Direct / App Store 在本机家目录下的路径布局。
///
/// 生产走 POSIX 家目录：导入只跑在无沙盒 Direct（正式或 Debug）里。
/// 测试注入临时 `homeDirectory`，避免碰到真实 Containers。
struct AppStoreToDirectImportLayout: Sendable {
    var homeDirectory: URL

    static func live() -> AppStoreToDirectImportLayout {
        AppStoreToDirectImportLayout(
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
    }

    var storeContainerURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.officialAppStoreBundleID, isDirectory: true)
    }

    var storeLibraryURL: URL {
        storeContainerURL
            .appendingPathComponent("Data/Library", isDirectory: true)
    }

    var storeApplicationSupportRoot: URL {
        storeLibraryURL.appendingPathComponent("Application Support", isDirectory: true)
    }

    var storeStarcatAppSupport: URL {
        storeApplicationSupportRoot.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
    }

    var storeProductSupport: URL {
        storeApplicationSupportRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.productSupportFolderName,
            isDirectory: true
        )
    }

    var storeCachesRoot: URL {
        storeLibraryURL.appendingPathComponent("Caches", isDirectory: true)
    }

    var storeKingfisherCache: URL {
        storeCachesRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.kingfisherCacheFolderName,
            isDirectory: true
        )
    }

    var storePreferencesPlist: URL {
        storeLibraryURL
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.storePreferencesFileName, isDirectory: false)
    }

    var storeWidgetGroup: URL {
        homeDirectory
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.storeWidgetGroupID, isDirectory: true)
    }

    var directApplicationSupportRoot: URL {
        homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    var directStarcatAppSupport: URL {
        directApplicationSupportRoot.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
    }

    var directProductSupport: URL {
        directApplicationSupportRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.productSupportFolderName,
            isDirectory: true
        )
    }

    var directCachesRoot: URL {
        homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    var directKingfisherCache: URL {
        directCachesRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.kingfisherCacheFolderName,
            isDirectory: true
        )
    }

    var directWidgetGroup: URL {
        homeDirectory
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.directWidgetGroupID, isDirectory: true)
    }
}

/// 是否弹出导入确认的纯判断。IO 和进程检查放在调用方。
enum AppStoreToDirectImportEvaluator {
    static func shouldPrompt(
        isEligibleDirectBuild: Bool,
        hasRecordedDecision: Bool,
        storeHasImportableData: Bool,
        destinationIsEmpty: Bool
    ) -> Bool {
        isEligibleDirectBuild
            && !hasRecordedDecision
            && storeHasImportableData
            && destinationIsEmpty
    }

    /// 按「廉价判断优先」的顺序决定是否探测商店容器。
    ///
    /// 商店容器属于另一个 App 的受保护数据：macOS 15+ 对未授权探测可能弹出
    /// 「访问其他 App 的数据」授权框，而且授权未必跨启动保留。因此只有渠道合格、
    /// 从未做过导入决策且 Direct 尚无用户数据时才允许探测，避免用户选过
    /// 「跳过 / 已导入」之后每次冷启动都重复弹窗。
    static func decidePrompt(
        isEligibleDirectBuild: Bool,
        hasRecordedDecision: Bool,
        destinationIsEmpty: () -> Bool,
        storeHasImportableData: () -> Bool
    ) -> PromptDecision {
        let mayPrompt = isEligibleDirectBuild && !hasRecordedDecision
        let destinationEmpty = mayPrompt ? destinationIsEmpty() : false
        let shouldProbeStore = mayPrompt && destinationEmpty
        let storeHasData = shouldProbeStore ? storeHasImportableData() : false
        return PromptDecision(
            shouldPrompt: shouldPrompt(
                isEligibleDirectBuild: isEligibleDirectBuild,
                hasRecordedDecision: hasRecordedDecision,
                storeHasImportableData: storeHasData,
                destinationIsEmpty: destinationEmpty
            ),
            destinationProbed: mayPrompt,
            destinationEmpty: destinationEmpty,
            storeProbed: shouldProbeStore,
            storeHasImportableData: storeHasData
        )
    }

    /// `decidePrompt` 的探测执行结果：控制器用来记日志，测试用来断言没有越级探测。
    struct PromptDecision: Equatable, Sendable {
        var shouldPrompt: Bool
        var destinationProbed: Bool
        var destinationEmpty: Bool
        var storeProbed: Bool
        var storeHasImportableData: Bool
    }

    /// Direct 正式包和 Debug 包都可以问；App Store 渠道一律不问。
    static func isEligibleDirectBuild(
        bundleIdentifier: String?,
        channel: DistributionChannel
    ) -> Bool {
        guard channel.isDirect else { return false }
        return bundleIdentifier == AppStoreToDirectImportIdentity.officialDirectBundleID
            || bundleIdentifier == AppStoreToDirectImportIdentity.debugDirectBundleID
    }

    /// 商店容器里有用户库、加密凭据，或至少能看见正式商店容器，才值得问。
    ///
    /// 关键约束：macOS 会用 MACL 保护别的 App 的 `Containers/.../Data`。
    /// Direct 没有「完全磁盘访问」时，`fileExists` 看 sqlite / credentials 会返回 false，
    /// 但 `Containers/com.starcat.app.store` 目录本身通常仍可见。只认内部文件就会导致
    /// 正式用户永远看不到导入窗。
    static func storeHasImportableData(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager
    ) -> Bool {
        containsReadableStoreUserData(at: layout.storeStarcatAppSupport, fileManager: fileManager)
            || fileManager.fileExists(atPath: layout.storeContainerURL.path)
    }

    /// 已经能读到库或凭据，拷贝才算有货。
    static func containsReadableStoreUserData(
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        containsStarcatDatabase(at: root, fileManager: fileManager)
            || fileManager.fileExists(atPath: root.appendingPathComponent("credentials.json").path)
    }

    /// Direct 已有真实用户库才当作已经用过，不再覆盖。
    ///
    /// 启动链会先 `DatabaseManager(userId: nil)` 建 `users/_anonymous`，再
    /// `KeychainManager.ping()` 写出 `credentials.json`。这两份文件在第一次打开
    /// Direct 时必然存在，不能当成「用户已经用过」。只认 `users/<githubUserId>/`。
    static func destinationIsEmpty(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager
    ) -> Bool {
        !containsRealUserStarcatDatabase(at: layout.directStarcatAppSupport, fileManager: fileManager)
    }

    /// 忽略 `_anonymous` 占位库，只找登录用户目录下的 `starcat.sqlite`。
    static func containsRealUserStarcatDatabase(at root: URL, fileManager: FileManager) -> Bool {
        let users = root.appendingPathComponent(AppConstants.usersDirectoryName, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: users,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator where url.lastPathComponent == AppConstants.databaseFileName {
            let parentName = url.deletingLastPathComponent().lastPathComponent
            if parentName == AppConstants.anonymousUserDirectoryName { continue }
            return true
        }
        return false
    }

    static func containsStarcatDatabase(at root: URL, fileManager: FileManager) -> Bool {
        let users = root.appendingPathComponent(AppConstants.usersDirectoryName, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: users,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator where url.lastPathComponent == AppConstants.databaseFileName {
            return true
        }
        return false
    }
}

/// 首次导入选择落在 Direct 自己的 UserDefaults 里，和商店版 plist 隔离。
struct AppStoreToDirectImportDecisionStore {
    var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var decision: AppStoreToDirectImportDecision? {
        guard let raw = defaults.string(forKey: AppStoreToDirectImportIdentity.decisionDefaultsKey) else {
            return nil
        }
        return AppStoreToDirectImportDecision(rawValue: raw)
    }

    func record(_ decision: AppStoreToDirectImportDecision) {
        defaults.set(decision.rawValue, forKey: AppStoreToDirectImportIdentity.decisionDefaultsKey)
    }
}

/// Debug 菜单重放导入确认层；不改磁盘数据，只把 sheet 再拉出来。
enum AppStoreToDirectImportDebug {
    static let replayNotification = Notification.Name("starcat.debug.replayAppStoreImport")

    @MainActor
    static func requestManualReplay() {
        NotificationCenter.default.post(name: replayNotification, object: nil)
    }
}

/// 查询商店版是否仍在运行。测试注入假实现，避免依赖本机进程。
protocol AppStoreToDirectImportProcessInspecting: Sendable {
    func isAppStoreStarcatRunning() -> Bool
}

struct LaunchServicesAppStoreProcessInspector: AppStoreToDirectImportProcessInspecting {
    func isAppStoreStarcatRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppStoreToDirectImportIdentity.officialAppStoreBundleID
        ).isEmpty
    }
}

/// 文件拷贝已在启动前检查过商店版进程，后台任务不再重复查。
struct IdleAppStoreProcessInspector: AppStoreToDirectImportProcessInspecting {
    func isAppStoreStarcatRunning() -> Bool { false }
}
