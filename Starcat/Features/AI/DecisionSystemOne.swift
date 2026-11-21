//
//  DecisionSystemOne.swift
//  Starcat
//
//  App、远端 Jev 和公共调用共用的 System One JSON 契约。
//  题目 ID 来自调用方，决定答案归属。只有 App 设置可以决定实际模型。
//

import Foundation

/// 保留协议中嵌套的数组、对象和 null；文本模型需要时才把结构化内容转成稳定文本。
extension AgentJSONValue {
    var decisionText: String {
        if case .string(let text) = self { return text }
        return (try? jsonString()) ?? ""
    }

    fileprivate var isDecisionContent: Bool {
        switch self {
        case .string, .array, .object: true
        default: false
        }
    }
}

extension AgentJSONValue {
    /// 图片占位符可嵌套在任意字符串中；仅遍历合法 JSON 值，避免读取正文以外的数据。
    func containsAsset(key: String) -> Bool {
        switch self {
        case .string(let text):
            return text.contains(key)
        case .array(let values):
            return values.contains { $0.containsAsset(key: key) }
        case .object(let values):
            return values.values.contains { $0.containsAsset(key: key) }
        case .number, .bool, .null:
            return false
        }
    }
}

/// 参数路径同时用于 CLI、MCP 和 HTTP。错误只引用字段位置，不包含图片或用户正文。
struct DecisionInputError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// JSON 传输携带内联图片。调用端和 Starcat 均无需打开对方设备的文件。
struct DecisionImageAsset: Codable, Equatable, Sendable {
    let type: String
    let format: String
    let dataBase64: String

    enum CodingKeys: String, CodingKey { case type, format, dataBase64 = "data_base64" }
}

/// 单题与原生 wire 结构相同，criteria 的形状由题型决定，进入引擎前统一校验。
struct DecisionQuestion: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case noul, choice, score, box }
    let type: Kind
    var instructions: AgentJSONValue?
    var criteria: AgentJSONValue?

    /// 现有仓库、标签及搜索问题仍按原有字段编码。
    static func noul(instructions: DecisionQuestionInstructions, criteria: DecisionNoulCriteria?) -> Self {
        let content: AgentJSONValue = switch instructions {
        case .text(let text): .string(text)
        case .object(let fields): .object(fields.mapValues(AgentJSONValue.string))
        }
        return Self(type: .noul, instructions: content, criteria: criteria.map {
            .object(["true": $0.true, "false": $0.false].compactMapValues { $0.map(AgentJSONValue.string) })
        })
    }

    /// App 既有 Noul 阈值按这一 prompt 调整过，结构化仓库指令保持原排列和判据位置。
    var legacyNoulPrompt: String {
        let text: String
        if case .object(let values) = instructions {
            text = values.keys.sorted().map { "\($0): \(values[$0]?.decisionText ?? "")" }.joined(separator: "\n")
        } else {
            text = instructions?.decisionText ?? ""
        }
        var parts = [text]
        for key in ["true", "false"] {
            if let value = criteria?.objectValue?[key]?.stringValue, !value.isEmpty {
                parts.append("\(key) criterion: \(value)")
            }
        }
        return parts.joined(separator: "\n")
    }

    func validate(path: String) throws {
        if let instructions, !instructions.isDecisionContent && instructions != .null {
            throw DecisionInputError("\(path).instructions: expected string, object or array")
        }
        let valid: Bool
        switch (type, criteria) {
        case (.noul, nil), (.noul, .null), (.box, nil), (.box, .null):
            valid = true
        case (.noul, .object(let values)):
            valid = values.allSatisfy { ["true", "false"].contains($0.key) && ($0.value.isDecisionContent || $0.value == .null) }
        case (.choice, .object(let values)):
            valid = (1...255).contains(values.count) && values.values.allSatisfy { $0.isDecisionContent || $0 == .null }
        case (.score, .array(let values)):
            valid = (1...10).contains(values.count) && values.allSatisfy(\.isDecisionContent)
        default:
            valid = false
        }
        guard valid else { throw DecisionInputError("\(path).criteria: invalid \(type.rawValue) criteria") }
    }

    /// Jev / OpenRouter 都允许占位符出现在任意字符串内部；校验只跟踪字符串节点，
    /// 避免把对象字段名或数字误判成图片引用。
    func referencesAsset(key: String) -> Bool {
        return (instructions ?? .null).containsAsset(key: key)
            || (criteria ?? .null).containsAsset(key: key)
    }
}

