//
//  DirectUpdateLocalizationTests.swift
//  StarcatTests
//
//  使用隔离偏好与临时翻译资源，验证更新显示不会被系统语言或启动缓存覆盖。
//

import Foundation
import Testing
@testable import Starcat

@Suite("DirectUpdateLocalization")
struct DirectUpdateLocalizationTests {
    private let notes = [
        "starcat:releaseNotes-en": "<h2>New</h2><p>Repository Skills</p>",
        "starcat:releaseNotes-zh-Hans": "<h2>新增</h2><p>仓库技能</p>"
    ]

    @Test("全部应用语言均优先于系统语言", arguments: AppLocale.allCases.filter { $0 != .system })
    func explicitLanguageOverridesSystem(selection: AppLocale) {
        let preferences = makePreferences()
        preferences.set(selection.rawValue, forKey: DirectUpdateLocalization.preferenceKey)

        #expect(DirectUpdateLocalization.preferredLanguages(
            preferences: preferences, systemLanguages: ["ja"]
        ).first == selection.rawValue)
        let expected = selection == .simplifiedChinese || selection == .traditionalChinese
            ? notes["starcat:releaseNotes-zh-Hans"] : notes["starcat:releaseNotes-en"]
        #expect(DirectUpdateLocalization.releaseNotes(
            in: notes, preferences: preferences, systemLanguages: ["ja"]
        ) == expected)
    }

    @Test("中文、英文和跟随系统切换无需重启")
    func languageChangesAreReadOnEveryLookup() {
        let preferences = makePreferences()
        for (selection, expected) in [
            ("zh-Hans", "starcat:releaseNotes-zh-Hans"),
            ("en", "starcat:releaseNotes-en"),
            ("zh-Hant", "starcat:releaseNotes-zh-Hans"),
            ("system", "starcat:releaseNotes-en")
        ] {
            preferences.set(selection, forKey: DirectUpdateLocalization.preferenceKey)
            #expect(DirectUpdateLocalization.releaseNotes(
                in: notes, preferences: preferences, systemLanguages: ["en-US"]
            ) == notes[expected])
        }
    }

    @Test("未设置和跟随系统都读取系统语言")
    func systemSelectionUsesSystemLanguage() {
        let preferences = makePreferences()
        for selection in [nil, "system"] as [String?] {
            preferences.set(selection, forKey: DirectUpdateLocalization.preferenceKey)
            #expect(DirectUpdateLocalization.releaseNotes(
                in: notes, preferences: preferences, systemLanguages: ["zh-Hans-CN", "en"]
            ) == notes["starcat:releaseNotes-zh-Hans"])
            #expect(DirectUpdateLocalization.releaseNotes(
                in: notes, preferences: preferences, systemLanguages: ["en-US", "zh-Hans"]
            ) == notes["starcat:releaseNotes-en"])
        }
    }

    @Test("框架命名和英文 Base 资源正确匹配")
    func sparkleResourceNamesMatchApplicationLanguages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Fixture.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "ink.starcat.update-localization-fixture",
                    "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        for language in ["Base", "zh_CN", "zh_TW", "ja"] {
            try FileManager.default.createDirectory(
                at: resources.appendingPathComponent("\(language).lproj"), withIntermediateDirectories: true
            )
        }
        let bundle = try #require(Bundle(url: root.appendingPathComponent("Fixture.bundle")))
        let preferences = makePreferences()
        for (selection, expected) in [
            ("zh-Hans", "zh_CN.lproj"), ("zh-Hant", "zh_TW.lproj"),
            ("en", "Base.lproj"), ("ja", "ja.lproj"), ("id", "Base.lproj")
        ] {
            preferences.set(selection, forKey: DirectUpdateLocalization.preferenceKey)
            #expect(DirectUpdateLocalization.resourceBundle(
                in: bundle, preferences: preferences, systemLanguages: ["zh-Hans"]
            )?.bundleURL.lastPathComponent == expected)
        }
    }

    @Test("旧清单和空说明交回 Sparkle 原始 getter")
    func missingLocalizedNotesPreserveOriginalBehavior() {
        let preferences = makePreferences()
        #expect(DirectUpdateLocalization.releaseNotes(
            in: ["description": "Legacy notes"], preferences: preferences
        ) == nil)
        #expect(DirectUpdateLocalization.releaseNotes(
            in: ["starcat:releaseNotes-en": " \n "], preferences: preferences, systemLanguages: ["en"]
        ) == nil)
    }

    /// 独立 suite 不读写用户的实际语言选择。
    private func makePreferences() -> UserDefaults {
        UserDefaults(suiteName: "DirectUpdateLocalizationTests.\(UUID().uuidString)")!
    }
}
