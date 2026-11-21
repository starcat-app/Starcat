//
//  LayaMLXDecisionRuntime.swift
//  Starcat
//
//  Laya Multilingual checkpoint 的进程内 MLX Swift runtime。
//
//  文本题型按最多 16 个问题组成 batch，一次 forward 返回各题的 marker logits。
//  模型、tokenizer 与 MLXArray 留在 actor 内，非 Sendable 图状态不会越过并发边界。
//


import Foundation
import MLX
import MLXNN
import Tokenizers

/// 加载或推理失败时保留足够上下文，避免把 checkpoint 不兼容误报成普通 AI 失败。
enum LayaMLXDecisionError: Error, LocalizedError, Sendable {
    case incompleteCheckpoint(String)
    case invalidConfiguration(String)
    case invalidTokenizer(String)
    case runtimeNotLoaded
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .incompleteCheckpoint(let path):
            return "Laya checkpoint 缺少必需文件：\(path)"
        case .invalidConfiguration(let reason):
            return "Laya checkpoint 配置不兼容：\(reason)"
        case .invalidTokenizer(let reason):
            return "Laya tokenizer 不兼容：\(reason)"
        case .runtimeNotLoaded:
            return "Laya MLX runtime 尚未完成加载"
        case .invalidOutput(let reason):
            return "Laya MLX 推理输出无效：\(reason)"
        }
    }
}

/// checkpoint 权重精度；产品默认与社区预转换模型一致使用 FP16。
enum LayaMLXPrecision: Sendable {
    case float16
    case float32

    fileprivate var dataType: DType {
        switch self {
        case .float16: .float16
        case .float32: .float32
        }
    }
}

/// 在 checkpoint 对拍中保留未校准 logits，公共调用只返回协议答案和 token 用量。
struct LayaPrediction: Sendable {
    let answer: DecisionAnswer
    let logits: [Float]
    let inputTokenCount: Int
}

/// 文本选项的排列同时决定 marker、logit 和响应键之间的映射。
struct LayaTextQuestion: Sendable {
    enum Kind: Int32, Sendable {
        // 此顺序来自 checkpoint 的 type_embedding 权重。
        case choice = 0, score = 1, noul = 2

        var name: String {
            switch self {
            case .choice: "choice"
            case .score: "score"
            case .noul: "noul"
            }
        }
    }

    let kind: Kind
    let instructions: String
    let options: [String]
    let keys: [String]
    var levels: [AgentJSONValue] = []

    init(_ question: DecisionQuestion, legacyNoul: Bool = false) throws {
        let instructions = question.instructions?.decisionText ?? ""
        switch (question.type, question.criteria) {
        case (.noul, _):
            let criteria = legacyNoul ? nil : question.criteria?.objectValue
            let negative = criteria?["false"].flatMap(Self.description) ?? "no, the statement does not hold"
            let positive = criteria?["true"].flatMap(Self.description) ?? "yes, the statement holds"
            kind = .noul
            self.instructions = legacyNoul ? question.legacyNoulPrompt : instructions
            keys = ["false", "true"]
            options = ["false: \(negative)", "true: \(positive)"]
        case (.choice, .object(let choices)) where !choices.isEmpty:
            let names = choices.keys.sorted()
            kind = .choice
            self.instructions = instructions
            keys = names
            options = names.map { name in
                choices[name].flatMap(Self.description).map { "\(name): \($0)" } ?? name
            }
        case (.score, .array(let criteria)) where !criteria.isEmpty:
            kind = .score
            self.instructions = instructions
            levels = criteria
            keys = criteria.indices.map(String.init)
            options = criteria.enumerated().map { "level \($0.offset): \($0.element.decisionText)" }
        default:
            throw DecisionInputError("Invalid or unsupported Laya question; expected noul, choice or score")
        }
    }

    private static func description(_ value: AgentJSONValue) -> String? {
        guard value != .null, value != .string("") else { return nil }
        return value.decisionText
    }

