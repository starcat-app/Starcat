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

    /// `part` 只出现在 Jev multipart 传输层；JSON 请求在归一化前不能直接使用它。
    let part: String?

    enum CodingKeys: String, CodingKey { case type, format, dataBase64 = "data_base64", part }

    /// JSON 请求的默认路径不携带 multipart 引用；这里给解码和调用端一个稳定默认值。
    init(type: String, format: String, dataBase64: String, part: String? = nil) {
        self.type = type
        self.format = format
        self.dataBase64 = dataBase64
        self.part = part
    }

    /// multipart 的 JSON part 只引用原始字节；空的 format/base64 会在归一化或执行校验中被拒绝。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        dataBase64 = try container.decodeIfPresent(String.self, forKey: .dataBase64) ?? ""
        part = try container.decodeIfPresent(String.self, forKey: .part)
    }
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
                guard !key.isEmpty, asset.type == "image", asset.part == nil,
                      ["png", "jpeg", "jpg"].contains(asset.format),
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
        return DecisionEvaluationRequest(state: engineState, questions: questions, operation: .external, assets: assets)
    }
}

/// Jev `/v1/systemone` 的 multipart 归一化。
///
/// 官方协议规定：首个 part 必须叫 `request` 且承载 UTF-8 JSON；每个图片 part
/// 通过 JSON `assets.<reference>.part` 引用。这里不实现第二套执行协议，只把
/// 图片字节替换成已有 `data_base64`，让 CLI / MCP / HTTP 继续共用一个执行器。
extension DecisionSystemOneInput {
    private struct MultipartPart {
        let name: String
        let contentType: String?
        let body: Data
    }

    static func normalize(
        multipartBody body: Data,
        contentType header: String?
    ) throws -> Self {
        let boundary = try boundary(from: header)
        let parts = try parse(body, boundary: boundary)
        guard let requestPart = parts.first, requestPart.name == "request" else {
            throw DecisionInputError("multipart.request: the first part must be named request")
        }

        do {
            var input = try JSONDecoder().decode(Self.self, from: requestPart.body)
            let imageParts = parts.dropFirst()
            var byName: [String: MultipartPart] = [:]
            for part in imageParts {
                // Content-Type 可省略；缺失时由 imageFormat 根据 Jev 元数据或图片 magic bytes 判断。
                if let contentType = part.contentType,
                   !["image/png", "image/jpeg", "image/jpg", "application/octet-stream"].contains(contentType.lowercased()) {
                    throw DecisionInputError("multipart.\(part.name): expected image/png, image/jpeg, image/jpg, application/octet-stream or no content type")
                }
                guard byName[part.name] == nil else {
                    throw DecisionInputError("multipart.\(part.name): duplicate part name")
                }
                byName[part.name] = part
            }

            var normalizedAssets: [String: DecisionImageAsset] = [:]
            for (reference, asset) in input.assets ?? [:] {
                guard let partName = asset.part else {
                    // multipart JSON 仍允许直接放 data_base64；这里保持 Jev 行为，
                    // 由 evaluationRequest 做相同的 base64 与引用校验。
                    normalizedAssets[reference] = asset
                    continue
                }
                guard let part = byName[partName] else {
                    throw DecisionInputError("multipart.\(partName): asset \(reference) references a missing part")
                }
                byName.removeValue(forKey: partName)
                let format = try imageFormat(asset: asset, part: part)
                normalizedAssets[reference] = DecisionImageAsset(
                    type: asset.type,
                    format: format,
                    dataBase64: part.body.base64EncodedString(),
                    part: nil
                )
            }
            guard byName.isEmpty else {
                throw DecisionInputError("multipart.\(byName.keys.sorted().first ?? "part"): image part is not referenced by any asset")
            }
            input = Self(
                model: input.model,
                state: input.state,
                questions: input.questions,
                assets: input.assets == nil ? nil : normalizedAssets
            )
            return input
        } catch let error as DecisionInputError {
            throw error
        } catch {
            throw DecisionInputError("multipart.request: expected a UTF-8 JSON System One request")
        }
    }

    private static func boundary(from header: String?) throws -> String {
        let marker = "boundary="
        guard let header, header.lowercased().hasPrefix("multipart/form-data"),
              let range = header.range(of: marker, options: .caseInsensitive),
              let boundary = header[range.upperBound...].split(separator: ";").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        else {
            throw DecisionInputError("headers.Content-Type: expected multipart/form-data with boundary")
        }
        guard !boundary.isEmpty else {
            throw DecisionInputError("headers.Content-Type: boundary must not be empty")
        }
        return boundary
    }

    private static func parse(_ body: Data, boundary: String) throws -> [MultipartPart] {
        let boundaryData = Data("--\(boundary)".utf8)
        var parts: [MultipartPart] = []
        var remainder = Data(body)
        while let boundaryRange = remainder.range(of: boundaryData) {
            var part = Data(remainder[..<boundaryRange.lowerBound])
            remainder = Data(remainder[boundaryRange.upperBound...])
            let isFinalPart = remainder.starts(with: Data("--".utf8))
            if part.starts(with: Data("\r\n".utf8)) {
                part = part.dropFirst(2)
            }
            if remainder.starts(with: Data("\r\n".utf8)) {
                remainder = remainder.dropFirst(2)
            }
            if part.isEmpty {
                // 只允许在首个 boundary 前出现 preamble；终结 boundary 前必须有实际 part。
                guard !isFinalPart else {
                    throw DecisionInputError("multipart: malformed final part framing")
                }
                continue
            }
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else {
                throw DecisionInputError("multipart: malformed part headers")
            }
            let headerText = String(data: part[..<headerEnd.lowerBound], encoding: .utf8)
            let body = Data(part[headerEnd.upperBound...])
            guard let headerText, body.count >= 2, body.suffix(2) == Data("\r\n".utf8) else {
                throw DecisionInputError("multipart: malformed part framing")
            }
            var name: String?
            var contentType: String?
            for line in headerText.split(separator: "\r\n") {
                let fields = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard fields.count == 2 else { continue }
                if fields[0].lowercased() == "content-type" {
                    contentType = fields[1].trimmingCharacters(in: .whitespaces)
                } else if fields[0].lowercased() == "content-disposition",
                          let value = fields[1].range(of: "name=\"", options: .caseInsensitive)?.upperBound {
                    name = String(fields[1][value...].prefix(while: { $0 != "\"" }))
                }
            }
            guard let name, !name.isEmpty else {
                throw DecisionInputError("multipart: every part requires a non-empty name")
            }
            parts.append(MultipartPart(name: name, contentType: contentType, body: body.dropLast(2)))
            if isFinalPart { break }
        }
        guard remainder.starts(with: Data("--".utf8)) else {
            throw DecisionInputError("multipart: missing closing boundary")
        }
        guard !parts.isEmpty else {
            throw DecisionInputError("multipart: no parts found")
        }
        return parts
    }

    private static func imageFormat(asset: DecisionImageAsset, part: MultipartPart) throws -> String {
        let contentType = part.contentType?.lowercased()
        let knownFormat: String? = ["image/png": "png", "image/jpeg": "jpeg", "image/jpg": "jpg"][contentType ?? ""]
        if let format = knownFormat {
            return format
        }
        if ["png", "jpeg", "jpg"].contains(asset.format) {
            return asset.format
        }
        if part.body.starts(with: Data([0x89, 0x50, 0x4e, 0x47])) { return "png" }
        if part.body.starts(with: Data([0xff, 0xd8])) { return "jpeg" }
        throw DecisionInputError("multipart.\(part.name): expected PNG or JPEG bytes")
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
