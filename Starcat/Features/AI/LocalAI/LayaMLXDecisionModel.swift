//
//  LayaMLXDecisionModel.swift
//  Starcat
//
//  Laya 社区 MLX checkpoint 的 Swift 网络结构。这里刻意完整声明 encoder、
//  Decision Transformer、scorer 与 action head，使 safetensors 可以严格校验加载；
//  当前业务入口只读取 Noul logits，不把尚未验证的 action 输出暴露给 Starcat。
//


import MLX
import MLXNN

/// ModernBERT 每层采用的注意力范围，raw value 与 checkpoint 配置保持一致。
enum LayaAttentionKind: String, Sendable {
    case full = "full_attention"
    case sliding = "sliding_attention"
}

/// 已校验、可直接构造 MLX 网络的 encoder 配置。
struct LayaEncoderConfiguration: Sendable {
    let vocabularySize: Int
    let hiddenSize: Int
    let intermediateSize: Int
    let layerCount: Int
    let attentionHeadCount: Int
    let normEpsilon: Float
    let normBias: Bool
    let attentionBias: Bool
    let mlpBias: Bool
    let localAttentionWindow: Int
    let maxPositionEmbeddings: Int
    let layerKinds: [LayaAttentionKind]
    let ropeBases: [LayaAttentionKind: Float]

    var attentionHeadSize: Int { hiddenSize / attentionHeadCount }

    func ropeBase(for kind: LayaAttentionKind) -> Float {
        // 配置校验会保证两种 kind 均有值；fallback 只保护未来手工构造的测试配置。
        ropeBases[kind] ?? 10_000
    }
}

/// token embedding + LayerNorm，对应 `encoder.embeddings.*`。
private final class LayaEncoderEmbeddings: Module {
    @ModuleInfo(key: "tok_embeddings") private var tokenEmbedding: Embedding
    @ModuleInfo private var norm: LayerNorm

    init(configuration: LayaEncoderConfiguration) {
        _tokenEmbedding.wrappedValue = Embedding(
            embeddingCount: configuration.vocabularySize,
            dimensions: configuration.hiddenSize
        )
        _norm.wrappedValue = LayerNorm(
            dimensions: configuration.hiddenSize,
            eps: configuration.normEpsilon,
            bias: configuration.normBias
        )
    }

    func callAsFunction(_ tokenIDs: MLXArray) -> MLXArray {
        norm(tokenEmbedding(tokenIDs))
    }
}

/// ModernBERT self-attention；RoPE base 会随 full/sliding layer 切换。
private final class LayaEncoderAttention: Module {
    @ModuleInfo(key: "Wqkv") private var queryKeyValue: Linear
    @ModuleInfo(key: "Wo") private var output: Linear

    private let headCount: Int
    private let headSize: Int
    private let rope: RoPE

    init(configuration: LayaEncoderConfiguration, kind: LayaAttentionKind) {
        headCount = configuration.attentionHeadCount
        headSize = configuration.attentionHeadSize
        rope = RoPE(
            dimensions: configuration.attentionHeadSize,
            traditional: false,
            base: configuration.ropeBase(for: kind),
            scale: 1
        )
        _queryKeyValue.wrappedValue = Linear(
            configuration.hiddenSize,
            3 * configuration.hiddenSize,
            bias: configuration.attentionBias
        )
        _output.wrappedValue = Linear(
            configuration.hiddenSize,
            configuration.hiddenSize,
            bias: configuration.attentionBias
        )
    }

    /// 输入/输出均为 `[batch, length, hidden]`；mask 使用 MLX 的 true=可见语义。
    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        let batchSize = input.dim(0)
        let length = input.dim(1)
        let projected = queryKeyValue(input).reshaped(
            batchSize, length, 3, headCount, headSize
        )
        let parts = projected.split(parts: 3, axis: 2)
        let queries = rope(parts[0].squeezed(axis: 2).transposed(0, 2, 1, 3))
        let keys = rope(parts[1].squeezed(axis: 2).transposed(0, 2, 1, 3))
        let values = parts[2].squeezed(axis: 2).transposed(0, 2, 1, 3)
        let attended = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: 1 / Float(headSize).squareRoot(),
            mask: mask
        )
        return output(attended.transposed(0, 2, 1, 3).reshaped(batchSize, length, -1))
    }
}

/// ModernBERT gated MLP：`Wo(gelu(value) * gate)`。
private final class LayaEncoderMLP: Module {
    @ModuleInfo(key: "Wi") private var input: Linear
    @ModuleInfo(key: "Wo") private var output: Linear

    init(configuration: LayaEncoderConfiguration) {
        _input.wrappedValue = Linear(
            configuration.hiddenSize,
            2 * configuration.intermediateSize,
            bias: configuration.mlpBias
        )
        _output.wrappedValue = Linear(
            configuration.intermediateSize,
            configuration.hiddenSize,
            bias: configuration.mlpBias
        )
    }

