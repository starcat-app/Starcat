//
//  KnowledgeRAGPromptBuilder.swift
//  Starcat
//
//  把 repo-aware 检索结果、远程临时上下文和附件文本打包为 Generator prompt。
//
//  证据编号在本地生成并与 RAGCitation 一一对应。模型只能引用提供的编号；这让 UI 和
//  历史记录不需要从模型自由文本中猜 repo/chunk 身份。
//

import Foundation

struct RAGPromptBuildResult: Equatable, Sendable {
    var systemPrompt: String
    var userPrompt: String
    var citationsByMarker: [String: RAGCitation]
    /// 已被统一预算后的历史；Service 必须发送这份而不是调用方传入的原始 history。
    var history: [AIChatMessage] = []
    var contextUsage: RAGContextUsage = .empty
}

struct KnowledgeRAGPromptBuilder: Sendable {
    var maxEvidenceTokens = 12_000
    var maxRemoteTokens = 3_000
    var maxAttachmentTokens = 4_000
    /// 可配置模板；默认走 `RAGDefaultPrompts.generator`。
    var promptConfiguration: AIPromptConfiguration = RAGDefaultPrompts.generator
    /// Display Language 派发到 LLM 的英文语言名，如 `Simplified Chinese`。
    var outputLanguage: String = "English"

    func build(
        question: String,
        plan: RAGQueryPlan,
        retrieval: RAGRetrievalResult,
        remoteBlocks: [RAGRemoteContextBlock],
        attachmentContexts: [RAGAttachmentContext],
        history: [AIChatMessage] = [],
        contextWindowTokens: Int = 32 * 1_024,
        maximumOutputTokens: Int = 8 * 1_024
    ) -> RAGPromptBuildResult {
        var budget = RAGContextBudget(
            contextWindowTokens: contextWindowTokens,
            requestedOutputTokens: maximumOutputTokens
        )
        let renderedSystem = promptConfiguration.renderedSystemPrompt(placeholders: [
            "outputLanguage": outputLanguage
        ])
        let systemPrompt = budget.consume(renderedSystem, kind: .system)
        let boundedHistory = boundedHistory(history, budget: &budget)
        var citations: [String: RAGCitation] = [:]
        var evidenceSections: [String] = []
        var usedTokens = 0
        var nextCitation = 1

        let structuredRowLimit = min(max(plan.candidateLimit ?? 50, 1), 50)
        let bundles = retrieval.bundles.isEmpty
            ? retrieval.candidates.prefix(structuredRowLimit).map { structuredBundle($0) }
            : retrieval.bundles
        for bundle in bundles {
            var lines = [metadataLine(bundle.candidate)]
            for parent in bundle.sectionParents {
                let tokens = TokenEstimator.estimate(text: parent.content)
                guard usedTokens + tokens <= maxEvidenceTokens else { break }
                let parentHits = bundle.matchedChildren.filter { parent.childChunkIDs.contains($0.chunk.id ?? -1) }
                let hit = parentHits.first ?? bundle.matchedChildren.first
                let marker = "S\(nextCitation)"
                if let hit {
                    citations[marker] = RAGCitation(
                        id: UUID(),
                        marker: marker,
                        chunkID: hit.chunk.id,
                        repoID: bundle.candidate.repo.id,
                        repoFullName: bundle.candidate.repo.fullName,
                        source: hit.chunk.source,
                        sectionTitle: parent.title,
                        score: hit.score,
                        hitKind: hit.kind,
                        vectorSimilarity: hit.vectorSimilarity,
                        scoreBreakdown: hit.scoreBreakdown,
                        sourceURL: URL(string: bundle.candidate.repo.htmlUrl)
                    )
                    nextCitation += 1
                    lines.append("[\(marker)] \(parent.title)\n\(parent.content)")
                    usedTokens += tokens
                }
            }
            // structured_only 没有 child hit，也必须把数据库事实送给模型；这类回答的 repo
            // 链接由 UI 根据 candidate 提供，不伪造 chunk citation。
            evidenceSections.append(lines.joined(separator: "\n\n"))
        }

        var remoteTokens = 0
        let rawRemoteText = remoteBlocks.enumerated().compactMap { index, block -> String? in
            let remaining = maxRemoteTokens - remoteTokens
            guard remaining > 0 else { return nil }
            let status = block.errorMessage.map { "获取失败：\($0)" } ?? block.content
            let value = "[R\(index + 1)] \(block.title)\n\(status)"
            let clipped = RAGContextBudget.clip(value, toTokenBudget: remaining)
            remoteTokens += TokenEstimator.estimate(text: clipped)
            return clipped
        }.joined(separator: "\n\n")

        var attachmentTokens = 0
        let rawAttachmentText = attachmentContexts.compactMap { attachment -> String? in
            let remaining = maxAttachmentTokens - attachmentTokens
            guard remaining > 0 else { return nil }
            let value = "[A:\(attachment.filename)]\n\(attachment.content)"
            let clipped = RAGContextBudget.clip(value, toTokenBudget: remaining)
            attachmentTokens += TokenEstimator.estimate(text: clipped)
            return clipped
        }.joined(separator: "\n\n")

        let degradation = remoteBlocks.compactMap(\.errorMessage).isEmpty
            ? ""
            : "Remote context partially failed to fetch. The answer must state the degraded scope and must not present missing information as fact."
        let planBlock = """
            mode=\(plan.mode.rawValue)
            semantic=\(plan.semanticQuery)
            structured_candidate_count=\(retrieval.candidates.count)
            structured_rows_in_prompt=\(retrieval.bundles.isEmpty ? bundles.count : 0)
            structured_rows_truncated=\(retrieval.bundles.isEmpty && retrieval.candidates.count > bundles.count)
            \(degradation)
            """.trimmingCharacters(in: .whitespacesAndNewlines)

        // 先按分段裁剪并计量，再填进可编辑模板；删掉模板占位符 = 不注入对应段。
        let questionSection = budget.consume("""
            User question:
            \(question)

            Query plan:
            \(planBlock)
            """, kind: .question, preferredLimit: 4_096)
        let evidenceBody = evidenceSections.joined(separator: "\n\n---\n\n")
        let evidenceSection = evidenceBody.isEmpty
            ? ""
            : budget.consume(
                "\n\nLocal knowledge-base evidence:\n\(evidenceBody)",
                kind: .evidence,
                preferredLimit: maxEvidenceTokens
            )
        citations = citations.filter { evidenceSection.contains("[\($0.key)]") }

        let remoteSection = rawRemoteText.isEmpty
            ? ""
            : budget.consume(
                "\n\nGitHub temporary remote context:\n\(rawRemoteText)",
                kind: .remoteContext,
                preferredLimit: maxRemoteTokens
            )
        let attachmentSection = rawAttachmentText.isEmpty
            ? ""
            : budget.consume(
                "\n\nUser attachments for this turn:\n\(rawAttachmentText)",
                kind: .attachments,
                preferredLimit: maxAttachmentTokens
            )

        let userPrompt = promptConfiguration.renderedUserPrompt(placeholders: [
            "outputLanguage": outputLanguage,
            "questionSection": questionSection,
            "evidenceSection": evidenceSection,
            "remoteSection": remoteSection,
            "attachmentSection": attachmentSection
        ])

        return RAGPromptBuildResult(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            citationsByMarker: citations,
            history: boundedHistory,
            contextUsage: budget.usage(promptPreview: promptPreview(
                systemPrompt: systemPrompt,
                history: boundedHistory,
                userPrompt: userPrompt
            ))
        )
    }

