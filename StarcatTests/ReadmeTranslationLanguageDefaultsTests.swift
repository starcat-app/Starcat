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
//  - 日韩：`ja*` / `ko*` → `.japanese` / `.korean`；
//  - 其他：英文、法文、德文、空串等 → `.english`（fallback）。
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

    // MARK: - Fallback：英文

    /// 非中日韩 locale 一律落到英文：这是 HOM-198 的核心改动——原默认值 `.simplifiedChinese`
    /// 对非中文用户硬塞中文，issue 的核心抱怨即此。
    @Test("非中日韩 locale → English（fallback）", arguments: [
        "en",
        "en-US",
        "en-GB",
        "fr",
        "fr-FR",
        "de",
        "de-DE",
        "es",
        "es-ES",
        "pt-BR",
        "ru",
        "it",
        "ar",
        "vi",
        "th"
    ])
    func nonCJKFallsBackToEnglish(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .english
        )
    }

    /// 空 identifier / 完全无法解析的串：Locale.Language 返回 nil languageCode，
    /// 走 default 分支 → `.english`。
    @Test("空 / 无效 identifier → English（fallback）", arguments: [
        "",
        "xx",            // 不存在的语言码
        "garbage-input"  // 完全不合法
    ])
    func invalidIdentifierFallsBackToEnglish(identifier: String) {
        #expect(
            ReadmeTranslationLanguage.defaultLanguage(forLocaleIdentifier: identifier) == .english
        )
    }
}