    /// 对齐 Laya 的 softmax 和熵置信度。评分以未舍入的分布计算零基期望值。
    func answer(logits: [Float], temperature: Double) throws -> DecisionAnswer {
        guard logits.count == keys.count, logits.allSatisfy(\.isFinite),
              let maximum = logits.max(), let winner = logits.firstIndex(of: maximum)
        else {
            throw LayaMLXDecisionError.invalidOutput("Unexpected \(kind.name) logits")
        }
        let masses = logits.map { exp((Double($0) - Double(maximum)) / temperature) }
        let total = masses.reduce(0, +)
        let probabilities = masses.map { $0 / total }
        func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        let distribution = Dictionary(uniqueKeysWithValues: zip(keys, probabilities.map(rounded)))
        let entropy = probabilities.reduce(0) { $0 - $1 * log(max($1, 1e-12)) }
        let certainty = keys.count == 1 ? 1 : 1 - entropy / log(Double(keys.count))
        let confidence = rounded(min(1, max(0, certainty)))
        switch kind {
        case .choice:
            return DecisionAnswer(type: kind.name, choice: keys[winner], confidence: confidence, probabilities: distribution)
        case .score:
            let expected = probabilities.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
            let legend = Dictionary(uniqueKeysWithValues: zip(keys, levels))
            return DecisionAnswer(
                type: kind.name, score: rounded(expected), confidence: confidence,
                probabilities: distribution, legend: .object(legend)
            )
        case .noul:
            return DecisionAnswer(type: kind.name, noul: rounded(probabilities[1]))
        }
    }
}

/// prompt builder 只依赖这一小段 tokenizer 能力，常规单测无需加载 644 MB 权重。
protocol LayaTokenizing: Sendable {
    var classTokenID: Int { get }
    var separatorTokenID: Int { get }
    var paddingTokenID: Int { get }
    var maskToken: String { get }
    var maskTokenID: Int { get }

    func encodeWithoutSpecialTokens(_ text: String) -> [Int]
}

/// Swift Transformers tokenizer 的轻量适配，特殊 token 仍以 checkpoint 配置为准。
private struct LayaTokenizerAdapter: LayaTokenizing {
    let tokenizer: any Tokenizer
    let classTokenID: Int
    let separatorTokenID: Int
    let paddingTokenID: Int
    let maskToken: String
    let maskTokenID: Int

    func encodeWithoutSpecialTokens(_ text: String) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: false)
    }
}

/// 单题的 CPU 表示，marker 次序与该题的 options 一致。
struct LayaPreparedInput: Equatable, Sendable {
    let tokenIDs: [Int]
    let markerPositions: [Int]
}

/// 保留 checkpoint 的顺序 marker 布局和截断规则。
struct LayaPromptBuilder: Sendable {
    let maximumLength: Int
    let headMaximumLength: Int

    /// 格式：`[CLS] <type> question... [SEP] [MASK] opt0... [MASK] opt1... [SEP] state [SEP]`。
    func build(
        state: String,
        question: LayaTextQuestion,
        tokenizer: any LayaTokenizing
    ) throws -> LayaPreparedInput {
        let sanitizedInstructions = question.instructions.replacingOccurrences(
            of: tokenizer.maskToken,
            with: " "
        )
        var headIDs = tokenizer.encodeWithoutSpecialTokens(
            "\(question.kind.name) question: \(sanitizedInstructions)"
        )
        var optionIDs = question.options.map { option in
            let sanitized = option.replacingOccurrences(of: tokenizer.maskToken, with: " ")
            return [tokenizer.maskTokenID]
                + tokenizer.encodeWithoutSpecialTokens(" \(sanitized)").prefix(48)
        }

        var optionBudget = headMaximumLength - optionIDs.reduce(0) { $0 + $1.count }
        if optionBudget < 16 {
            let perOption = max(4, (headMaximumLength - 16) / max(1, optionIDs.count))
            optionIDs = optionIDs.map { Array($0.prefix(perOption)) }
            optionBudget = headMaximumLength - optionIDs.reduce(0) { $0 + $1.count }
        }
        headIDs = Array(headIDs.prefix(max(8, optionBudget)))

        var tokenIDs = [tokenizer.classTokenID] + headIDs + [tokenizer.separatorTokenID]
        var markers: [Int] = []
        for option in optionIDs {
            markers.append(tokenIDs.count)
            tokenIDs.append(contentsOf: option)
        }
        tokenIDs.append(tokenizer.separatorTokenID)

        guard tokenIDs.count < maximumLength else {
            throw DecisionInputError("The question has too many options for the selected Laya model")
        }
        let room = maximumLength - tokenIDs.count - 1
        let sanitizedState = state.replacingOccurrences(of: tokenizer.maskToken, with: " ")
        let stateIDs = tokenizer.encodeWithoutSpecialTokens(sanitizedState)
        tokenIDs.append(contentsOf: stateIDs.prefix(room))
        tokenIDs.append(tokenizer.separatorTokenID)
        return LayaPreparedInput(tokenIDs: tokenIDs, markerPositions: markers)
    }
}