    /// 输入框还没有检索结果时的轻量预估。正式请求完成构建后会被精确快照替代；此处不读取
    /// 附件文件内容，避免用户仅输入文字就触发磁盘 I/O 或把大文件预先放进内存。
    func preview(
        question: String,
        history: [AIChatMessage],
        attachmentNames: [String],
        contextWindowTokens: Int,
        maximumOutputTokens: Int
    ) -> RAGContextUsage {
        var budget = RAGContextBudget(
            contextWindowTokens: contextWindowTokens,
            requestedOutputTokens: maximumOutputTokens
        )
        let renderedSystem = promptConfiguration.renderedSystemPrompt(placeholders: [
            "outputLanguage": outputLanguage
        ])
        let systemPrompt = budget.consume(renderedSystem, kind: .system)
        let boundedHistory = boundedHistory(history, budget: &budget)
        let questionSection = budget.consume("""
            User question:
            \(question)

            Query plan:
            (pending)
            """, kind: .question, preferredLimit: 4_096)
        let attachmentSection = attachmentNames.isEmpty
            ? ""
            : budget.consume(
                "\n\nUser attachments for this turn:\n\(attachmentNames.joined(separator: "\n"))",
                kind: .attachments,
                preferredLimit: 512
            )
        let userPrompt = promptConfiguration.renderedUserPrompt(placeholders: [
            "outputLanguage": outputLanguage,
            "questionSection": questionSection,
            "evidenceSection": "",
            "remoteSection": "",
            "attachmentSection": attachmentSection
        ])
        return budget.usage(promptPreview: promptPreview(
            systemPrompt: systemPrompt,
            history: boundedHistory,
            userPrompt: userPrompt
        ))
    }

