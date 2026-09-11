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

    /// 从 README 样本文本解析一个可传给 Apple Translation 的明确源语言。
    ///
    /// TranslationSession 在准备语言包时不能依赖 `source: nil` 猜测语言；但 README
    /// 可能包含代码、链接和多语种短句，因此只接受足够长且达到高置信度的主语言。
    /// 解析失败时由调用方展示可恢复的系统翻译错误，不把不确定的语言硬编码成英语。
    static func detectedLanguage(from text: String) -> ReadmeTranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage,
              let mapped = mappedLanguage(from: dominant)
        else { return nil }

        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        return confidence >= minimumConfidence ? mapped : nil
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
