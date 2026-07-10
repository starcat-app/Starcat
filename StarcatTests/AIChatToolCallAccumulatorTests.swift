//
//  AIChatToolCallAccumulatorTests.swift
//  StarcatTests
//
//  验证流式 function tool-call 的交错聚合和缺失 id 兜底。
//

import Testing
@testable import Starcat

@Suite("AIChatToolCallAccumulator")
struct AIChatToolCallAccumulatorTests {
    @Test("按 index 聚合交错的参数增量")
    func assemblesInterleavedDeltasByIndex() {
        var accumulator = AIChatToolCallAccumulator()
        accumulator.append(.init(index: 1, id: "call-2", name: "external_", argumentsFragment: "{\"q\":"))
        accumulator.append(.init(index: 0, id: "call-1", name: "repo_", argumentsFragment: "{\"id\":"))
        accumulator.append(.init(index: 1, name: "search", argumentsFragment: "\"swift\"}"))
        accumulator.append(.init(index: 0, name: "detail", argumentsFragment: "42}"))

        #expect(accumulator.completedCalls() == [
            AIChatToolCall(id: "call-1", name: "repo_detail", arguments: "{\"id\":42}"),
            AIChatToolCall(id: "call-2", name: "external_search", arguments: "{\"q\":\"swift\"}")
        ])
    }

    @Test("缺失 id 和参数时生成可关联的宿主调用")
    func suppliesMissingIDAndEmptyArguments() {
        var accumulator = AIChatToolCallAccumulator()
        accumulator.append(.init(index: 0, name: "repo_detail"))

        let calls = accumulator.completedCalls(idFactory: { "host-call-id" })

        #expect(calls == [AIChatToolCall(id: "host-call-id", name: "repo_detail", arguments: "{}")])
    }
}
