//
//  RepoAIChatContextTests.swift
//  StarcatTests
//
//  回放长 README + 超大 XML + 首轮短问题，以及历史压缩和真实计数回退路径。
//  测试只注入 token 计数，不依赖 GPU 或用户安装的模型。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoAIChatContext")
struct RepoAIChatContextTests {
    @Test("GitHub 评论和 Issue 草稿共用用量标签，仍走各自的本地预算",
          arguments: ["github_comment", "github_issue_compose"])
    func ignoresRequestsWithoutRepositoryMaterials(phase: String) async throws {
        let original = AIChatRequest(
            systemPrompt: "Write a GitHub draft.", userPrompt: "Follow the issue template.",
            model: "test", parameters: .summaryDefault,
            usageContext: AIUsageContext(feature: .repoChat, phase: phase)
        )
        let result: RepoAIChatContextBudget.Prepared? = try await RepoAIChatContextBudget.prepare(original) { _ in
            Issue.record("Requests outside the repository chat must not use its budget.")
            return 20_000
        }
        #expect(result == nil)
    }

    @Test("标题下的长简介不能挤掉快速上手小节里的安装和启动命令")
    func onboardingStepsSurviveTheReadmeCharacterLimit() throws {
        let readme = "# Project\n" + String(repeating: "Long introduction.\n", count: 1_500)
            + "\n## Quick start\n### Installation\n`tool install`\n### First launch\n`tool run`\n## Community\nSkip me."
        let excerpt = try #require(RepoAIChatContext.onboardingReadme(readme)).prefix(2_000)

        #expect(excerpt.contains("`tool install`"))
        #expect(excerpt.contains("`tool run`"))
        #expect(!excerpt.contains("## Community"))
    }

    @Test("README 没有上手步骤时，快速使用首问仍能参考代码上下文")
    func usesCodeWhenReadmeHasNoOnboardingSteps() async throws {
        let readme = "# Project\nAn example."
        let excerpt = RepoAIChatContext.onboardingReadme(readme)
        let context = makeContext(readme: readme,
                                  codeContext: fixtureXML(readme: "ROOT_README", source: "let launchCommand = \"tool run\""),
                                  onboardingReadme: excerpt)
        let prepared = try await RepoAIChatContextBudget.prepare(
            request(context, question: "怎么快速使用这个项目?"), countTokens: count
        )
        let result = try #require(prepared)

        #expect(excerpt == nil)
        #expect(result.request.systemPrompt.contains("tool run"))
        #expect(!result.request.systemPrompt.contains("ROOT_README"))
    }

    @Test("快速使用首问优先保留截断线之后的安装命令，不发送整仓代码或重复 README")
    func firstQuestionFitsWithLongReadmeAndCodeContext() async throws {
        let readme = "# AOCI-CODE\nRepository overview.\n## Background\n"
            + String(repeating: "Long architecture background.\n", count: 2_500)
            + "\n## Quick start\n### Requirements\nInstall Go.\n```sh\n# Run below\naoci init\n```\n## Discussions\nSkip me."
        let context = makeContext(
            readme: String(readme.prefix(12_000)),
            codeContext: fixtureXML(readme: readme, source: String(repeating: "CODE_TOKEN ", count: 32_000)),
            onboardingReadme: RepoAIChatContext.onboardingReadme(readme)
        )
        let original = request(context, question: "怎么快速使用这个项目? 给我步骤说明")
        let prepared = try await RepoAIChatContextBudget.prepare(original, countTokens: count)
        let result = try #require(prepared)
        #expect(count(original) > 28_672)
        #expect(result.inputTokens <= 28_672)
        #expect(result.wasCompacted)
        #expect(result.request.userPrompt == original.userPrompt)
        #expect(result.request.systemPrompt.contains("aoci init"))
        #expect(result.request.systemPrompt.contains("# Run below"))
        #expect(result.request.systemPrompt.contains("Install Go."))
        #expect(!result.request.systemPrompt.contains("Long architecture background"))
        #expect(!result.request.systemPrompt.contains("CODE_TOKEN"))
    }

    @Test("去重删除根 README 及其语言版本，保留子目录文档、源码和合法 XML")
    func deduplicatesRootReadmeAtNodeBoundaries() throws {
        let xml = fixtureXML(readme: "ROOT_README", source: "let code = 1")
        let context = makeContext(readme: "ROOT_README", codeContext: xml)
        let selected = context.selectingLocalMaterials()
        let projected = try #require(selected.placeholders["codeContext"])
        #expect(context.placeholders["codeContext"] == xml)
        #expect(!projected.contains("ROOT_README"))
        #expect(!projected.contains("README.zh-CN.md"))
        #expect(projected.contains("docs/README.md"))
        #expect(projected.contains("let code = 1"))
        #expect(try XMLDocument(xmlString: projected).rootElement()?.name == "repository")
        #expect(RepoAIChatContext.removingDuplicateReadme(from: xml, hasReadme: false) == xml)
        #expect(selected.systemPrompt.components(separatedBy: "ROOT_README").count == 2)
    }