    func citationsUsed(in answer: String, prompt: RAGPromptBuildResult) -> [RAGCitation] {
        let visibleAnswer = citationVisibleText(in: answer)
        let referencedMarkers = Set(Self.citationMarkerRegex.matches(
            in: visibleAnswer,
            range: NSRange(visibleAnswer.startIndex..<visibleAnswer.endIndex, in: visibleAnswer)
        ).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  !isEscapedMarker(match.range, in: visibleAnswer),
                  !isMarkdownLinkLabel(match.range, in: visibleAnswer),
                  let markerRange = Range(match.range(at: 1), in: visibleAnswer)
            else { return nil }
            let marker = String(visibleAnswer[markerRange])
            return prompt.citationsByMarker[marker] == nil ? nil : marker
        })
        return prompt.citationsByMarker.keys.sorted { lhs, rhs in
            markerNumber(lhs) < markerNumber(rhs)
        }.compactMap { marker in
            referencedMarkers.contains(marker) ? prompt.citationsByMarker[marker] : nil
        }
    }

    /// 历史按“离当前轮最近优先”放入统一预算。摘要与普通消息分段计数，供 Composer
    /// 明确展示压缩效果；没有空间的旧消息被稳定丢弃，而不是把当前问题或输出空间挤掉。
    private func boundedHistory(
        _ history: [AIChatMessage],
        budget: inout RAGContextBudget
    ) -> [AIChatMessage] {
        let historyLimit = min(budget.remainingInputTokens, max(budget.inputLimitTokens * 35 / 100, 512))
        var remaining = historyLimit
        var result: [AIChatMessage] = []
        for message in history.reversed() {
            guard remaining > 0 else { break }
            let isSummary = message.content.hasPrefix("以下是较早对话的")
            let kind: RAGContextUsageSegmentKind = isSummary ? .historySummary : .recentMessages
            let clipped = budget.consume(message.content, kind: kind, preferredLimit: remaining)
            let consumed = TokenEstimator.estimate(text: clipped)
            remaining -= consumed
            guard !clipped.isEmpty else { continue }
            result.insert(AIChatMessage(role: message.role, content: clipped), at: 0)
        }
        return result
    }

    private func promptPreview(
        systemPrompt: String,
        history: [AIChatMessage],
        userPrompt: String
    ) -> String {
        let historyText = history.map { "\($0.role.rawValue):\n\($0.content)" }.joined(separator: "\n\n")
        return """
            system:
            \(systemPrompt)

            \(historyText.isEmpty ? "" : "history:\n\(historyText)\n")
            user:
            \(userPrompt)
            """
    }

    private func structuredBundle(_ candidate: RAGRepoCandidate) -> RepoContextBundle {
        RepoContextBundle(candidate: candidate, score: 0, matchedChildren: [], sectionParents: [])
    }

    private func metadataLine(_ candidate: RAGRepoCandidate) -> String {
        let repo = candidate.repo
        return """
            Repo: \(repo.fullName)
            Description: \(repo.description ?? "")
            Language: \(repo.language ?? "Unknown")
            Stars: \(repo.starsCount); Forks: \(repo.forksCount); Status: \(candidate.status.rawValue)
            Tags: \(candidate.tagNames.joined(separator: ", "))
            GitHub: \(repo.htmlUrl)
            """
    }

    private func markerNumber(_ marker: String) -> Int {
        Int(marker.dropFirst()) ?? .max
    }

    /// 回答里的代码示例和转义文本可能原样包含 `[S1]`，但它们不是模型对证据的引用。
    /// 在做 citation 语法校验前先剔除 fenced / inline code，避免历史和 Inspector 展示伪证据。
    private func citationVisibleText(in answer: String) -> String {
        var visibleLines: [String] = []
        var activeFence: (character: Character, length: Int)?
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let currentFence = activeFence {
                if let closingFence = fence(in: trimmed),
                   closingFence.character == currentFence.character,
                   closingFence.length >= currentFence.length {
                    activeFence = nil
                }
                continue
            }
            if let openingFence = fence(in: trimmed) {
                activeFence = openingFence
                continue
            }
            visibleLines.append(removingInlineCode(from: String(line)))
        }
        return visibleLines.joined(separator: "\n")
    }

    private func fence(in line: String) -> (character: Character, length: Int)? {
        guard let character = line.first, character == "`" || character == "~" else { return nil }
        let length = line.prefix { $0 == character }.count
        return length >= 3 ? (character, length) : nil
    }

    private func removingInlineCode(from line: String) -> String {
        var result = ""
        var cursor = line.startIndex
        while let opening = line[cursor...].firstIndex(of: "`") {
            result += line[cursor..<opening]
            let delimiterEnd = line[opening...].firstIndex { $0 != "`" } ?? line.endIndex
            let delimiter = String(line[opening..<delimiterEnd])
            guard let closing = line.range(of: delimiter, range: delimiterEnd..<line.endIndex) else {
                // 未闭合的 backtick 只是普通文本；保留后续内容，避免无端丢失真实引用。
                result += line[opening...]
                return result
            }
            cursor = closing.upperBound
        }
        result += line[cursor...]
        return result
    }

    private func isEscapedMarker(_ range: NSRange, in text: String) -> Bool {
        let units = Array(text.utf16)
        var index = range.location - 1
        var slashCount = 0
        while index >= 0, units[index] == 92 {
            slashCount += 1
            index -= 1
        }
        return !slashCount.isMultiple(of: 2)
    }

    private func isMarkdownLinkLabel(_ range: NSRange, in text: String) -> Bool {
        let units = Array(text.utf16)
        let nextIndex = NSMaxRange(range)
        return nextIndex < units.count && units[nextIndex] == 40
    }

    private static let citationMarkerRegex = try! NSRegularExpression(pattern: #"\[(S\d+)\]"#)
}