/// actor 隔离所有 MLXArray/Module 状态，避免未来接入并发业务后让非 Sendable 图逃逸。
actor LayaMLXDecisionRuntime {
    /// 与 laya-mlx 默认 batch size 对齐；限制峰值内存，较大问题集分块执行。
    private static let maximumBatchSize = 16

    private let modelDirectory: URL
    private let precision: LayaMLXPrecision

    private var model: LayaMLXDecisionModel?
    private var tokenizer: (any LayaTokenizing)?
    private var promptBuilder: LayaPromptBuilder?
    private var calibration: LayaTemperatureCalibration?

    private init(modelDirectory: URL, precision: LayaMLXPrecision) {
        self.modelDirectory = modelDirectory
        self.precision = precision
    }

    /// 从 laya-mlx 目录加载并严格校验全部权重；方法返回时模型已 materialize。
    static func load(
        from modelDirectory: URL,
        precision: LayaMLXPrecision = .float16
    ) async throws -> LayaMLXDecisionRuntime {
        let runtime = LayaMLXDecisionRuntime(
            modelDirectory: modelDirectory,
            precision: precision
        )
        try await runtime.prepare()
        return runtime
    }

    /// 对共享 state 的混合题型分块推理。
    ///
    /// Dictionary 先按 question id 排序，保证 batch 编排稳定；返回仍以 id 为键，
    /// 调用方不依赖模型输出顺序。每个 chunk 独立 padding，避免 150 个标签被最长输入
    /// 拖成一个超大张量。
    func predictBatch(
        state: String,
        questions: [String: LayaTextQuestion]
    ) throws -> [String: LayaPrediction] {
        guard
            let model,
            let tokenizer,
            let promptBuilder,
            let calibration
        else {
            throw LayaMLXDecisionError.runtimeNotLoaded
        }
        guard !questions.isEmpty else { return [:] }

        let batchSize = Self.maximumBatchSize
        let ordered = try questions.sorted { $0.key < $1.key }.map { question in
            (
                id: question.key,
                question: question.value,
                input: try promptBuilder.build(
                    state: state,
                    question: question.value,
                    tokenizer: tokenizer
                )
            )
        }
        var predictions: [String: LayaPrediction] = [:]
        predictions.reserveCapacity(ordered.count)

        for start in stride(from: 0, to: ordered.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, ordered.count)
            let chunk = Array(ordered[start..<end])
            let paddedLength = chunk.map { $0.input.tokenIDs.count }.max() ?? 0
            let paddedMarkers = chunk.map { $0.input.markerPositions.count }.max() ?? 0

            var flatTokenIDs: [Int32] = []
            var flatAttentionMask: [Bool] = []
            var flatMarkerPositions: [Int32] = []
            var flatMarkerMask: [Bool] = []
            flatTokenIDs.reserveCapacity(chunk.count * paddedLength)
            flatAttentionMask.reserveCapacity(chunk.count * paddedLength)
            flatMarkerPositions.reserveCapacity(chunk.count * paddedMarkers)

            for item in chunk {
                let inputLength = item.input.tokenIDs.count
                flatTokenIDs.append(contentsOf: item.input.tokenIDs.map(Int32.init))
                flatTokenIDs.append(contentsOf: repeatElement(
                    Int32(tokenizer.paddingTokenID),
                    count: paddedLength - inputLength
                ))
                flatAttentionMask.append(contentsOf: repeatElement(true, count: inputLength))
                flatAttentionMask.append(contentsOf: repeatElement(
                    false,
                    count: paddedLength - inputLength
                ))
                let count = item.input.markerPositions.count
                flatMarkerPositions.append(contentsOf: item.input.markerPositions.map(Int32.init))
                // Gather 安全位置以补齐张量。解码仅取本题真实 marker，填充值不参与归一化。
                flatMarkerPositions.append(contentsOf: repeatElement(0, count: paddedMarkers - count))
                flatMarkerMask.append(contentsOf: repeatElement(true, count: count))
                flatMarkerMask.append(contentsOf: repeatElement(false, count: paddedMarkers - count))
            }

            let output = model.optionLogits(
                tokenIDs: MLXArray(flatTokenIDs).reshaped(chunk.count, paddedLength),
                attentionMask: MLXArray(flatAttentionMask).reshaped(chunk.count, paddedLength),
                questionTypes: MLXArray(chunk.map { $0.question.kind.rawValue }),
                markerPositions: MLXArray(flatMarkerPositions).reshaped(chunk.count, paddedMarkers),
                markerMask: MLXArray(flatMarkerMask).reshaped(chunk.count, paddedMarkers)
            )
            eval(output)

            for (index, item) in chunk.enumerated() {
                let count = item.input.markerPositions.count
                let logits = Array(output[index].asArray(Float.self).prefix(count))
                let answer = try item.question.answer(
                    logits: logits,
                    temperature: calibration.temperature(kind: item.question.kind, count: count)
                )
                predictions[item.id] = LayaPrediction(
                    answer: answer,
                    logits: logits,
                    inputTokenCount: item.input.tokenIDs.count
                )
            }
        }
        return predictions
    }

    /// 先解析轻量配置/tokenizer，再构造网络和加载大权重；整个过程留在 actor 内。
    private func prepare() async throws {
        let paths = CheckpointPaths(root: modelDirectory)
        for required in paths.requiredFiles where !FileManager.default.fileExists(atPath: required.path) {
            throw LayaMLXDecisionError.incompleteCheckpoint(required.path)
        }

        let encoderFile = try Self.decode(EncoderConfigurationFile.self, from: paths.encoderConfig)
        let encoderConfiguration = try encoderFile.validated()
        let agentFile = try Self.decode(AgentConfigurationFile.self, from: paths.agentConfig)
        let agentConfiguration = try agentFile.validated(
            maximumPositionEmbeddings: encoderConfiguration.maxPositionEmbeddings
        )
        let specialTokens = try Self.decode(
            TokenizerConfigurationFile.self,
            from: paths.tokenizerConfig
        )
        let upstreamTokenizer = try await AutoTokenizer.from(modelFolder: paths.tokenizerDirectory)
        let tokenizer = try LayaTokenizerAdapter(
            tokenizer: upstreamTokenizer,
            configuration: specialTokens
        )

        let model = LayaMLXDecisionModel(
            encoderConfiguration: encoderConfiguration,
            headLayerCount: agentConfiguration.headLayerCount,
            actionCostCount: agentConfiguration.actionCostCount
        )
        let rawWeights = try MLX.loadArrays(url: paths.weights)
        let weights = rawWeights.mapValues { $0.asType(precision.dataType) }
        try model.update(
            parameters: ModuleParameters.unflattened(weights),
            verify: [.all]
        )
        // 严格加载后立即求值，避免首个业务请求同时承担 644 MB 权重 materialize。
        eval(model)

        self.model = model
        self.tokenizer = tokenizer
        promptBuilder = LayaPromptBuilder(
            maximumLength: agentConfiguration.maximumLength,
            headMaximumLength: agentConfiguration.headMaximumLength
        )
        calibration = agentConfiguration.calibration
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

private extension LayaTokenizerAdapter {
    init(
        tokenizer: any Tokenizer,
        configuration: TokenizerConfigurationFile
    ) throws {
        func token(_ value: FlexibleToken, named name: String) throws -> (String, Int) {
            guard let id = tokenizer.convertTokenToId(value.content) else {
                throw LayaMLXDecisionError.invalidTokenizer(
                    "tokenizer_config.json 的 \(name)=\(value.content) 不在 tokenizer.json 中"
                )
            }
            return (value.content, id)
        }

        let classToken = try token(configuration.classToken, named: "cls_token")
        let separatorToken = try token(configuration.separatorToken, named: "sep_token")
        let paddingToken = try token(configuration.paddingToken, named: "pad_token")
        let maskToken = try token(configuration.maskToken, named: "mask_token")
        self.init(
            tokenizer: tokenizer,
            classTokenID: classToken.1,
            separatorTokenID: separatorToken.1,
            paddingTokenID: paddingToken.1,
            maskToken: maskToken.0,
            maskTokenID: maskToken.1
        )
    }
}

/// checkpoint 固定目录布局；集中声明可避免 runtime 各处拼接不一致。
private struct CheckpointPaths {
    let root: URL

    var weights: URL { root.appendingPathComponent("model.safetensors") }
    var agentConfig: URL { root.appendingPathComponent("rl_agent_config.json") }
    var encoderConfig: URL { root.appendingPathComponent("encoder/config.json") }
    var tokenizerDirectory: URL { root.appendingPathComponent("tokenizer", isDirectory: true) }
    var tokenizerJSON: URL { tokenizerDirectory.appendingPathComponent("tokenizer.json") }
    var tokenizerConfig: URL { tokenizerDirectory.appendingPathComponent("tokenizer_config.json") }

    var requiredFiles: [URL] {
        [weights, agentConfig, encoderConfig, tokenizerJSON, tokenizerConfig]
    }
}

/// encoder/config.json 的宽松读取模型；兼容字段由 `validated()` 收口。
private struct EncoderConfigurationFile: Decodable {
    struct RopeParameters: Decodable {
        let ropeTheta: Float?
        let ropeType: String?
    }

    let vocabSize: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let modelType: String?
    let normEps: Float?
    let layerNormEps: Float?
    let normBias: Bool?
    let attentionBias: Bool?
    let mlpBias: Bool?
    let hiddenActivation: String?
    let localAttention: Int?
    let globalAttnEveryNLayers: Int?
    let globalRopeTheta: Float?
    let localRopeTheta: Float?
    let maxPositionEmbeddings: Int?
    let layerTypes: [String]?
    let ropeParameters: [String: RopeParameters]?

    func validated() throws -> LayaEncoderConfiguration {
        guard modelType ?? "modernbert" == "modernbert" else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "仅支持 modernbert encoder，实际为 \(modelType ?? "nil")"
            )
        }
        guard hiddenActivation ?? "gelu" == "gelu" else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "仅支持 gelu encoder activation"
            )
        }
        guard
            vocabSize > 0,
            hiddenSize > 0,
            intermediateSize > 0,
            numHiddenLayers > 0,
            numAttentionHeads > 0,
            hiddenSize.isMultiple(of: numAttentionHeads),
            (hiddenSize / numAttentionHeads).isMultiple(of: 2)
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "ModernBERT dimensions/head count 非法"
            )
        }
        let globalEvery = globalAttnEveryNLayers ?? 3
        guard globalEvery > 0 else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "global_attn_every_n_layers 必须大于 0"
            )
        }
        let kinds: [LayaAttentionKind]
        if let layerTypes {
            kinds = try layerTypes.map { raw in
                guard let kind = LayaAttentionKind(rawValue: raw) else {
                    throw LayaMLXDecisionError.invalidConfiguration(
                        "不支持的 layer_type：\(raw)"
                    )
                }
                return kind
            }
        } else {
            kinds = (0..<numHiddenLayers).map {
                $0.isMultiple(of: globalEvery) ? .full : .sliding
            }
        }
        guard kinds.count == numHiddenLayers else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "layer_types 数量与 num_hidden_layers 不一致"
            )
        }

        var ropeBases: [LayaAttentionKind: Float] = [
            .full: globalRopeTheta ?? 160_000,
            .sliding: localRopeTheta ?? 10_000,
        ]
        for kind in [LayaAttentionKind.full, .sliding] {
            if let parameters = ropeParameters?[kind.rawValue] {
                guard parameters.ropeType ?? "default" == "default" else {
                    throw LayaMLXDecisionError.invalidConfiguration(
                        "仅支持 default RoPE，\(kind.rawValue) 使用 \(parameters.ropeType ?? "nil")"
                    )
                }
                if let theta = parameters.ropeTheta {
                    ropeBases[kind] = theta
                }
            }
        }
        let normEpsilon = normEps ?? layerNormEps ?? 1e-5
        let localAttentionWindow = localAttention ?? 128
        let positions = maxPositionEmbeddings ?? 8_192
        guard
            normEpsilon > 0,
            localAttentionWindow > 0,
            positions > 0,
            ropeBases.values.allSatisfy({ $0 > 0 && $0.isFinite })
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "norm/local attention/position/RoPE 参数非法"
            )
        }
        return LayaEncoderConfiguration(
            vocabularySize: vocabSize,
            hiddenSize: hiddenSize,
            intermediateSize: intermediateSize,
            layerCount: numHiddenLayers,
            attentionHeadCount: numAttentionHeads,
            normEpsilon: normEpsilon,
            normBias: normBias ?? false,
            attentionBias: attentionBias ?? false,
            mlpBias: mlpBias ?? false,
            localAttentionWindow: localAttentionWindow,
            maxPositionEmbeddings: positions,
            layerKinds: kinds,
            ropeBases: ropeBases
        )
    }
}

