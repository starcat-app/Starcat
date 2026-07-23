//
//  ReadmeTranslation.swift
//  Starcat
//
//  README 翻译数据模型。
//
//  模块职责：
//  - 表达 WebView 从已渲染 README 中提取的分段块与全文文本节点；
//  - 表达 AI 返回的“源文本指纹 → 译文”缓存；
//  - 表达 SwiftUI 传给 WKWebView 的增量渲染状态。
//
//  关键约束：
//  - 缓存以源段落 SHA256 为键，不依赖 DOM 顺序。README 只改一段时，其余段落仍可复用；
//  - DOM id 只属于当前页面，用于把译文插回正确位置，不写入长期缓存；
//  - `formatVersion` 用于一次性淘汰旧“整页 translated_html”缓存，避免长期维护两套格式。
//

import CryptoKit
import Foundation

/// README 翻译方式。
///
/// 两种方式都只把纯文本分批发送给 AI；区别仅在 DOM 呈现：
/// - `segmented`：保留原文，并在段落下方追加译文；
/// - `full`：把可见文本节点替换为译文，原 HTML 结构与非文本属性保持不变。
enum ReadmeTranslationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case segmented
    case full

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .segmented: return "readme.translate.mode.segmented"
        case .full:      return "readme.translate.mode.full"
        }
    }

    /// 分段模式沿用历史 `<language>.json`，让已生成缓存继续命中；
    /// 全文模式增加后缀，避免不同粒度的源文本指纹互相覆盖。
    var cacheFileSuffix: String {
        switch self {
        case .segmented: return ""
        case .full:      return ".full"
        }
    }

    var usagePhase: String {
        switch self {
        case .segmented: return "segmented_translation"
        case .full:      return "full_translation"
        }
    }
}

/// WebView 从当前 README DOM 中提取的一段可见自然语言。
struct ReadmeSourceSegment: Codable, Equatable, Identifiable, Sendable {
    /// 当前文档内稳定的 DOM id。文档重载后会按相同 DOM 顺序重新生成。
    let id: String
    /// 发给 AI 的纯文本；代码、命令等字面量仍保留在文本中并由 Prompt 约束不得翻译。
    let text: String
    /// 源文本指纹。缓存复用只比较该值，不依赖段落位置。
    let sourceHash: String

    init(id: String, text: String) {
        self.id = id
        self.text = text
        self.sourceHash = Self.hash(text)
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 同一份 README 为两种翻译方式准备的纯文本输入。
///
/// 分段模式按块提取，适合原文/译文对照；全文模式按 Text node 提取，替换时不会破坏
/// inline link、图片、代码块与 HTML attribute。两组输入都只在用户点击翻译后发给 AI。
struct ReadmeTranslationSourceSnapshot: Equatable, Sendable {
    var segmented: [ReadmeSourceSegment]
    var full: [ReadmeSourceSegment]

    static let empty = ReadmeTranslationSourceSnapshot(segmented: [], full: [])

    func segments(for mode: ReadmeTranslationMode) -> [ReadmeSourceSegment] {
        switch mode {
        case .segmented: return segmented
        case .full:      return full
        }
    }
}

/// 一段可长期缓存的译文。
struct ReadmeTranslatedSegment: Codable, Equatable, Sendable {
    /// 对应 `ReadmeSourceSegment.sourceHash`。
    let sourceHash: String
    /// 纯文本译文。原文的 HTML 结构继续由当前 WebView 持有，不让 AI 重写标签。
    let translatedText: String

    enum CodingKeys: String, CodingKey {
        case sourceHash = "source_hash"
        case translatedText = "translated_text"
    }
}

/// 当前 WebView 一次增量注入所需的最小数据。
struct ReadmeRenderedTranslation: Equatable, Sendable {
    let id: String
    let translatedText: String
}

/// SwiftUI → WKWebView 的翻译展示状态。
///
/// `revision` 只用于让 Representable 判断内容是否变化；它不落盘，也不参与业务缓存。
struct ReadmeTranslationRenderState: Equatable, Sendable {
    var isVisible: Bool
    var mode: ReadmeTranslationMode
    var translations: [ReadmeRenderedTranslation]
    var revision: Int

    static let hidden = ReadmeTranslationRenderState(
        isVisible: false,
        mode: .segmented,
        translations: [],
        revision: 0
    )
}

/// README 分段翻译缓存。
struct ReadmeTranslation: Codable, Equatable, Sendable {
    /// 当前缓存格式。v1 是整份 HTML；v2 起只缓存分段译文。
    static let currentFormatVersion = 2

    var formatVersion: Int = Self.currentFormatVersion
    var repoId: Int64?
    var targetLanguage: String
    var model: String
    /// 当前完整源 HTML 的指纹，用于 UI 判断 README 是否整体更新。
    var sourceHash: String
    /// 可跨 README 小改动复用的分段译文。
    var segments: [ReadmeTranslatedSegment]
    /// 当前源 README 的全部可翻译段落是否都已完成。取消时会留下 false 的部分缓存。
    var isComplete: Bool
    /// 全部译文 UTF-8 字节数，供缓存容量统计。
    var size: Int
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case repoId = "repo_id"
        case targetLanguage = "target_language"
        case model
        case sourceHash = "source_hash"
        case segments
        case isComplete = "is_complete"
        case size
        case createdAt = "created_at"
    }
}
