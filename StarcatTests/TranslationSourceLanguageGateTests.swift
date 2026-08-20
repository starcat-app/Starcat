//
//  TranslationSourceLanguageGateTests.swift
//  StarcatTests
//
//  按段跳过：高置信同语种不送 AI；简繁、短句、对不上的目标语言都要放行。
//

import NaturalLanguage
import Testing
@testable import Starcat

@Suite("TranslationSourceLanguageGate")
struct TranslationSourceLanguageGateTests {

    private let simplified = "这是一段足够长的简体中文说明，用来确认语言识别器能稳定判成简体中文而不是英文。"
    private let traditional = "這是一段足夠長的繁體中文說明，用來確認語言識別器能把它和簡體中文分開處理。"
    private let english = "This paragraph is long enough for the recognizer to treat it as English instead of Chinese."

    @Test("简体中文段 + 目标简体 → 跳过")
    func skipsSimplifiedWhenTargetIsSimplified() {
        #expect(
            TranslationSourceLanguageGate.shouldSkipTranslation(
                text: simplified,
                target: .simplifiedChinese
            )
        )
    }

    @Test("英文段 + 目标简体 → 不跳过")
    func keepsEnglishWhenTargetIsSimplified() {
        #expect(
            !TranslationSourceLanguageGate.shouldSkipTranslation(
                text: english,
                target: .simplifiedChinese
            )
        )
    }

    @Test("简体中文段 + 目标繁体 → 不跳过，避免误杀简繁转换")
    func doesNotSkipSimplifiedWhenTargetIsTraditional() {
        #expect(
            !TranslationSourceLanguageGate.shouldSkipTranslation(
                text: simplified,
                target: .traditionalChinese
            )
        )
    }

    @Test("繁体中文段 + 目标繁体 → 跳过")
    func skipsTraditionalWhenTargetIsTraditional() {
        #expect(
            TranslationSourceLanguageGate.shouldSkipTranslation(
                text: traditional,
                target: .traditionalChinese
            )
        )
    }

    @Test("短句即使像目标语言也不跳过")
    func shortTextDoesNotSkip() {
        #expect(
            !TranslationSourceLanguageGate.shouldSkipTranslation(
                text: "你好",
                target: .simplifiedChinese
            )
        )
        #expect(
            !TranslationSourceLanguageGate.shouldSkipTranslation(
                text: "OK",
                target: .english
            )
        )
    }

    @Test("笼统 zh 不能映射到简繁，避免误杀简繁转换")
    func genericChineseDoesNotMap() {
        #expect(TranslationSourceLanguageGate.mappedLanguage(from: NLLanguage(rawValue: "zh")) == nil)
        #expect(TranslationSourceLanguageGate.mappedLanguage(from: .simplifiedChinese) == .simplifiedChinese)
        #expect(TranslationSourceLanguageGate.mappedLanguage(from: .traditionalChinese) == .traditionalChinese)
        #expect(TranslationSourceLanguageGate.mappedLanguage(from: .english) == .english)
    }

    @Test("混合段落只送需要对不上目标语言的那些")
    func filtersMixedSegmentsPerItem() {
        let segments = [
            ReadmeSourceSegment(id: "zh", text: simplified),
            ReadmeSourceSegment(id: "en", text: english)
        ]
        let remaining = TranslationSourceLanguageGate.segmentsNeedingTranslation(
            segments,
            target: .simplifiedChinese
        )
        #expect(remaining.map(\.id) == ["en"])
    }
}
