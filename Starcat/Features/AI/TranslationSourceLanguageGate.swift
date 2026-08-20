//
//  TranslationSourceLanguageGate.swift
//  Starcat
//
//  翻译前按段判断「原文是不是已经是目标语言」。
//
//  为什么不用 App 界面语言：界面英文不代表 Issue / README 是英文。
//  为什么不让模型主判：同语种仍会打满 token，而且经常被「润色」成另一句。
//  本机 NLLanguageRecognizer 只在高置信且精确映射到目标语言时跳过；
//  笼统 Chinese、短句、混杂段一律送 AI，Prompt 再兜底原样复制。
//

import Foundation
import NaturalLanguage

enum TranslationSourceLanguageGate {

    /// 低于此值不跳过：短句和中英混排时识别器经常「看起来像」目标语言。
    static let minimumConfidence: Double = 0.8

    /// 这段是否已经是目标语言、不必送给模型。
    static func shouldSkipTranslation(
        text: String,
        target: ReadmeTranslationLanguage
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage,
              let mapped = mappedLanguage(from: dominant),
              mapped == target
        else { return false }

        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        return confidence >= minimumConfidence
    }

    static func segmentsNeedingTranslation(
        _ segments: [ReadmeSourceSegment],
        target: ReadmeTranslationLanguage
    ) -> [ReadmeSourceSegment] {
        segments.filter { !shouldSkipTranslation(text: $0.text, target: target) }
    }

    /// 只接受能一一对上 `ReadmeTranslationLanguage` 的 NLLanguage。
    /// `NLLanguage` 的笼统 `zh`（不分简繁）对不上 zh-Hans / zh-Hant，返回 nil 以免误杀简繁转换。
    static func mappedLanguage(from language: NLLanguage) -> ReadmeTranslationLanguage? {
        switch language {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .german: return .german
        case .french: return .french
        case .spanish: return .spanish
        case .portuguese: return .brazilianPortuguese
        case .italian: return .italian
        case .russian: return .russian
        case .dutch: return .dutch
        case .polish: return .polish
        case .ukrainian: return .ukrainian
        case .turkish: return .turkish
        case .vietnamese: return .vietnamese
        case .indonesian: return .indonesian
        case .arabic: return .arabic
        default: return nil
        }
    }
}