/// rl_agent_config.json 的读取模型；只消费构网、长度和温度校准字段。
private struct AgentConfigurationFile: Decodable {
    let encoder: String?
    let headLayers: Int?
    let maxLen: Int?
    let headMaxLen: Int?
    let actCosts: [String: Double]?
    let temperature: [Double]?
    let temperatureByOptions: [String: Double]?

    func validated(maximumPositionEmbeddings: Int) throws -> ValidatedAgentConfiguration {
        guard encoder?.isEmpty == false, let headLayers, headLayers > 0 else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "rl_agent_config.json 必须声明 encoder 和正数 head_layers"
            )
        }
        let maximumLength = maxLen ?? 512
        let headMaximumLength = headMaxLen ?? 192
        guard
            4 < headMaximumLength,
            headMaximumLength < maximumLength,
            maximumLength <= maximumPositionEmbeddings
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "应满足 4 < head_max_len < max_len <= max_position_embeddings"
            )
        }

        let temperatures = temperature ?? [1, 1, 1]
        let optionTemperatures = temperatureByOptions ?? [:]
        let allTemperatures = temperatures + Array(optionTemperatures.values)
        guard
            temperatures.count == 3,
            allTemperatures.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            throw LayaMLXDecisionError.invalidConfiguration(
                "calibration temperature 必须包含三个有限正数"
            )
        }
        return ValidatedAgentConfiguration(
            headLayerCount: headLayers,
            maximumLength: maximumLength,
            headMaximumLength: headMaximumLength,
            actionCostCount: actCosts?.count ?? 0,
            calibration: LayaTemperatureCalibration(base: temperatures, byOptions: optionTemperatures)
        )
    }
}