    @Test("代码相关问题的超大 XML 按节点降级，资料投入服从最终分词预算")
    func projectsOverBudgetKeyFiles() async throws {
        let xml = fixtureXML(readme: "ROOT_README", source: String(repeating: "BIG_CODE ", count: 25_000))
        let prepared = try await RepoAIChatContextBudget.prepare(
            request(makeContext(readme: "ROOT_README", codeContext: xml), question: "这里的源码架构是什么？"),
            countTokens: count
        )
        let result = try #require(prepared)
        let projected = try #require(result.request.systemPrompt.components(separatedBy: "\nCODE:\n").last)
        #expect(result.inputTokens <= 28_672)
        #expect(result.wasCompacted)
        #expect(!projected.contains("BIG_CODE"))
        #expect(projected.contains("Sources/main.swift"))
        #expect(try XMLDocument(xmlString: projected).rootElement()?.name == "repository")
    }

    @Test("整条请求未超额时不按固定份额预先裁剪资料和历史")
    func keepsFittingRequestWithoutProjection() async throws {
        let history = [
            AIChatMessage(role: .user, content: String(repeating: "问", count: 5_000)),
            AIChatMessage(role: .assistant, content: String(repeating: "答", count: 5_000)),
        ]
        var original = request(
            makeContext(readme: String(repeating: "读", count: 16_000)),
            question: "继续"
        )
        original.history = history

        let prepared = try await RepoAIChatContextBudget.prepare(original, countTokens: count)
        let result = try #require(prepared)

        #expect(result.inputTokens <= 28_672)
        #expect(!result.wasCompacted)
        #expect(result.request.systemPrompt == original.systemPrompt)
        #expect(result.request.history == history)
    }

    @Test("整条请求的 tokenizer 报告超额时再次精简，保留近期完整回合与当前问题")
    func rechecksDenseInputAndCompactsHistory() async throws {
        let history = (0..<44).flatMap { index in
            [AIChatMessage(role: .user, content: "question \(index) " + String(repeating: "旧", count: 850)),
             AIChatMessage(role: .assistant, content: "answer \(index) " + String(repeating: "复", count: 850))]
        }
        var original = request(makeContext(readme: String(repeating: "密", count: 44_000)), question: "现在继续")
        original.history = history
        let prepared = try await RepoAIChatContextBudget.prepare(original, countTokens: count)
        let result = try #require(prepared)
        #expect(result.inputTokens <= 28_672)
        #expect(result.wasCompacted)
        #expect(result.request.userPrompt == original.userPrompt)
        #expect(result.request.history.first?.content.contains("Earlier conversation excerpts") == true)
        #expect(Array(result.request.history.suffix(2)) == Array(history.suffix(2)))
        #expect(original.history == history)
    }

    @Test("当前用户问题及系统指令超限时明确失败，不裁原文")
    func refusesToTruncateQuestion() async {
        let original = request(makeContext(readme: "guidance"), question: String(repeating: "问", count: 35_000))
        await #expect(throws: LocalAIError.repositoryChatInputTooLong) {
            try await RepoAIChatContextBudget.prepare(original) { candidate in
                #expect(candidate.userPrompt == original.userPrompt)
                #expect(candidate.systemPrompt.contains("INSTRUCTIONS"))
                return count(candidate)
            }
        }
    }

    /// 用偏高密度的测试计数模拟估算不足，实际业务用当前模型模板计数。
    private func count(_ request: AIChatRequest) -> Int {
        request.systemPrompt.count + request.userPrompt.count + 20
            + request.history.reduce(0) { $0 + $1.content.count + 8 }
    }

    private func makeContext(readme: String, codeContext: String = "", onboardingReadme: String? = nil) -> RepoAIChatContext {
        RepoAIChatContext(template: "INSTRUCTIONS\n{metadata}\n{readme}\nCODE:\n{codeContext}",
                          outputLanguage: "English", runtimeContext: "", starcatResources: "",
                          metadata: "aoci-spec/aoci-code", readme: readme, codeContext: codeContext,
                          insightsContext: "", summary: "", externalContext: "", previousSessionCarryOver: "",
                          onboardingReadme: onboardingReadme)
    }

    private func request(_ context: RepoAIChatContext, question: String) -> AIChatRequest {
        AIChatRequest(systemPrompt: context.systemPrompt, userPrompt: question, model: "test",
                      parameters: .summaryDefault, repositoryContext: context)
    }

    private func fixtureXML(readme: String, source: String) -> String {
        """
        <repository><directoryStructure>Sources/main.swift</directoryStructure><keyFiles>
        <file path="README.md"><![CDATA[\(readme)]]></file>
        <file path="README.zh-CN.md">翻译</file>
        <file path="docs/README.md">nested docs</file>
        <file path="Sources/main.swift"><![CDATA[\(source)]]></file>
        </keyFiles><entryPoints><file path="Sources/main.swift">entry point</file></entryPoints></repository>
        """
    }
}
