//
//  AIChatToolCallAccumulator.swift
//  Starcat
//
//  OpenAI-compatible 流式 function tool-call 增量组装器。
//
//  同一次调用的 id、name 和 arguments 可能分散在多个 SSE chunk 中，多个调用还可能
//  交错返回。本类型严格按 provider 给出的 index 聚合，保留参数原文，完成后再交给
//  Agent Runtime 做 JSON 解码和 schema 校验。
//

import Foundation

struct AIChatToolCallAccumulator: Sendable {
    private struct PartialCall: Sendable {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var callsByIndex: [Int: PartialCall] = [:]

    var isEmpty: Bool { callsByIndex.isEmpty }

    mutating func append(_ delta: AIChatToolCallDelta) {
        var partial = callsByIndex[delta.index] ?? PartialCall()
        if let id = delta.id, !id.isEmpty {
            // OpenAI 协议把 id 视为完整值而非文本 delta；部分兼容服务会在多个 chunk
            // 重复发送同一个 id，覆盖可避免拼成 `call-1call-1`。
            partial.id = id
        }
        if let name = delta.name, !name.isEmpty {
            partial.name += name
        }
        if let fragment = delta.argumentsFragment, !fragment.isEmpty {
            partial.arguments += fragment
        }
        callsByIndex[delta.index] = partial
    }

    /// 某些 OpenAI-compatible provider 不返回 call id。这里生成宿主 id，确保后续
    /// assistant/tool 消息仍可按同一 id 关联；name 为空则保留为空，由 Runtime 产生
    /// 可审计的 missing-tool 错误结果。
    func completedCalls(idFactory: @Sendable () -> String = { UUID().uuidString }) -> [AIChatToolCall] {
        callsByIndex.keys.sorted().compactMap { index in
            guard let partial = callsByIndex[index] else { return nil }
            return AIChatToolCall(
                id: partial.id.isEmpty ? idFactory() : partial.id,
                name: partial.name,
                arguments: partial.arguments.isEmpty ? "{}" : partial.arguments
            )
        }
    }
}
