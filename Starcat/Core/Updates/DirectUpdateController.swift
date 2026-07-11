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

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController?
    #endif

    init(startingUpdater: Bool = true, bundle: Bundle = .main) {
        self.isDirectBuild = DistributionChannel.resolve(from: bundle).isDirect
        self.isConfigured = Self.configuredPublicKey(in: bundle) != nil

        #if canImport(Sparkle)
        if isDirectBuild, isConfigured, !TestEnvironment.isRunning {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: startingUpdater,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            self.updaterController = nil
        }
        #endif
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
