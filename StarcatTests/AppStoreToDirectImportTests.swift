//
//  AppStoreToDirectImportTests.swift
//  StarcatTests
//
//  Direct 首次从 App Store 拷贝数据：只认正式商店容器、确认后才拷、临时文件跳过。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AppStoreToDirectImport")
struct AppStoreToDirectImportTests {

    @Test("只在 Direct、尚未问过、商店有数据且 Direct 为空时弹出")
    func promptsOnlyForOfficialEmptyDirect() {
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isEligibleDirectBuild: true,
                hasRecordedDecision: false,
                storeHasImportableData: true,
                destinationIsEmpty: true
            )
        )
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isEligibleDirectBuild: false,
                hasRecordedDecision: false,
                storeHasImportableData: true,
                destinationIsEmpty: true
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isEligibleDirectBuild: true,
                hasRecordedDecision: true,
                storeHasImportableData: true,
                destinationIsEmpty: true
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isEligibleDirectBuild: true,
                hasRecordedDecision: false,
                storeHasImportableData: true,
                destinationIsEmpty: false
            ) == false
        )
    }

    @Test("正式 Direct 和 Debug Direct 都可以弹出，App Store 渠道不弹")
    func acceptsOfficialAndDebugDirect() {
        #expect(
            AppStoreToDirectImportEvaluator.isEligibleDirectBuild(
                bundleIdentifier: "com.starcat.app.direct.debug",
                channel: .direct
            )
        )
        #expect(
            AppStoreToDirectImportEvaluator.isEligibleDirectBuild(
                bundleIdentifier: "com.starcat.app.direct",
                channel: .direct
            )
        )
        #expect(
            AppStoreToDirectImportEvaluator.isEligibleDirectBuild(
                bundleIdentifier: "com.starcat.app.direct",
                channel: .appStore
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.isEligibleDirectBuild(
                bundleIdentifier: "com.starcat.app.store.debug",
                channel: .appStore
            ) == false
        )
    }

    @Test("已有导入决策时不探测商店容器，避免每次启动重复弹授权框", arguments: [
        AppStoreToDirectImportDecision.skipped, .imported
    ])
    func skipsStoreProbeWhenDecisionAlreadyRecorded(recordedDecision: AppStoreToDirectImportDecision) throws {
        let suite = "starcat.direct-import.probe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppStoreToDirectImportDecisionStore(defaults: defaults).record(recordedDecision)
        // 重建决策存储，模拟后续冷启动读取之前的“跳过 / 已导入”选择。
        let restored = AppStoreToDirectImportDecisionStore(defaults: defaults)
        #expect(restored.decision == recordedDecision)
        var destinationProbes = 0
        var storeProbes = 0

        let decision = AppStoreToDirectImportEvaluator.decidePrompt(
            isEligibleDirectBuild: true,
            hasRecordedDecision: restored.decision != nil,
            destinationIsEmpty: { destinationProbes += 1; return true },
            storeHasImportableData: { storeProbes += 1; return true }
        )

        #expect(decision.shouldPrompt == false)
        #expect(decision.destinationProbed == false)
        #expect(decision.storeProbed == false)
        #expect(destinationProbes == 0)
        #expect(storeProbes == 0)
    }

    @Test("非 Direct 渠道启动时不探测商店容器")
    func skipsStoreProbeForNonDirectChannel() {
        var destinationProbes = 0
        var storeProbes = 0

        let decision = AppStoreToDirectImportEvaluator.decidePrompt(
            isEligibleDirectBuild: false,
            hasRecordedDecision: false,
            destinationIsEmpty: { destinationProbes += 1; return true },
            storeHasImportableData: { storeProbes += 1; return true }
        )

        #expect(decision.shouldPrompt == false)
        #expect(destinationProbes == 0)
        #expect(storeProbes == 0)
    }

    @Test("Direct 已有用户数据时不探测商店容器")
    func skipsStoreProbeWhenDestinationNotEmpty() {
        var destinationProbes = 0
        var storeProbes = 0

        let decision = AppStoreToDirectImportEvaluator.decidePrompt(
            isEligibleDirectBuild: true,
            hasRecordedDecision: false,
            destinationIsEmpty: { destinationProbes += 1; return false },
            storeHasImportableData: { storeProbes += 1; return true }
        )

        #expect(decision.shouldPrompt == false)
        #expect(decision.destinationProbed)
        #expect(decision.storeProbed == false)
        #expect(destinationProbes == 1)
        #expect(storeProbes == 0)
    }

    @Test("确有需要时才探测商店容器，弹出条件不变")
    func probesStoreOnlyWhenPromptPossible() {
        var probes: [String] = []

        let prompts = AppStoreToDirectImportEvaluator.decidePrompt(
            isEligibleDirectBuild: true,
            hasRecordedDecision: false,
            destinationIsEmpty: { probes.append("destination"); return true },
            storeHasImportableData: { probes.append("store"); return true }
        )
        #expect(prompts.shouldPrompt)
        #expect(prompts.storeProbed)
        #expect(prompts.storeHasImportableData)
        #expect(probes == ["destination", "store"])

        probes.removeAll()
        let staysSilent = AppStoreToDirectImportEvaluator.decidePrompt(
            isEligibleDirectBuild: true,
            hasRecordedDecision: false,
            destinationIsEmpty: { probes.append("destination"); return true },
            storeHasImportableData: { probes.append("store"); return false }
        )
        #expect(staysSilent.shouldPrompt == false)
        #expect(staysSilent.storeProbed)
        #expect(probes == ["destination", "store"])
    }

    @Test("Debug 商店容器不参与检测，正式商店库才算可导入")
    func ignoresDebugStoreContainer() throws {
        try withImportHome { home, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "42")
            #expect(AppStoreToDirectImportEvaluator.storeHasImportableData(layout: layout, fileManager: fileManager))
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))

            let debugContainer = home
                .appendingPathComponent("Library/Containers/com.starcat.app.store.debug/Data/Library/Application Support/com.starcat.app/users/99", isDirectory: true)
            try fileManager.createDirectory(at: debugContainer, withIntermediateDirectories: true)
            try Data("debug".utf8).write(to: debugContainer.appendingPathComponent("starcat.sqlite"))

            try fileManager.removeItem(at: layout.storeStarcatAppSupport)
            #expect(AppStoreToDirectImportEvaluator.storeHasImportableData(layout: layout, fileManager: fileManager))

            try fileManager.removeItem(at: layout.storeContainerURL)
            #expect(AppStoreToDirectImportEvaluator.storeHasImportableData(layout: layout, fileManager: fileManager) == false)
        }
    }

    @Test("正式商店容器目录存在即可弹出，不要求当前进程能读到 sqlite")
    func treatsOfficialStoreContainerAsImportable() throws {
        try withImportHome { _, layout, fileManager in
            try fileManager.createDirectory(at: layout.storeContainerURL, withIntermediateDirectories: true)
            #expect(AppStoreToDirectImportEvaluator.storeHasImportableData(layout: layout, fileManager: fileManager))
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))
        }
    }

    @Test("启动期自动建的 _anonymous 库和空凭据文件不算 Direct 已经用过")
    func ignoresBootstrapAnonymousDatabaseWhenCheckingDestination() throws {
        try withImportHome { _, layout, fileManager in
            let anonymous = layout.directStarcatAppSupport
                .appendingPathComponent("users/_anonymous", isDirectory: true)
            try fileManager.createDirectory(at: anonymous, withIntermediateDirectories: true)
            try Data("anon".utf8).write(to: anonymous.appendingPathComponent("starcat.sqlite"))
            try Data("{}".utf8).write(
                to: layout.directStarcatAppSupport.appendingPathComponent("credentials.json")
            )
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))

            let realUser = layout.directStarcatAppSupport
                .appendingPathComponent("users/20341123", isDirectory: true)
            try fileManager.createDirectory(at: realUser, withIntermediateDirectories: true)
            try Data("user".utf8).write(to: realUser.appendingPathComponent("starcat.sqlite"))
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager) == false)
        }
    }

    @Test("确认拷贝会带走库、凭据、ZIP、头像缓存，并跳过临时文件")
    func copiesDurableFilesAndSkipsTemporary() throws {
        try withImportHome { _, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "42")
            try Data("token".utf8).write(
                to: layout.storeStarcatAppSupport.appendingPathComponent("credentials.json")
            )
            let legacyModel = layout.storeStarcatAppSupport
                .appendingPathComponent("models/llm/example@r1", isDirectory: true)
            try fileManager.createDirectory(at: legacyModel, withIntermediateDirectories: true)
            try Data("large-model-placeholder".utf8).write(
                to: legacyModel.appendingPathComponent("model.safetensors"))

            let zipDirectory = layout.storeProductSupport.appendingPathComponent("archives/github.com/octo", isDirectory: true)
            try fileManager.createDirectory(at: zipDirectory, withIntermediateDirectories: true)
            try Data("zip".utf8).write(to: zipDirectory.appendingPathComponent("repo.zip"))
            try Data("partial".utf8).write(to: zipDirectory.appendingPathComponent("repo.zip.tmp"))

            try fileManager.createDirectory(at: layout.storeKingfisherCache, withIntermediateDirectories: true)
            try Data("avatar".utf8).write(to: layout.storeKingfisherCache.appendingPathComponent("owner.png"))

            try fileManager.createDirectory(at: layout.storeWidgetGroup, withIntermediateDirectories: true)
            try Data("widget".utf8).write(to: layout.storeWidgetGroup.appendingPathComponent("widget-snapshot-v1.json"))

            try writeStorePreferences(
                layout: layout,
                fileManager: fileManager,
                values: [
                    "settings.appearanceMode": "dark",
                    "settings.pro.isProUser": true
                ]
            )

            let defaults = try isolatedDefaults()
            let service = AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: fileManager,
                processInspector: FixedProcessInspector(isRunning: false),
                destinationDefaults: defaults
            )

            try service.copyConfirmedData()

            #expect(fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("users/42/starcat.sqlite").path))
            #expect(fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("credentials.json").path))
            #expect(fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("models").path) == false)
            #expect(fileManager.fileExists(atPath: layout.directProductSupport.appendingPathComponent("archives/github.com/octo/repo.zip").path))
            #expect(fileManager.fileExists(atPath: layout.directProductSupport.appendingPathComponent("archives/github.com/octo/repo.zip.tmp").path) == false)
            #expect(fileManager.fileExists(atPath: layout.directKingfisherCache.appendingPathComponent("owner.png").path))
            #expect(fileManager.fileExists(atPath: layout.directWidgetGroup.appendingPathComponent("widget-snapshot-v1.json").path))
            #expect(fileManager.fileExists(atPath: layout.storeStarcatAppSupport.appendingPathComponent("users/42/starcat.sqlite").path))
            #expect(fileManager.fileExists(atPath: legacyModel.path))
            #expect(defaults.string(forKey: "settings.appearanceMode") == "dark")
            #expect(defaults.object(forKey: AppSettings.Keys.isProUser) == nil)
        }
    }

    @Test("读不到商店 Widget App Group 时仍拷主库，不把整次导入判失败")
    func skipsUnreadableStoreWidgetGroup() throws {
        try withImportHome { _, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "42")
            try Data("token".utf8).write(
                to: layout.storeStarcatAppSupport.appendingPathComponent("credentials.json")
            )
            try fileManager.createDirectory(at: layout.storeWidgetGroup, withIntermediateDirectories: true)
            try Data("widget".utf8).write(
                to: layout.storeWidgetGroup.appendingPathComponent("widget-snapshot-v1.json")
            )

            let denying = PermissionDenyingFileManager(deniedPath: layout.storeWidgetGroup.path)
            let service = AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: denying,
                processInspector: FixedProcessInspector(isRunning: false),
                destinationDefaults: try isolatedDefaults()
            )
            try service.copyConfirmedData()

            #expect(fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("users/42/starcat.sqlite").path))
            #expect(
                fileManager.fileExists(
                    atPath: layout.directWidgetGroup.appendingPathComponent("widget-snapshot-v1.json").path
                ) == false
            )
        }
    }

    @Test("商店容器在但读不到库时拒绝空拷贝，避免记下 imported")
    func refusesEmptyCopyWhenStoreDataUnreadable() throws {
        try withImportHome { _, layout, fileManager in
            try fileManager.createDirectory(at: layout.storeContainerURL, withIntermediateDirectories: true)
            let service = AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: fileManager,
                processInspector: FixedProcessInspector(isRunning: false),
                destinationDefaults: try isolatedDefaults()
            )

            #expect(throws: AppStoreToDirectImportError.self) {
                try service.copyConfirmedData()
            }
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))
        }
    }

    @Test("商店版仍在运行时拒绝拷贝")
    func refusesCopyWhileStoreAppRunning() throws {
        try withImportHome { _, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "1")
            let service = AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: fileManager,
                processInspector: FixedProcessInspector(isRunning: true),
                destinationDefaults: try isolatedDefaults()
            )

            #expect(throws: AppStoreToDirectImportError.storeAppRunning) {
                try service.copyConfirmedData()
            }
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))
        }
    }

    @Test("Pro 与 StoreKit 相关偏好不会迁入 Direct")
    func skipsSubscriptionPreferenceKeys() {
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey("settings.appearanceMode"))
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey(AppSettings.Keys.isProUser) == false)
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey("SUEnableAutomaticChecks") == false)
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey("storekit.transaction.cache") == false)
        #expect(
            AppStoreToDirectImportCopyService.shouldMigratePreferenceKey(
                AppStoreToDirectImportIdentity.decisionDefaultsKey
            ) == false
        )
    }

    private func withImportHome(
        _ body: (URL, AppStoreToDirectImportLayout, FileManager) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(
            "direct-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try body(home, AppStoreToDirectImportLayout(homeDirectory: home), fileManager)
    }

    private func writeStoreDatabase(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager,
        userID: String
    ) throws {
        let directory = layout.storeStarcatAppSupport
            .appendingPathComponent("users/\(userID)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("sqlite".utf8).write(to: directory.appendingPathComponent("starcat.sqlite"))
    }

    private func writeStorePreferences(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager,
        values: [String: Any]
    ) throws {
        let directory = layout.storePreferencesPlist.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: layout.storePreferencesPlist)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "starcat.direct-import.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw AppStoreToDirectImportError.copyFailed(message: "defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private struct FixedProcessInspector: AppStoreToDirectImportProcessInspecting {
    let isRunning: Bool

    func isAppStoreStarcatRunning() -> Bool {
        isRunning
    }
}

/// 模拟 Direct 没有商店 Widget App Group entitlement：目录存在，一列内容就 TCC 拒绝。
private final class PermissionDenyingFileManager: FileManager, @unchecked Sendable {
    let deniedPath: String

    init(deniedPath: String) {
        self.deniedPath = deniedPath
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.path == deniedPath || url.path.hasPrefix(deniedPath + "/") {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileReadNoPermission.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "未能打开文件 “group.com.starcat.app.store.widgets”，因为你没有查看它的权限。"
                ]
            )
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
