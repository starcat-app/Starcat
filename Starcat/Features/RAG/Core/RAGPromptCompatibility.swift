//
//  RAGPromptCompatibility.swift
//  Starcat
//
//  检查自定义 RAG Prompt 是否仍包含当前版本默认模板使用的运行时占位符。
//  用户自定义内容始终保留；诊断只暴露能力差异，不把“不同于默认值”误判成错误。
//

import Foundation

/// 当前 Prompt 与本版本默认 Prompt 的兼容状态。
enum RAGPromptCompatibilityState: Equatable, Sendable {
    /// 当前内容与默认值完全一致。
    case defaultValue
    /// 内容已自定义，但当前版本使用的占位符仍然完整。
    case customized
    /// 至少缺少一个当前版本使用的占位符，部分运行时上下文不会进入模型。
    case limited
}

/// 单套 RAG Prompt 的兼容性诊断结果。
struct RAGPromptCompatibility: Equatable, Sendable {
    var state: RAGPromptCompatibilityState
    var missingSystemPlaceholders: [String]
    var missingUserPlaceholders: [String]

    var missingPlaceholders: [String] {
        missingSystemPlaceholders + missingUserPlaceholders
    }
}

/// RAG Prompt 兼容性诊断与非破坏性修复入口。
enum RAGPromptCompatibilityAnalyzer {
    /// 对比当前配置和当前版本默认配置。
    ///
    /// 不能只判断两段字符串是否相等：自定义 Prompt 是合法状态，只有缺少默认模板
    /// 正在使用的占位符时，才说明新版上下文能力被关闭或遗漏。
    static func analyze(
        current: AIPromptConfiguration,
        reference: AIPromptConfiguration
    ) -> RAGPromptCompatibility {
        if current == reference {
            return RAGPromptCompatibility(
                state: .defaultValue,
                missingSystemPlaceholders: [],
                missingUserPlaceholders: []
            )
        }

        let missingSystem = missingPlaceholders(
            current: current.systemPrompt,
            reference: reference.systemPrompt
        )
        let missingUser = missingPlaceholders(
            current: current.userPromptTemplate,
            reference: reference.userPromptTemplate
        )
        return RAGPromptCompatibility(
            state: missingSystem.isEmpty && missingUser.isEmpty ? .customized : .limited,
            missingSystemPlaceholders: missingSystem,
            missingUserPlaceholders: missingUser
        )
    }

    /// 在不覆盖用户已有内容的前提下补齐缺失占位符。
    ///
    /// 默认模板中的占位符可能嵌在描述语句里，直接复制整段默认文本会破坏用户结构；
    /// 因此统一追加一个紧凑的 Starcat 运行时变量区。再次执行时不会重复追加。
    static func repairing(
        current: AIPromptConfiguration,
        reference: AIPromptConfiguration
    ) -> AIPromptConfiguration {
        let diagnostic = analyze(current: current, reference: reference)
        var repaired = current
        repaired.systemPrompt = appending(
            diagnostic.missingSystemPlaceholders,
            to: current.systemPrompt,
            heading: "Starcat runtime variables:"
        )
        repaired.userPromptTemplate = appending(
            diagnostic.missingUserPlaceholders,
            to: current.userPromptTemplate,
            heading: "Starcat runtime context:"
        )
        return repaired
    }

    /// 按出现顺序提取形如 `{questionSection}` 的运行时占位符并去重。
    static func placeholders(in text: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let opening = text.range(
                  of: "{",
                  range: searchStart..<text.endIndex
              ),
              let closing = text.range(
                  of: "}",
                  range: opening.upperBound..<text.endIndex
              ) {
            let tokenRange = opening.lowerBound..<closing.upperBound
            let token = String(text[tokenRange])
            let name = text[opening.upperBound..<closing.lowerBound]
            if isPlaceholderName(name), seen.insert(token).inserted {
                result.append(token)
            }
            searchStart = closing.upperBound
        }
        return result
    }

    private static func missingPlaceholders(
        current: String,
        reference: String
    ) -> [String] {
        let currentTokens = Set(placeholders(in: current))
        return placeholders(in: reference).filter { !currentTokens.contains($0) }
    }

    private static func isPlaceholderName(_ value: Substring) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "."
        }
    }

    private static func appending(
        _ placeholders: [String],
        to text: String,
        heading: String
    ) -> String {
        guard !placeholders.isEmpty else { return text }
        let suffix = ([heading] + placeholders.map { "\($0): \($0)" })
            .joined(separator: "\n")
        guard !text.isEmpty else { return suffix }
        let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
        return text + separator + suffix
    }
}