    func callAsFunction(_ value: MLXArray) -> MLXArray {
        let parts = input(value).split(parts: 2, axis: -1)
        return output(gelu(parts[0]) * parts[1])
    }
}

/// 单层 ModernBERT block；第 0 层没有 `attn_norm` 参数，这是严格加载的重要差异。
private final class LayaEncoderLayer: Module {
    @ModuleInfo(key: "attn_norm") private var attentionNorm: LayerNorm?
    @ModuleInfo(key: "attn") private var attention: LayaEncoderAttention
    @ModuleInfo(key: "mlp_norm") private var mlpNorm: LayerNorm
    @ModuleInfo private var mlp: LayaEncoderMLP

    let kind: LayaAttentionKind

    init(configuration: LayaEncoderConfiguration, index: Int) {
        kind = configuration.layerKinds[index]
        if index > 0 {
            _attentionNorm.wrappedValue = LayerNorm(
                dimensions: configuration.hiddenSize,
                eps: configuration.normEpsilon,
                bias: configuration.normBias
            )
        }
        _attention.wrappedValue = LayaEncoderAttention(
            configuration: configuration,
            kind: kind
        )
        _mlpNorm.wrappedValue = LayerNorm(
            dimensions: configuration.hiddenSize,
            eps: configuration.normEpsilon,
            bias: configuration.normBias
        )
        _mlp.wrappedValue = LayaEncoderMLP(configuration: configuration)
    }

    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        let normalized = attentionNorm.map { $0(input) } ?? input
        let attended = input + attention(normalized, mask: mask)
        return attended + mlp(mlpNorm(attended))
    }
}

/// 完整 ModernBERT encoder，对应 checkpoint 的 `encoder.*` 参数树。
private final class LayaModernBERT: Module {
    @ModuleInfo private var embeddings: LayaEncoderEmbeddings
    @ModuleInfo private var layers: [LayaEncoderLayer]
    @ModuleInfo(key: "final_norm") private var finalNorm: LayerNorm

    private let localAttentionWindow: Int

    init(configuration: LayaEncoderConfiguration) {
        localAttentionWindow = configuration.localAttentionWindow
        _embeddings.wrappedValue = LayaEncoderEmbeddings(configuration: configuration)
        _layers.wrappedValue = (0..<configuration.layerCount).map {
            LayaEncoderLayer(configuration: configuration, index: $0)
        }
        _finalNorm.wrappedValue = LayerNorm(
            dimensions: configuration.hiddenSize,
            eps: configuration.normEpsilon,
            bias: configuration.normBias
        )
    }

    func callAsFunction(_ tokenIDs: MLXArray, attentionMask: MLXArray) -> MLXArray {
        var hidden = embeddings(tokenIDs)
        let masks = Self.makeAttentionMasks(
            attentionMask: attentionMask,
            localWindow: localAttentionWindow
        )
        for layer in layers {
            let mask = layer.kind == .full ? masks.full : masks.sliding
            hidden = layer(hidden, mask: mask)
        }
        return finalNorm(hidden)
    }

    /// 复刻 laya-mlx 的 padding 处理：padding query 可见有效 key，避免全 mask softmax。
    private static func makeAttentionMasks(
        attentionMask: MLXArray,
        localWindow: Int
    ) -> (full: MLXArray, sliding: MLXArray) {
        let valid = attentionMask.asType(.bool)
        let full = valid[0..., .newAxis, .newAxis, 0...]
        let positions = MLXArray.arange(valid.dim(1))
        let distance = abs(
            positions[0..., .newAxis] - positions[.newAxis, 0...]
        )
        let local = (distance .<= localWindow / 2)[.newAxis, .newAxis, 0..., 0...]
        let paddingQueries = logicalNot(valid)[0..., .newAxis, 0..., .newAxis]
        return (full, logicalAnd(logicalOr(local, paddingQueries), full))
    }
}

/// Decision Transformer 使用的无位置编码 self-attention。
private final class LayaHeadAttention: Module {
    @ModuleInfo(key: "in_proj") private var inputProjection: Linear
    @ModuleInfo(key: "out_proj") private var outputProjection: Linear

    private let headCount: Int
    private let headSize: Int

