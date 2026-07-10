//
//  AgentJSONTests.swift
//  StarcatTests
//
//  Agent tool JSON value 与 Schema 校验契约测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Agent JSON")
struct AgentJSONTests {

    @Test("JSON value 可稳定编码并往返解码")
    func valueRoundTrip() throws {
        let value: AgentJSONValue = .object([
            "enabled": .bool(true),
            "limit": .number(5),
            "query": .string("swift agent"),
            "repos": .array([.string("groue/GRDB.swift")]),
            "optional": .null
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AgentJSONValue.self, from: data)

        #expect(decoded == value)
        #expect(try value.jsonString().contains("\"query\":\"swift agent\""))
    }

    @Test("object schema 校验 required、类型与未知字段")
    func objectValidation() throws {
        let schema = AgentJSONSchema(
            type: .object,
            properties: [
                "query": AgentJSONSchema(type: .string),
                "maxResults": AgentJSONSchema(type: .integer)
            ],
            required: ["query"]
        )

        try schema.validate(.object([
            "query": .string("Swift Agent"),
            "maxResults": .number(5)
        ]))

        #expect(throws: AgentJSONSchemaValidationError.missingRequired(path: "$", key: "query")) {
            try schema.validate(.object([:]))
        }
        #expect(throws: AgentJSONSchemaValidationError.typeMismatch(path: "$.maxResults", expected: .integer)) {
            try schema.validate(.object(["query": .string("Swift"), "maxResults": .number(2.5)]))
        }
        #expect(throws: AgentJSONSchemaValidationError.unknownProperty(path: "$", key: "extra")) {
            try schema.validate(.object(["query": .string("Swift"), "extra": .bool(true)]))
        }
    }

    @Test("array items 与 enum 会递归校验并保留路径")
    func nestedArrayAndEnumValidation() throws {
        let schema = AgentJSONSchema(
            type: .array,
            items: AgentJSONSchema(
                type: .string,
                enumValues: [.string("day"), .string("week")]
            )
        )

        try schema.validate(.array([.string("day"), .string("week")]))
        #expect(throws: AgentJSONSchemaValidationError.valueNotAllowed(path: "$[1]")) {
            try schema.validate(.array([.string("day"), .string("month")]))
        }
    }
}
