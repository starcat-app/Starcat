//
//  RepoAIChatContext.swift
//  Starcat
//
//  仓库聊天的请求级资料投影。磁盘原始资料与完整会话历史不变；只精简本次模型输入。
//  字符估算只用于初选，最终准入必须回测本地模型的真实 chat template tokenizer。
//

import Foundation

/// 保留模板的占位符边界，避免预算不足时误删系统约束、用户问题或截断 XML 标签。
struct RepoAIChatContext: Equatable, Sendable {
    var template: String
    var placeholders: [String: String]
    /// 从完整 README 提取后再截断的上手步骤；未命中时保留原 README 和代码资料。
    let onboardingReadme: String?

    init(
        template: String, outputLanguage: String, runtimeContext: String, starcatResources: String,
        metadata: String, readme: String, codeContext: String, insightsContext: String,
        summary: String, externalContext: String, previousSessionCarryOver: String,
        onboardingReadme: String? = nil
    ) {
        self.template = template
        self.onboardingReadme = onboardingReadme
        placeholders = [
            "outputLanguage": outputLanguage, "runtimeContext": runtimeContext,
            "starcatResources": starcatResources, "metadata": metadata, "readme": readme,
            "codeContext": codeContext,
            "insightsContext": insightsContext, "summary": summary,
            "externalContext": externalContext, "previousSessionCarryOver": previousSessionCarryOver
        ]
    }

    var systemPrompt: String {
        AIPromptConfiguration.render(template: template, placeholders: placeholders)
    }

    /// README 已有专属入口时，移除 XML 中根目录 README 的各语言副本。
    /// 仅处理受管 repository XML；CDATA 中即使有伪造标签也不会被当成文件边界。
    static func removingDuplicateReadme(from xml: String, hasReadme: Bool) -> String {
        guard hasReadme, !xml.isEmpty,
              let document = try? XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]),
              let root = document.rootElement(), root.name == "repository" else { return xml }
        var changed = false
        for section in ["keyFiles", "entryPoints", "fileList"] {
            for file in root.elements(forName: section).flatMap({ $0.elements(forName: "file") }) {
                let path = file.attribute(forName: "path")?.stringValue?.lowercased() ?? ""
                let name = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
                if !name.contains("/"), name == "readme" || name.hasPrefix("readme.") || name.hasPrefix("readme-") {
                    file.detach()
                    changed = true
                }
            }
        }
        return changed ? document.xmlString : xml
    }

    /// 仅本地聊天精简资料；命中上手步骤时用 README 直接回答，找不到步骤时仍保留源码作为依据。
    func selectingLocalMaterials() -> Self {
        guard template.contains("{readme}") else { return self }
        var result = self
        if let onboardingReadme, !onboardingReadme.isEmpty {
            result.placeholders["readme"] = onboardingReadme
            result.placeholders["codeContext"] = ""
        } else if template.contains("{codeContext}"), let xml = placeholders["codeContext"] {
            result.placeholders["codeContext"] = Self.removingDuplicateReadme(
                from: xml, hasReadme: !(placeholders["readme"] ?? "").isEmpty)
        }
        return result
    }

    /// 估算预算只负责减少真实分词次数；XML 复用现有的完整节点投影器，不能直接 prefix。
    func projected(to budget: Int) -> Self {
        var result = self
        let shares: [(String, Int)] = [
            ("readme", 40), ("codeContext", 30), ("summary", 7), ("insightsContext", 7),
            ("externalContext", 7), ("previousSessionCarryOver", 7), ("starcatResources", 2)
        ]
        for (key, percent) in shares {
            let value = placeholders[key] ?? ""
            let allowed = max(0, budget * percent / 100)
            if key == "codeContext", !value.isEmpty {
                // 坏 XML 或连最小合法根节点都装不下时，本次不带代码；README 仍可用于回答。
                result.placeholders[key] = (try? RAGRepoContextXMLProjector().project(value, tokenBudget: allowed).xml) ?? ""
            } else if key == "insightsContext", value.hasPrefix("<") {
                result.placeholders[key] = (try? RAGRepositoryInsightsXMLProjector().project(value, tokenBudget: allowed).xml) ?? ""
            } else {
                result.placeholders[key] = RAGContextBudget.clip(value, toTokenBudget: allowed)
            }
        }
        return result
    }

    static func isOnboardingQuestion(_ question: String) -> Bool {
        let text = question.lowercased()
        guard !["架构", "源码", "代码结构", "architecture", "source code"].contains(where: { text.contains($0) }) else { return false }
        return ["快速使用", "上手", "入门", "怎么用", "如何使用", "安装", "quick start", "quickstart",
                "getting started", "how to use", "install", "setup"].contains { text.contains($0) }
    }

    /// 直接从匹配章节开始，长简介不会吃掉安装步骤的字符预算。保留其子标题和围栏代码。
    static func onboardingReadme(_ readme: String) -> String? {
        let terms = ["quick start", "quickstart", "getting started", "install", "requirement", "usage", "setup",
                     "快速", "安装", "依赖", "使用", "入门"]
        var selected: [String] = []
        var selectedLevel: Int?
        var fence: Character?
        for line in readme.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = fence == marker ? nil : (fence ?? marker)
            } else if fence == nil, trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" })
                let level = trimmed.count - title.count
                if (1...6).contains(level), title.first?.isWhitespace == true {
                    if let parent = selectedLevel, level <= parent { selectedLevel = nil }
                    let heading = title.lowercased()
                    if selectedLevel == nil, terms.contains(where: { heading.contains($0) }) {
                        selectedLevel = level
                    }
                }
            }
            if selectedLevel != nil { selected.append(String(line)) }
        }
        return selected.isEmpty ? nil : selected.joined(separator: "\n")
    }
}