/// 接收 Jev 客户端的 model 以兼容现有请求，转换成执行请求时只保留内容字段。
struct DecisionSystemOneInput: Decodable {
    let model: String?
    let state: AgentJSONValue
    let questions: [String: DecisionQuestion]
    let assets: [String: DecisionImageAsset]?

    func evaluationRequest() throws -> DecisionEvaluationRequest {
        // Jev SDK 的最低版本不再要求 model；公开入口省略 model 时按 App 配置选择。
        // 仍拒绝显式空值，避免客户端误以为它能改变执行模型。
        if let model, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecisionInputError("arguments.model: expected a non-empty model name")
        }
        guard state.isDecisionContent else { throw DecisionInputError("arguments.state: expected string, object or array") }
        guard !questions.isEmpty else { throw DecisionInputError("arguments.questions: expected at least one question") }
        for (name, question) in questions { try question.validate(path: "arguments.questions.\(name)") }
        if let assets {
            guard !assets.isEmpty else { throw DecisionInputError("arguments.assets: expected at least one image") }
            for (key, asset) in assets {
                guard !key.isEmpty, asset.type == "image", ["png", "jpeg", "jpg"].contains(asset.format),
                      !asset.dataBase64.isEmpty, Data(base64Encoded: asset.dataBase64) != nil
                else { throw DecisionInputError("arguments.assets.\(key): expected a base64 PNG or JPEG image") }
                let referencesAsset = questions.values.contains { $0.referencesAsset(key: key) }
                    || state.containsAsset(key: key)
                guard referencesAsset else {
                    throw DecisionInputError("arguments.assets.\(key): expected a reference in state or questions")
                }
            }
        }
        if questions.values.contains(where: { $0.type == .box }), assets == nil {
            throw DecisionInputError("arguments.assets: box requires an image")
        }
        // Jev 协议允许 state 直接是字符串；引擎契约用 .text 表达这个常见形态，
        // 只有对象 / 数组才保留为通用 JSON，避免下游把纯文本再按 JSON 解释。
        let engineState: DecisionState
        if case .string(let text) = state {
            engineState = .text(text)
        } else {
            engineState = .json(state)
        }
    }
}

/// 四种答案沿用 Jev 字段。Box 的 confidence 可以为 JSON null，原生 SDK 仍要求该键存在。
struct DecisionAnswer: Codable, Equatable, Sendable {
    struct Box: Codable, Equatable, Sendable {
        let top, bottom, left, right: Double
    }
    let type: String
    var noul: Double?
    var choice: String?
    var score: Double?
    var box: Box?
    var confidence: Double?
    var probabilities: [String: Double]?
    var legend: AgentJSONValue?

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(type, forKey: .type)
        try fields.encodeIfPresent(noul, forKey: .noul)
        try fields.encodeIfPresent(choice, forKey: .choice)
        try fields.encodeIfPresent(score, forKey: .score)
        try fields.encodeIfPresent(box, forKey: .box)
        if type == "box" { try fields.encode(confidence, forKey: .confidence) }
        else { try fields.encodeIfPresent(confidence, forKey: .confidence) }
        try fields.encodeIfPresent(probabilities, forKey: .probabilities)
        try fields.encodeIfPresent(legend, forKey: .legend)
    }

    /// 封闭题型按请求的选项 / 等级校验，避免错误键或越界坐标被外部调用方用作决策。
    func matches(_ question: DecisionQuestion) -> Bool {
        func probability(_ value: Double?) -> Bool { value.map { (0...1).contains($0) } == true }
        func distribution(_ keys: Set<String>) -> Bool {
            guard let probabilities else { return false }
            return Set(probabilities.keys) == keys && probabilities.values.allSatisfy { probability($0) }
        }
        guard type == question.type.rawValue else { return false }
        switch question.type {
        case .noul:
            return probability(noul)
        case .choice:
            guard let options = question.criteria?.objectValue, let choice else { return false }
            return options[choice] != nil && distribution(Set(options.keys)) && probability(confidence)
        case .score:
            guard case .array(let levels) = question.criteria, !levels.isEmpty, let score else { return false }
            let expected = Dictionary(uniqueKeysWithValues: levels.enumerated().map { (String($0.offset), $0.element) })
            return (0...Double(levels.count - 1)).contains(score) && legend == .object(expected)
                && distribution(Set(expected.keys)) && probability(confidence)
        case .box:
            guard let box else { return false }
            return [box.top, box.bottom, box.left, box.right].allSatisfy { probability($0) }
                && box.top <= box.bottom && box.left <= box.right && (confidence == nil || probability(confidence))
        }
    }
}
