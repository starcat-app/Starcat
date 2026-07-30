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
    /// 存在缺失或重复占位符，运行时上下文可能缺失或被重复发送。
    case limited
}

/// 单套 RAG Prompt 的兼容性诊断结果。
struct RAGPromptCompatibility: Equatable, Sendable {
    var state: RAGPromptCompatibilityState
    var missingSystemPlaceholders: [String]
    var missingUserPlaceholders: [String]
    var duplicatedSystemPlaceholders: [String]
    var duplicatedUserPlaceholders: [String]

    var missingPlaceholders: [String] {
        missingSystemPlaceholders + missingUserPlaceholders
    }

    var duplicatedPlaceholders: [String] {
        duplicatedSystemPlaceholders + duplicatedUserPlaceholders
    }
}

/// RAG Prompt 兼容性诊断入口。
///
/// 这里只报告差异，不自动改写用户 Prompt；默认模板由设置页只读展示，用户自行对比修改。
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
                missingUserPlaceholders: [],
                duplicatedSystemPlaceholders: [],
                duplicatedUserPlaceholders: []
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
        let duplicatedSystem = duplicatedPlaceholders(in: current.systemPrompt)
        let duplicatedUser = duplicatedPlaceholders(in: current.userPromptTemplate)
        let hasCompatibilityIssue = !missingSystem.isEmpty
            || !missingUser.isEmpty
            || !duplicatedSystem.isEmpty
            || !duplicatedUser.isEmpty
        return RAGPromptCompatibility(
            state: hasCompatibilityIssue ? .limited : .customized,
            missingSystemPlaceholders: missingSystem,
            missingUserPlaceholders: missingUser,
            duplicatedSystemPlaceholders: duplicatedSystem,
            duplicatedUserPlaceholders: duplicatedUser
        )
    }

    /// 按出现顺序提取形如 `{questionSection}` 的运行时占位符并去重。
    static func placeholders(in text: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for token in placeholderOccurrences(in: text) {
            if seen.insert(token).inserted {
                result.append(token)
            }
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

    /// 重复的 Section 会让同一份运行时正文进入模型多次；保持首次重复出现的顺序，
    /// 便于设置页直接展示并由用户自行修改。
    private static func duplicatedPlaceholders(in text: String) -> [String] {
        var seen: Set<String> = []
        var reported: Set<String> = []
        var result: [String] = []
        for token in placeholderOccurrences(in: text) {
            if !seen.insert(token).inserted, reported.insert(token).inserted {
                result.append(token)
            }
        }
        return result
    }

    private static func placeholderOccurrences(in text: String) -> [String] {
        var result: [String] = []
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
            if isPlaceholderName(name) {
                result.append(token)
            }
            searchStart = closing.upperBound
        }
        return result
    }

    private static func isPlaceholderName(_ value: Substring) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "."
        }
    }
}
