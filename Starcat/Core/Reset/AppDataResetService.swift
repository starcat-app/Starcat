//
//  AppDataResetService.swift
//  Starcat
//
//  本机数据恢复出厂协调器。
//
//  职责：
//  - 释放当前登录用户的数据库连接，让物理删除 SQLite 文件变得可控；
//  - 删除当前 GitHub user id 对应的本地数据库目录；
//  - 清理不属于 AppSettings 的零散 UserDefaults 本机状态；
//  - 调用 AppSettings.resetToDefaults() 抹掉本机配置与加密凭据。
//
//  关键边界：
//  - 只处理本机文件、UserDefaults、加密凭据，不调用 GitHub / CloudKit / 后端服务；
//  - 不修改 App Store 订阅购买记录；订阅权益由 StoreKit 在下次启动时重新刷新；
//  - 删除目标按 GitHub user id 定位，避免用户改名后误删别的目录。
//

import Foundation

/// Storage 页“清空所有数据”的目标账号。
struct AppDataResetTarget: Equatable, Identifiable, Sendable {
    let userID: Int64
    let login: String

    var id: Int64 { userID }
}

/// 本机恢复出厂失败。
enum AppDataResetError: LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String.l10n("settings.storage.resetAll.error.notAuthenticated")
        }
    }
}

@MainActor
final class AppDataResetService {
    private let database: any DatabaseManaging
    private let settings: AppSettings
    private let fileManager: FileManager
    private let databaseBasePathOverride: URL?
    private let standardDefaults: UserDefaults

    init(
        database: any DatabaseManaging,
        settings: AppSettings,
        fileManager: FileManager = .default,
        databaseBasePathOverride: URL? = nil,
        standardDefaults: UserDefaults = .standard
    ) {
        self.database = database
        self.settings = settings
        self.fileManager = fileManager
        self.databaseBasePathOverride = databaseBasePathOverride
        self.standardDefaults = standardDefaults
    }

    /// 执行本机恢复出厂。
    ///
    /// - Parameters:
    ///   - target: 当前已登录 GitHub 用户；调用方必须来自 AuthSession 的真实登录态。
    ///   - releaseCurrentSession: 通常传 `AuthSession.signOut()`，用于清登录态并切到匿名库。
    ///   - clearGeneratedCaches: 清 README 以外的全局磁盘缓存 / 生成物。README 在当前用户
    ///     SQLite 中，删除用户 DB 目录即可一并清掉。
    func resetLocalData(
        for target: AppDataResetTarget,
        releaseCurrentSession: @MainActor () async -> Void,
        clearGeneratedCaches: @MainActor () async -> Void = {}
    ) async throws {
        guard target.userID > 0,
              !target.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppDataResetError.notAuthenticated
        }

        await releaseCurrentSession()
        try await database.reopen(userId: nil)
        await clearGeneratedCaches()
        try removeUserDatabaseDirectory(userID: target.userID)
        try settings.resetToDefaults()
        resetNonSettingsDefaults()

        AppLog.general.info(
            "Local app data reset completed for userId=\(target.userID, privacy: .public), login=\(target.login, privacy: .public)"
        )
    }

    private func removeUserDatabaseDirectory(userID: Int64) throws {
        let databaseURL = try DatabaseManager.databaseFileURL(
            userId: userID,
            basePathOverride: databaseBasePathOverride
        )
        let userDirectory = databaseURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: userDirectory.path) else { return }
        try fileManager.removeItem(at: userDirectory)
    }

    /// 清理不归 AppSettings 管的 UserDefaults 状态。
    ///
    /// 这些 key 大多是 scene / onboarding / profile 快照等局部状态。它们不属于
    /// 业务数据库，也不在 AppSettings 里，但恢复出厂时应当回到首次安装体验。
    private func resetNonSettingsDefaults() {
        let exactKeys: Set<String> = [
            "AppLocaleOverride",
            "onboarding.hasCompletedStepGuide",
            "launchSplash.hasCompletedColdStart",
            "settings.ai.lastSelectedProfileID",
            "DebugLayoutOverlay",
            "DebugAIHTTPLogging",
            "auth.lastLogin",
            MainWindowFrameDefaults.defaultsKey
        ]
        let prefixes = [
            "userprofile.snapshot.",
            "contribution.calendar.",
            "developer.languages.snapshot."
        ]

        for key in standardDefaults.dictionaryRepresentation().keys {
            if exactKeys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) {
                standardDefaults.removeObject(forKey: key)
            }
        }
    }
}
