//
//  LocaleStoreTests.swift
//  StarcatTests
//
//  验证 18 种目标 locale 到 AI 输出语言描述的映射。
//
//  这些测试不代表 draft 语言已经开放给用户；它们只保证底层语言语义在进入
//  released 阶段前已准备好，尤其避免 zh-Hant 被误判为简体中文。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LocaleStore")
struct LocaleStoreTests {

    @Test("18 种目标 locale 映射到明确的 AI 输出语言", arguments: [
        ("en", "English"),
        ("zh-Hans", "Simplified Chinese"),
        ("zh-Hant", "Traditional Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("pt-BR", "Brazilian Portuguese"),
        ("it", "Italian"),
        ("ru", "Russian"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("tr", "Turkish"),
        ("vi", "Vietnamese"),
        ("id", "Indonesian"),
        ("ar", "Arabic"),
    ])
    func supportedLocaleMapsToAIOutputLanguage(
        identifier: String,
        expected: String
    ) {
        let locale = Locale(identifier: identifier)

        #expect(AppLocale.aiOutputLanguageDescriptor(for: locale) == expected)
    }

    @Test("未知语言安全回退到 English")
    func unknownLocaleFallsBackToEnglish() {
        #expect(
            AppLocale.aiOutputLanguageDescriptor(for: Locale(identifier: "xx"))
                == "English"
        )
    }
}
