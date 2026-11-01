//
//  TranslationSourceLanguageGate.swift
//  Starcat
//
//  翻译前按段判断「原文是不是已经是目标语言」，并投票识别整篇主语言。
//
//  为什么不用 App 界面语言：界面英文不代表 Issue / README 是英文。
//  为什么不让模型主判：同语种仍会打满 token，而且经常被「润色」成另一句。
//  本机 NLLanguageRecognizer 只在高置信且精确映射到目标语言时跳过；
//  笼统 Chinese、短句、混杂段一律送 AI，Prompt 再兜底原样复制。
//
//  文档级主语言不能对拼接样本做一次识别：专有名词 / 缩写密集的技术 README
//  （KAG、OpenSPG、RAG…）整体置信度只有 ~0.5，而正文段落单独识别普遍 0.99+。
//  因此按段投票：每段 top-1 置信度累计到映射后的语言取最高，头部噪音段
//  （三语导航行会被判成 ja 0.98）压不过正文的多次一致投票。
//

import Foundation
import NaturalLanguage

enum TranslationSourceLanguageGate {

    /// 低于此值不跳过：短句和中英混排时识别器经常「看起来像」目标语言。
    static let minimumConfidence: Double = 0.8

    /// 文档级投票赢家的最低累计票数：一段足够长的正文（≥0.9）即可通过。
    static let minimumDocumentVotes: Double = 0.8

    /// 参与文档级投票的段数上限：头部噪音之后几段正文足以稳定投票，
    /// 封顶同时避免超长 README 的识别成本无界增长。
    static let documentVoteSegmentLimit = 20

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

    /// 逐段投票识别整篇 README 的主语言；系统翻译源语言与「同语种整篇跳过」共用。
    ///
    /// TranslationSession 准备语言包时不能依赖 `source: nil` 猜测语言，必须给明确
    /// 源语言；返回 nil（样本过短、没有段落映射到 18 种支持语言、最高票未达门槛
    /// 或并列）时由调用方展示可恢复错误，绝不把不确定的语言硬编码成英语——猜错
    /// 会下载错误语言包并把失败伪装成正文翻译失败。
    static func detectDocumentLanguage(
        in segments: [ReadmeSourceSegment]
    ) -> ReadmeTranslationLanguage? {
        var votes: [ReadmeTranslationLanguage: Double] = [:]
        for segment in segments.prefix(documentVoteSegmentLimit) {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 12 else { continue }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(trimmed)
            guard let dominant = recognizer.dominantLanguage,
                  let mapped = mappedLanguage(from: dominant) else { continue }
            votes[mapped, default: 0] += recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        }
        guard let top = votes.values.max(), top >= minimumDocumentVotes else { return nil }
        // 最高票并列 = 没有可靠主语言（真双语混排），不猜。
        let winners = votes.filter { $0.value == top }
        guard winners.count == 1, let winner = winners.first else { return nil }
        return winner.key
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
        default: return nil
        }
    }
}