private struct ValidatedAgentConfiguration: Sendable {
    let headLayerCount: Int
    let maximumLength: Int
    let headMaximumLength: Int
    let actionCostCount: Int
    let calibration: LayaTemperatureCalibration
}

/// checkpoint 优先按题型与选项数量校准，其次使用该题型的通用温度。
struct LayaTemperatureCalibration: Sendable {
    let base: [Double]
    let byOptions: [String: Double]

    func temperature(kind: LayaTextQuestion.Kind, count: Int) -> Double {
        let bucket: String = switch count {
        case ...2: "2"
        case 3...5: "3-5"
        case 6...10: "6-10"
        default: "11+"
        }
        let raw = byOptions["\(kind.name):\(bucket)"] ?? base[Int(kind.rawValue)]
        return min(5, max(0.5, raw))
    }
}

/// tokenizer_config 的特殊 token 既可能是字符串，也可能是 `{ "content": ... }`。
private struct FlexibleToken: Decodable {
    let content: String

    private enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: any Swift.Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let string = try? single.decode(String.self) {
            content = string
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        content = try object.decode(String.self, forKey: .content)
    }
}

private struct TokenizerConfigurationFile: Decodable {
    let classToken: FlexibleToken
    let separatorToken: FlexibleToken
    let paddingToken: FlexibleToken
    let maskToken: FlexibleToken

    private enum CodingKeys: String, CodingKey {
        case classToken = "clsToken"
        case separatorToken = "sepToken"
        case paddingToken = "padToken"
        case maskToken
    }
}
