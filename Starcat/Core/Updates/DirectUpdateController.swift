//
//  DirectUpdateController.swift
//  Starcat
//
//  Direct 分发渠道的 Sparkle 更新协调器。
//

import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// Direct 版可选的更新源。
///
/// 正式版与 Beta 版使用不同 appcast，避免旧客户端、官网和 Homebrew 把 Beta 构建
/// 误判为正式最新版。Beta appcast 同时包含正式版条目，因此选择 Beta 版的用户
/// 仍能在正式版构建号更新时回到稳定版本。
enum DirectUpdateChannel: String, CaseIterable, Identifiable {
    case stable
    /// 持久化值和订阅地址保留 development，确保既有 Beta 用户升级后继续接收更新。
    case development

    static let preferenceKey = "directUpdateChannel"

    var id: String { rawValue }

    var feedURL: URL {
        switch self {
        case .stable:
            URL(string: "https://starcat.ink/appcast.xml")!
        case .development:
            URL(string: "https://starcat.ink/appcast-development.xml")!
        }
    }
}

#if canImport(Sparkle)
/// Sparkle 2 推荐通过 delegate 动态提供 feed，而不是调用会把 URL 另存进
/// UserDefaults 的已废弃 `setFeedURL`。通道切换因此只修改 Starcat 自己的偏好，
/// 不会留下覆盖 Info.plist 的 Sparkle 历史状态。
@MainActor
private final class DirectUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    var channel: DirectUpdateChannel

    init(channel: DirectUpdateChannel) {
        self.channel = channel
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        channel.feedURL.absoluteString
    }
}
#endif

/// Direct 版自动更新入口。
///
/// App Store target 不链接 Sparkle；本文件通过 `canImport(Sparkle)` 保证同一份源码在
/// App Store 构建中退化为 no-op。Direct target 链接 Sparkle 后才会真正创建
/// `SPUStandardUpdaterController`。这样渠道差异集中在构建配置和这个小控制器里，业务层只
/// 需要判断 `isDirectBuild` / `canCheckForUpdates`。
@MainActor
@Observable
final class DirectUpdateController {

    /// 是否为 Direct 构建。菜单展示只看渠道，不因为公钥尚未配置而消失。
    let isDirectBuild: Bool

    /// Sparkle 公钥是否已配置。未配置时不启动 updater，避免开发环境误触发更新检查。
    let isConfigured: Bool

    /// 当前 Direct 更新通道。非法或缺失的历史偏好一律回退到正式版。
    private(set) var updateChannel: DirectUpdateChannel

    private let preferences: UserDefaults

    #if canImport(Sparkle)
    private let updaterDelegate: DirectUpdateFeedDelegate
    private let updaterController: SPUStandardUpdaterController?
    #endif

    init(
        startingUpdater: Bool = true,
        bundle: Bundle = .main,
        preferences: UserDefaults = .standard
    ) {
        let resolvedChannel = DirectUpdateChannel(
            rawValue: preferences.string(forKey: DirectUpdateChannel.preferenceKey) ?? ""
        ) ?? .stable
        self.preferences = preferences
        self.updateChannel = resolvedChannel
        self.isDirectBuild = DistributionChannel.resolve(from: bundle).isDirect
        self.isConfigured = Self.configuredPublicKey(in: bundle) != nil

        #if canImport(Sparkle)
        let updaterDelegate = DirectUpdateFeedDelegate(channel: resolvedChannel)
        self.updaterDelegate = updaterDelegate
        if isDirectBuild, isConfigured, !TestEnvironment.isRunning {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: startingUpdater,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: nil
            )
        } else {
            self.updaterController = nil
        }
        #endif
    }

    /// 保存更新通道，并立即用新 feed 执行一次用户主动检查。
    ///
    /// Sparkle 只会安装构建号更高的版本，因此从 Beta 版切回正式版不会触发降级；
    /// 用户会等到后续构建号更高的正式版再更新。
    func selectUpdateChannel(_ channel: DirectUpdateChannel) {
        guard isDirectBuild else { return }
        updateChannel = channel
        preferences.set(channel.rawValue, forKey: DirectUpdateChannel.preferenceKey)
        #if canImport(Sparkle)
        updaterDelegate.channel = channel
        #endif
        checkForUpdates()
    }

    /// 当前是否允许用户主动触发检查更新。
    var canCheckForUpdates: Bool {
        guard isDirectBuild, isConfigured else { return false }
        #if canImport(Sparkle)
        return updaterController?.updater.canCheckForUpdates ?? false
        #else
        return false
        #endif
    }

    /// Sparkle 是否按计划自动检查更新。
    ///
    /// 只在 Direct 且 Sparkle 已配置时读写真实 updater；App Store 构建或未配置公钥时固定
    /// 为 `false`，避免 Settings UI 把不可用能力展示成可切换状态。
    var automaticallyChecksForUpdates: Bool {
        get {
            guard isDirectBuild, isConfigured else { return false }
            #if canImport(Sparkle)
            return updaterController?.updater.automaticallyChecksForUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            guard isDirectBuild, isConfigured else { return }
            #if canImport(Sparkle)
            updaterController?.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    /// Sparkle 是否在后台自动下载可用更新。
    ///
    /// Sparkle 的语义是“自动下载 / 准备更新”，最终安装仍可能需要用户确认或重启，
    /// 所以 UI 文案不能承诺完全静默安装。
    var automaticallyDownloadsUpdates: Bool {
        get {
            guard isDirectBuild, isConfigured else { return false }
            #if canImport(Sparkle)
            return updaterController?.updater.automaticallyDownloadsUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            guard isDirectBuild, isConfigured else { return }
            #if canImport(Sparkle)
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
            #endif
        }
    }

    /// 打开 Sparkle 标准检查更新流程。
    ///
    /// 这里不自绘更新 UI，保持 Sparkle 负责签名校验、下载、安装和错误展示。
    /// 产品约束：更新弹窗与 appcast release notes 固定英文——Direct 打包会剥离
    /// Sparkle.framework 的非英文本地化；说明正文由 inject-appcast-release-notes.py
    /// 只写入 `xml:lang=en` 的 description。不跟 `AppLocale` 走。
    func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        #if canImport(Sparkle)
        updaterController?.checkForUpdates(sender)
        #endif
    }

    private static func configuredPublicKey(in bundle: Bundle) -> String? {
        let rawValue = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
