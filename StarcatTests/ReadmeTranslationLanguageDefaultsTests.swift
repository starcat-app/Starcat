//
//  ReadmeTranslationLanguageDefaultsTests.swift
//  StarcatTests
//
//  HOM-198：验证 `ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier:)`
//  把 BCP-47 locale identifier 正确映射到 README 翻译目标语言枚举。
//
//  覆盖目标：
//  - 中文：简体（`zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh` / 旧 POSIX `zh_CN`）→ `.simplifiedChinese`；
//  - 中文：繁体（`zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO` / `zh-Hant-TW`）→ `.traditionalChinese`；
//  - 其余 16 种支持语言按 language code 映射到对应目标；
//  - 不支持或无效 identifier → `.english`（fallback）。
//
//  这部分不测试 `defaultForCurrentLocale()` 本身——它读 `Bundle.main.preferredLocalizations`，
//  在测试 host 里值不稳定。可注入版本 `defaultLanguage(forLocaleIdentifier:)`
//  承载全部业务规则，是真正需要锁定的契约。
//

import Testing
import Foundation
@testable import Starcat

@Suite("ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier:)")
struct ReadmeTranslationLanguageDefaultsTests {

    // MARK: - 中文：简体

    @Test("zh-Hans → 简体中文", arguments: [
        "zh-Hans",
        "zh-Hans-CN",
        "zh-CN",
        "zh-SG",
        "zh",          // 裸 zh，按"未指定脚本/地区时落简体"约定
        "zh_CN"        // 旧 POSIX 风格，Locale.Language 仍应解析为 zh
    ])
    func simplifiedChineseIdentifiers(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .simplifiedChinese
        )
    }

    // MARK: - 中文：繁体

    @Test("zh-Hant / zh-TW / zh-HK / zh-MO → 繁體中文", arguments: [
        "zh-Hant",
        "zh-Hant-TW",
        "zh-Hant-HK",
        "zh-TW",
        "zh-HK",
        "zh-MO"
    ])
    func traditionalChineseIdentifiers(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .traditionalChinese
        )
    }

    // MARK: - 日韩

    @Test("ja* → 日本語", arguments: ["ja", "ja-JP", "ja_JP"])
    func japaneseIdentifiers(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .japanese
        )
    }

    @Test("ko* → 한국어", arguments: ["ko", "ko-KR", "ko_KR"])
    func koreanIdentifiers(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .korean
        )
    }

    // MARK: - 其余已支持语言

    @Test("其余目标 locale 映射到对应 README 翻译语言", arguments: [
        ("en-US", ReadmeTranslationLanguage.english),
        ("de-DE", ReadmeTranslationLanguage.german),
        ("fr-FR", ReadmeTranslationLanguage.french),
        ("es-ES", ReadmeTranslationLanguage.spanish),
        ("pt-BR", ReadmeTranslationLanguage.brazilianPortuguese),
        ("it-IT", ReadmeTranslationLanguage.italian),
        ("ru-RU", ReadmeTranslationLanguage.russian),
        ("nl-NL", ReadmeTranslationLanguage.dutch),
        ("pl-PL", ReadmeTranslationLanguage.polish),
        ("uk-UA", ReadmeTranslationLanguage.ukrainian),
        ("tr-TR", ReadmeTranslationLanguage.turkish),
        ("vi-VN", ReadmeTranslationLanguage.vietnamese),
        ("id-ID", ReadmeTranslationLanguage.indonesian),
        ("ar-SA", ReadmeTranslationLanguage.arabic),
    ])
    func supportedIdentifiers(
        identifier: String,
        expected: ReadmeTranslationLanguage
    ) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == expected
        )
    }

    // MARK: - Fallback：英文

    /// 空 identifier / 完全无法解析的串：Locale.Language 返回 nil languageCode，
    /// 走 default 分支 → `.english`。
    @Test("不支持 / 无效 identifier → English（fallback）", arguments: [
        "",
        "xx",            // 不存在的语言码
        "garbage-input", // 完全不合法
        "th-TH"
    ])
    func invalidIdentifierFallsBackToEnglish(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .english
        )
    }

    @Test("auto 解析为当前 App locale；具体语言保持锁定")
    func autoResolvesToLocaleAndConcreteStaysPinned() {
        #expect(ReadmeTranslationLanguage.auto.resolved(appLocaleOverride: "zh-Hans") == .simplifiedChinese)
        #expect(ReadmeTranslationLanguage.auto.resolved(appLocaleOverride: "en") == .english)
        #expect(ReadmeTranslationLanguage.auto.resolved(appLocaleOverride: "ja") == .japanese)
        #expect(ReadmeTranslationLanguage.japanese.resolved(appLocaleOverride: "zh-Hans") == .japanese)
    }
}