/// 使用真实 tokenizer 校验整次请求，含系统模板、资料、历史、当前问题和模型 framing。
/// 纯请求变换允许无权重测试注入分词计数；生产计数必须由 LocalMLXRuntime 的 processor 提供。
enum RepoAIChatContextBudget {
    struct Prepared: Sendable {
        var request: AIChatRequest
        var inputTokens: Int
        var wasCompacted: Bool
    }

    static func prepare(
        _ original: AIChatRequest,
        countTokens: @Sendable (AIChatRequest) async throws -> Int
    ) async throws -> Prepared? {
        // 用量标签还供 GitHub 草稿使用。只有携带仓库聊天资料边界的请求走 32K 策略。
        guard let context = original.repositoryContext else { return nil }
        var request = original
        request.parameters = LocalAIGenerationPolicy.repositoryChatParameters(request.parameters)
        let selected = context.selectingLocalMaterials()
        let limit = LocalAIGenerationPolicy.chatInputTokens
        request.systemPrompt = selected.systemPrompt
        let initialCount = try await countTokens(request)
        if initialCount <= limit {
            return Prepared(request: request, inputTokens: initialCount, wasCompacted: request.systemPrompt != original.systemPrompt)
        }
        var allowance = limit
        // 实测/估算比例对中文、代码和路径可能差很多。逐次回测并缩小预算，有界次数后
        // 仍只允许发送已验证可容纳的输入；不以“差不多”绕过准入。
        for attempt in 0..<5 {
            try Task.checkCancellation()
            let historyBudget = original.history.isEmpty ? 0 : allowance / 3
            request.history = compactHistory(original.history, budget: historyBudget)
            request.systemPrompt = selected.projected(to: allowance - historyBudget).systemPrompt
            let count = try await countTokens(request)
            if count <= limit {
                return Prepared(request: request, inputTokens: count,
                                wasCompacted: request.systemPrompt != original.systemPrompt || request.history != original.history)
            }
            if allowance == 0 { break }
            // 最后一轮一定检查纯指令 + 当前问题，避免仍有几百个可选 token 时误报。
            allowance = attempt == 3 ? 0 : max(0, min(allowance / 2, allowance * limit / count - 256))
        }
        throw LocalAIError.repositoryChatInputTooLong
    }

    /// 按完整 user/assistant 轮次保留最近历史；较早消息仅作标明来源的摘录，绝不伪造模型摘要。
    /// 仅变换请求副本，用户的磁盘对话保持完整。工具调用链不进入仓库聊天压缩路径。
    static func compactHistory(_ history: [AIChatMessage], budget: Int) -> [AIChatMessage] {
        guard budget > 0 else { return [] }
        let total = history.reduce(0) { $0 + TokenEstimator.estimate(text: $1.content) + 8 }
        guard total > budget else { return history }
        var start = history.count
        var used = 0
        for index in history.indices.reversed() where history[index].role == .user {
            let turnTokens = history[index..<start].reduce(0) { $0 + TokenEstimator.estimate(text: $1.content) + 8 }
            guard used + turnTokens <= budget * 3 / 4 else { break }
            used += turnTokens
            start = index
        }
        let older = history[..<start].suffix(20).map {
            "\($0.role.rawValue): \(String($0.content.prefix(160)))"
        }.joined(separator: "\n")
        let recap = RAGContextBudget.clip(
            "Earlier conversation excerpts (incomplete, not a generated summary):\n" + older,
            toTokenBudget: max(0, budget - used - 8))
        return (recap.isEmpty ? [] : [AIChatMessage(role: .user, content: recap)]) + Array(history[start...])
    }
}
