//
//  AgentJSON.swift
//  Starcat
//
//  Agent 工具协议使用的 JSON 值与轻量 Schema。
//
//  模型返回的 tool-call arguments 不能直接落到 `[String: Any]`：`Any` 不满足
//  Sendable/Codable，也无法在 Swift 6 并发边界和运行历史中安全传递。这里使用值语义模型，
//  同一份输入可以被模型适配层解析、Runtime 校验、工具执行和 Repository 持久化。
//

import Foundation

/// 可跨并发边界、可持久化的 JSON 值。
indirect enum AgentJSONValue: Hashable, Sendable {
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: AgentJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    /// 生成稳定排序的 JSON，便于审计日志、测试 fixture 和 provider 请求复用。
    func jsonString() throws -> String {
        let data = try JSONEncoder.agent.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentJSONError.invalidUTF8
        }
        return string
    }
}

extension AgentJSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Agent JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw AgentJSONError.nonFiniteNumber }
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Agent 第一版工具参数需要支持的 JSON Schema 类型。
enum AgentJSONSchemaType: String, Codable, Hashable, Sendable {
    case object
    case array
    case string
    case number
    case integer
    case boolean
}

/// 模型可见并由宿主执行前再次校验的轻量 JSON Schema。
///
/// 这不是完整 JSON Schema 标准实现，只覆盖 Agent 工具参数需要的稳定子集。未声明字段默认
/// 拒绝，避免模型拼错参数名后工具静默忽略，从而造成不可审计的行为偏差。
struct AgentJSONSchema: Codable, Hashable, Sendable {
    var type: AgentJSONSchemaType
    var description: String?
    var properties: [String: AgentJSONSchema]?
    var required: [String]
    private var itemSchemas: [AgentJSONSchema]
    var enumValues: [AgentJSONValue]?
    var defaultValue: AgentJSONValue?
    var additionalProperties: Bool

    /// 用单元素数组打断值类型的直接递归存储；对外仍保持标准 JSON Schema 的单个 `items`。
    var items: AgentJSONSchema? { itemSchemas.first }

    init(
        type: AgentJSONSchemaType,
        description: String? = nil,
        properties: [String: AgentJSONSchema]? = nil,
        required: [String] = [],
        items: AgentJSONSchema? = nil,
        enumValues: [AgentJSONValue]? = nil,
        defaultValue: AgentJSONValue? = nil,
        additionalProperties: Bool = false
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.itemSchemas = items.map { [$0] } ?? []
        self.enumValues = enumValues
        self.defaultValue = defaultValue
        self.additionalProperties = additionalProperties
    }

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case properties
        case required
        case items
        case enumValues = "enum"
        case defaultValue = "default"
        case additionalProperties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(AgentJSONSchemaType.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decodeIfPresent([String: AgentJSONSchema].self, forKey: .properties)
        required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
        itemSchemas = try container.decodeIfPresent(AgentJSONSchema.self, forKey: .items).map { [$0] } ?? []
        enumValues = try container.decodeIfPresent([AgentJSONValue].self, forKey: .enumValues)
        defaultValue = try container.decodeIfPresent(AgentJSONValue.self, forKey: .defaultValue)
        additionalProperties = try container.decodeIfPresent(Bool.self, forKey: .additionalProperties) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(properties, forKey: .properties)
        if !required.isEmpty {
            try container.encode(required, forKey: .required)
        }
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(enumValues, forKey: .enumValues)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        if type == .object {
            try container.encode(additionalProperties, forKey: .additionalProperties)
        }
    }

    /// 在工具执行前校验模型参数；错误携带 JSON path，直接作为 error tool-result 返回。
    func validate(_ value: AgentJSONValue, path: String = "$") throws {
        try validateType(value, path: path)

        if let enumValues, !enumValues.contains(value) {
            throw AgentJSONSchemaValidationError.valueNotAllowed(path: path)
        }

        switch (type, value) {
        case (.object, .object(let object)):
            let properties = properties ?? [:]
            for key in required where object[key] == nil {
                throw AgentJSONSchemaValidationError.missingRequired(path: path, key: key)
            }
            if !additionalProperties, let unknown = object.keys.first(where: { properties[$0] == nil }) {
                throw AgentJSONSchemaValidationError.unknownProperty(path: path, key: unknown)
            }
            for (key, child) in object {
                try properties[key]?.validate(child, path: "\(path).\(key)")
            }
        case (.array, .array(let values)):
            if let items {
                for (index, child) in values.enumerated() {
                    try items.validate(child, path: "\(path)[\(index)]")
                }
            }
        default:
            break
        }
    }

    private func validateType(_ value: AgentJSONValue, path: String) throws {
        let isValid: Bool
        switch (type, value) {
        case (.object, .object), (.array, .array), (.string, .string),
             (.number, .number), (.boolean, .bool):
            isValid = true
        case (.integer, .number(let number)):
            isValid = number.isFinite && number.rounded() == number
        default:
            isValid = false
        }
        guard isValid else {
            throw AgentJSONSchemaValidationError.typeMismatch(path: path, expected: type)
        }
    }
}

enum AgentJSONSchemaValidationError: LocalizedError, Equatable, Sendable {
    case typeMismatch(path: String, expected: AgentJSONSchemaType)
    case missingRequired(path: String, key: String)
    case unknownProperty(path: String, key: String)
    case valueNotAllowed(path: String)

    var errorDescription: String? {
        switch self {
        case .typeMismatch(let path, let expected):
            return String(format: String.l10n("agent.schema.error.typeMismatchFormat"), path, expected.rawValue)
        case .missingRequired(let path, let key):
            return String(format: String.l10n("agent.schema.error.missingRequiredFormat"), path, key)
        case .unknownProperty(let path, let key):
            return String(format: String.l10n("agent.schema.error.unknownPropertyFormat"), path, key)
        case .valueNotAllowed(let path):
            return String(format: String.l10n("agent.schema.error.valueNotAllowedFormat"), path)
        }
    }
}

enum AgentJSONError: LocalizedError, Equatable, Sendable {
    case invalidUTF8
    case nonFiniteNumber

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: return String.l10n("agent.json.error.invalidUTF8")
        case .nonFiniteNumber: return String.l10n("agent.json.error.nonFiniteNumber")
        }
    }
}

private extension JSONEncoder {
    static var agent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
