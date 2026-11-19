//
//  LocalAIGenerationPolicyTests.swift
//  StarcatTests
//
//  本地生成的无权重回归：采样默认、重复后缀、超时取消及终止原因。
//  不读取用户配置或模型目录，不触发 GPU 工作。
//

import Foundation
import Testing
@testable import Starcat

/// 工程保护必须可确定性验证，不能依赖随机模型“这次没有重复”。
@Suite("LocalAIGenerationPolicy")
struct LocalAIGenerationPolicyTests {
    @Test("MiniCPM 和 Qwen3 使用各自默认采样，输出预算有界")
    func modelSpecificDefaults() throws {
        let mini = LocalAIGenerationPolicy.defaultParameters(model: LocalAIModelCatalog.llmMiniCPM5.displayName, capability: .chat)
        let qwen = LocalAIGenerationPolicy.defaultParameters(model: LocalAIModelCatalog.llmLite.displayName, capability: .chat)
        #expect(mini.temperature == 1.0 && mini.topP == 0.95 && mini.topK == 0)
        #expect(qwen.temperature == 0.6 && qwen.topK == 20)
        #expect(mini.maxCompletionTokens <= LocalAIMemoryPolicy.outputTokens)
        #expect(qwen.maxCompletionTokens <= LocalAIMemoryPolicy.outputTokens)
        let miniWindow = try #require(mini.contextWindowTokens)
        let qwenWindow = try #require(qwen.contextWindowTokens)
        #expect(miniWindow - mini.maxCompletionTokens <= LocalAIMemoryPolicy.inputTokens)
        #expect(qwenWindow - qwen.maxCompletionTokens <= LocalAIMemoryPolicy.inputTokens)
    }

    @Test("仓库对话固定 32K 窗口，预留 4K 输出，不改原模型配置")
    func repositoryChatKeepsOutputHeadroom() {
        var original = AIModelParameters.summaryDefault
        original.contextWindowTokens = 128 * 1_024
        original.maxCompletionTokens = 80_000
        let localChat = LocalAIGenerationPolicy.repositoryChatParameters(original)
        #expect(localChat.contextWindowTokens == 32_768)
        #expect(localChat.maxCompletionTokens == 4_096)
        #expect(LocalAIGenerationPolicy.chatInputTokens + localChat.maxCompletionTokens == 32_768)
        #expect(original.contextWindowTokens == 131_072)
        #expect(original.maxCompletionTokens == 80_000)
        original.maxCompletionTokens = 1_000
        #expect(LocalAIGenerationPolicy.repositoryChatParameters(original).maxCompletionTokens == 1_000)
    }

    @Test("重复章节不受流分块大小影响", arguments: [1, 7, 64, 1_024])
    func detectsRepeatedSections(chunkSize: Int) {
        let block = (0..<24).map { "## 配置条目 \($0)\n这一条说明对应独立配置的用途与验证条件。\n" }.joined()
        let characters = Array(String(repeating: block, count: 6))
        var guardState = LocalAIRepetitionGuard()
        var stopped = false
        for index in stride(from: 0, to: characters.count, by: chunkSize) {
            if guardState.ingest(String(characters[index..<min(index + chunkSize, characters.count)])) {
                stopped = true
                break
            }
        }
        #expect(stopped)
    }

    @Test("短重复、正常列表与两次引用不触发保护")
    func allowsOrdinaryRepetition() {
        var guardState = LocalAIRepetitionGuard()
        let shortRepeated = guardState.ingest("## Notes\n- TODO\n- TODO\n- TODO\n")
        #expect(!shortRepeated)
        let block = (0..<40).map { "项目 \($0)：独立配置及注释\n" }.joined()
        let quotedTwice = guardState.ingest(block + block)
        #expect(!quotedTwice)
    }

    @Test("成功调用不等待超时计时器")
    func finishesBeforeDeadline() async throws {
        let value = try await LocalAIGenerationPolicy.withTimeout(seconds: 10) { 42 }
        #expect(value == 42)
    }

    @Test("超时会取消工作并等待清理，不遗留后台生成")
    func timeoutJoinsCancelledWork() async {
        let probe = CancellationProbe()
        do {
            try await LocalAIGenerationPolicy.withTimeout(seconds: 0.01) {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { await probe.markFinished(); throw error }
            }
            Issue.record("Expected timeout")
        } catch {
            #expect(LocalAIGenerationPolicy.finishReason(for: error) == "timeout")
        }
        #expect(await probe.finished)
    }

    @Test("长度截断不能成为正常完成")
    func rejectsTruncatedCompletion() throws {
        let response = AIChatResponse(content: "unfinished", model: "test", finishReason: "length")
        #expect(throws: AIClientError.responseTruncated) { try LocalAIGenerationPolicy.validateCompletion(response) }
        var complete = response
        complete.finishReason = "stop"
        try LocalAIGenerationPolicy.validateCompletion(complete)
    }

    @Test("用户取消同样等待生成任务清理")
    func parentCancellationJoinsWork() async {
        let probe = CancellationProbe()
        let task = Task {
            try await LocalAIGenerationPolicy.withTimeout(seconds: 10) {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { await probe.markFinished(); throw error }
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.finished)
    }

    @Test("内部为停止 producer 发起取消时，保留原始重复错误")
    func keepsRepetitionErrorAfterInternalCancellation() async {
        await #expect(throws: LocalAIError.repetitiveOutput) {
            try await LocalAIGenerationPolicy.withTimeout(seconds: 10) {
                withUnsafeCurrentTask { $0?.cancel() }
                throw LocalAIError.repetitiveOutput
            }
        }
    }

    @Test("重复和用户取消保留不同的终止类别")
    func distinguishesRepetitionAndCancellation() {
        #expect(LocalAIGenerationPolicy.finishReason(for: LocalAIError.repetitiveOutput) == "repetition")
        #expect(LocalAIGenerationPolicy.finishReason(for: CancellationError()) == "cancelled")
    }
}

/// 异步清理探针仅在测试中持有一个布尔值，避免跨任务共享可变捕获。
private actor CancellationProbe {
    private(set) var finished = false
    func markFinished() { finished = true }
}