    init(dimensions: Int) {
        headCount = max(1, dimensions / 64)
        headSize = dimensions / headCount
        _inputProjection.wrappedValue = Linear(dimensions, 3 * dimensions)
        _outputProjection.wrappedValue = Linear(dimensions, dimensions)
    }

    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        let batchSize = input.dim(0)
        let length = input.dim(1)
        let projected = inputProjection(input).reshaped(
            batchSize, length, 3, headCount, headSize
        )
        let parts = projected.split(parts: 3, axis: 2)
        let queries = parts[0].squeezed(axis: 2).transposed(0, 2, 1, 3)
        let keys = parts[1].squeezed(axis: 2).transposed(0, 2, 1, 3)
        let values = parts[2].squeezed(axis: 2).transposed(0, 2, 1, 3)
        let attended = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: 1 / Float(headSize).squareRoot(),
            mask: mask
        )
        return outputProjection(
            attended.transposed(0, 2, 1, 3).reshaped(batchSize, length, -1)
        )
    }
}

/// Decision Transformer block；FFN 必须使用 ReLU，不能沿用 encoder 的 GELU。
private final class LayaHeadLayer: Module {
    @ModuleInfo(key: "self_attn") private var attention: LayaHeadAttention
    @ModuleInfo private var norm1: LayerNorm
    @ModuleInfo private var norm2: LayerNorm
    @ModuleInfo private var linear1: Linear
    @ModuleInfo private var linear2: Linear

    init(dimensions: Int) {
        _attention.wrappedValue = LayaHeadAttention(dimensions: dimensions)
        _norm1.wrappedValue = LayerNorm(dimensions: dimensions)
        _norm2.wrappedValue = LayerNorm(dimensions: dimensions)
        _linear1.wrappedValue = Linear(dimensions, 4 * dimensions)
        _linear2.wrappedValue = Linear(4 * dimensions, dimensions)
    }

    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        let attended = input + attention(norm1(input), mask: mask)
        return attended + linear2(relu(linear1(norm2(attended))))
    }
}

/// 两层 Decision Transformer 容器，对应 `head.layers.*`。
private final class LayaDecisionHead: Module {
    @ModuleInfo private var layers: [LayaHeadLayer]

    init(dimensions: Int, layerCount: Int) {
        _layers.wrappedValue = (0..<layerCount).map { _ in
            LayaHeadLayer(dimensions: dimensions)
        }
    }

    func callAsFunction(_ input: MLXArray, mask: MLXArray) -> MLXArray {
        layers.reduce(input) { hidden, layer in
            layer(hidden, mask: mask)
        }
    }
}

/// checkpoint 的完整参数容器；文本题型共享 marker scorer。
final class LayaMLXDecisionModel: Module {
    @ModuleInfo private var encoder: LayaModernBERT
    @ModuleInfo private var head: LayaDecisionHead
    @ModuleInfo(key: "type_emb") private var typeEmbedding: Embedding
    @ModuleInfo private var scorer: Sequential
    @ModuleInfo(key: "act_head") private var actionHead: Sequential
    @ParameterInfo private var temperature: MLXArray

    init(
        encoderConfiguration: LayaEncoderConfiguration,
        headLayerCount: Int,
        actionCostCount: Int
    ) {
        let dimensions = encoderConfiguration.hiddenSize
        _encoder.wrappedValue = LayaModernBERT(configuration: encoderConfiguration)
        _head.wrappedValue = LayaDecisionHead(
            dimensions: dimensions,
            layerCount: headLayerCount
        )
        _typeEmbedding.wrappedValue = Embedding(embeddingCount: 3, dimensions: dimensions)
        _scorer.wrappedValue = Sequential {
            LayerNorm(dimensions: dimensions)
            Linear(dimensions, dimensions)
            GELU()
            Linear(dimensions, 1)
        }
        // 即使当前产品不消费 action，仍声明该 head，避免“忽略多余权重”掩盖结构偏差。
        _actionHead.wrappedValue = Sequential {
            Linear(dimensions + 4, 256)
            GELU()
            Linear(256, actionCostCount + 1)
        }
        _temperature.wrappedValue = MLXArray.ones([3])
    }

    /// 为 batch 中每行广播对应题型的 embedding，返回补齐后各 marker 的 logits。
    func optionLogits(
        tokenIDs: MLXArray,
        attentionMask: MLXArray,
        questionTypes: MLXArray,
        markerPositions: MLXArray,
        markerMask: MLXArray
    ) -> MLXArray {
        var hidden = encoder(tokenIDs, attentionMask: attentionMask)
        hidden += typeEmbedding(questionTypes)[0..., .newAxis, 0...]
        hidden = head(
            hidden,
            mask: attentionMask.asType(.bool)[0..., .newAxis, .newAxis, 0...]
        )

        let batchIndices = MLXArray.arange(tokenIDs.dim(0))[0..., .newAxis]
        let safePositions = maximum(markerPositions, 0)
        let markerHidden = hidden[batchIndices, safePositions]
        let logits = scorer(markerHidden).squeezed(axis: -1).asType(.float32)
        return which(markerMask.asType(.bool), logits, -10_000)
    }
}
