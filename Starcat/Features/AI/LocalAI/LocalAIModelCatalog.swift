//
//  LocalAIModelCatalog.swift
//  Starcat
//
//  本地 AI 内置模型目录（编译期常量）。
//
//  设计：
//  - 普通用户不接触 HF / ModelScope Repo ID，只面对「推荐 / 轻量」档 Starcat Model；
//    UI 文案不暴露 FP16 / 4bit / 8bit / MXFP8 等量化概念（displayName 的量化后缀
//    仅用于同系列多权重间的区分，统一小写风格）。
//  - 目录只收录**逐个人工验证过**的仓库（2026-09-12 核验）：HF 仓库必须 API 可达
//    （401/404 视为不存在），ModelScope 镜像必须 API `Code:200`。未验证的组合不入册
//    ——下载源选了 ModelScope 而某模型没有镜像时，该模型显示「暂未收录」。
//  - ModelScope 镜像为社区同步（master 分支），revision 记录为 master 快照；
//    HF 优先使用目录固定的 commit SHA，未固定时在安装时解析。
//  - 2026-09-12 二轮扩充：Embedding 4 / Reranker 3 / LLM 5（Qwen3.5、MiniCPM5 已入册）。
//    Nemotron-3-Embed（model_type ministral3）上游 registry 不支持，未收录；
//    jina-reranker-v3 为 CC BY-NC 非商业许可，未收录；Qwen3-VL-Reranker 为
//    视觉语言架构，文本管线暂不支持。12 个模型均已核验 HF + ModelScope 双源。
//  - 换默认模型 = 改这里，业务层无感。
//

import Foundation

/// 本地模型类型。与 `AIModelCapability` 对齐映射，见 `LocalAIModelCatalogEntry.capability`。
enum LocalAIModelType: String, Codable, Sendable, CaseIterable, Identifiable {
    case embedding
    case reranker
    case llm

    var id: String { rawValue }

    /// 安装目录 / 存储子目录名。
    var storagePathComponent: String {
        switch self {
        case .embedding: return "embedding"
        case .reranker: return "reranker"
        case .llm: return "llm"
        }
    }

    /// 分类行与模型能力共享图标，保留非向量模型的原生 SF 图形。
    var iconSource: BusinessIcon.Source {
        switch self {
        case .embedding: return AIModelCapability.embedding.iconSource
        case .reranker: return .system("arrow.up.arrow.down")
        case .llm: return .system("bubble.left.and.text.bubble.right")
        }
    }
}

/// 模型下载源。
struct LocalAIModelSource: Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case huggingFace
        case modelScope

        var id: String { rawValue }
    }

    var kind: Kind
    /// 模型仓库标识，如 `mlx-community/Qwen3-Embedding-0.6B-8bit`。
    var repo: String
    /// 固定 revision；nil = 安装时解析（HF 解析 main 的 commit SHA，ModelScope 固定 master）。
    var revision: String?
}

/// 待下载文件。`isRequired == false` 的文件（如 generation_config.json）404 时跳过。
struct LocalAIModelFile: Sendable, Equatable {
    var name: String
    var isRequired: Bool

    static func required(_ name: String) -> LocalAIModelFile { .init(name: name, isRequired: true) }
    static func optional(_ name: String) -> LocalAIModelFile { .init(name: name, isRequired: false) }
}

/// Catalog 单条记录。
struct LocalAIModelCatalogEntry: Identifiable, Sendable, Equatable {
    /// 稳定短 id（用于存储目录名 / 下载状态 key），如 `qwen3-embedding-0.6b-8bit`。
    let id: String
    let displayName: String
    let type: LocalAIModelType
    /// 下发到 `AIProviderProfile.models` 的能力标签。
    let capability: AIModelCapability
    /// true = 「推荐」档；每类恰好一个。
    let recommended: Bool
    /// true = 「轻量」档（小体积 / 低内存机型友好）；与 recommended 互斥展示。
    let isLite: Bool
    /// 下载体积预估（字节），用于 UI 展示与磁盘预检。
    let estimatedDownloadSize: Int64
    /// 运行内存建议（字节），安装前提示。
    let memoryRecommendation: UInt64
    let contextLength: Int?
    /// embedding 专用：向量维度（写入 `repo_embeddings.dimensions` 口径）。
    let embeddingDimension: Int?
    /// 可用下载源。至少一项；按数组顺序视为优先级。
    let sources: [LocalAIModelSource]
    let files: [LocalAIModelFile]

    func source(for kind: LocalAIModelSource.Kind) -> LocalAIModelSource? {
        sources.first { $0.kind == kind }
    }

    /// 该模型是否在指定下载源可用。
    func isAvailable(on kind: LocalAIModelSource.Kind) -> Bool {
        source(for: kind) != nil
    }
}

enum LocalAIModelCatalog {

    /// 内置本地 AI profile 的固定 id。seed-if-missing，用户不可删除。
    static let builtInProfileID = "built-in.local-ai"

    private static let mlxConfigFiles: [LocalAIModelFile] = [
        .required("config.json"),
        .required("model.safetensors"),
        .required("tokenizer.json"),
        .required("tokenizer_config.json"),
        .optional("special_tokens_map.json"),
    ]

    private static let llmConfigFiles: [LocalAIModelFile] = [
        .required("config.json"),
        .required("model.safetensors"),
        .required("tokenizer.json"),
        .required("tokenizer_config.json"),
        .optional("generation_config.json"),
        .optional("special_tokens_map.json"),
    ]

    // MARK: - Embedding（3）

    static let embedding = LocalAIModelCatalogEntry(
        id: "qwen3-embedding-0.6b-8bit",
        displayName: "Qwen3 Embedding 0.6B 8bit",
        type: .embedding,
        capability: .embedding,
        recommended: true,
        isLite: false,
        estimatedDownloadSize: 664_000_000,
        memoryRecommendation: 1_200_000_000,
        contextLength: 32_768,
        embeddingDimension: 1024,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Embedding-0.6B-8bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-Embedding-0.6B-8bit", revision: nil),
        ],
        files: mlxConfigFiles)

    /// LFM2.5 350M（8bit）：11 语言、CLS 池化 1024 维；上游 mlx-swift-lm 原生支持 lfm2 架构。
    static let embeddingLFM8bit = LocalAIModelCatalogEntry(
        id: "lfm2.5-embedding-350m-8bit",
        displayName: "LFM2.5 Embedding 350M 8bit",
        type: .embedding,
        capability: .embedding,
        recommended: false,
        isLite: false,
        estimatedDownloadSize: 390_000_000,
        memoryRecommendation: 800_000_000,
        contextLength: nil,
        embeddingDimension: 1024,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/LFM2.5-Embedding-350M-8bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/LFM2.5-Embedding-350M-8bit", revision: nil),
        ],
        files: mlxConfigFiles)

    static let embeddingLFM4bit = LocalAIModelCatalogEntry(
        id: "lfm2.5-embedding-350m-4bit",
        displayName: "LFM2.5 Embedding 350M 4bit",
        type: .embedding,
        capability: .embedding,
        recommended: false,
        isLite: true,
        estimatedDownloadSize: 210_000_000,
        memoryRecommendation: 600_000_000,
        contextLength: nil,
        embeddingDimension: 1024,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/LFM2.5-Embedding-350M-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/LFM2.5-Embedding-350M-4bit", revision: nil),
        ],
        files: mlxConfigFiles)

    static let embeddingGemma = LocalAIModelCatalogEntry(
        id: "embeddinggemma-300m-4bit",
        displayName: "EmbeddingGemma 300M 4bit",
        type: .embedding,
        capability: .embedding,
        recommended: false,
        isLite: true,
        estimatedDownloadSize: 215_000_000,
        memoryRecommendation: 600_000_000,
        contextLength: 2_048,
        embeddingDimension: 768,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/embeddinggemma-300m-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/embeddinggemma-300m-4bit", revision: nil),
        ],
        files: mlxConfigFiles)

    // MARK: - Reranker（2；上游可核验的只有这两个）

    static let reranker = LocalAIModelCatalogEntry(
        id: "qwen3-reranker-0.6b-4bit",
        displayName: "Qwen3 Reranker 0.6B 4bit",
        type: .reranker,
        capability: .rerank,
        recommended: true,
        isLite: false,
        estimatedDownloadSize: 350_000_000,
        memoryRecommendation: 1_000_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Reranker-0.6B-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-Reranker-0.6B-4bit", revision: nil),
        ],
        files: mlxConfigFiles)

    static let rerankerMXFP8 = LocalAIModelCatalogEntry(
        id: "qwen3-reranker-0.6b-mxfp8",
        displayName: "Qwen3 Reranker 0.6B mxfp8",
        type: .reranker,
        capability: .rerank,
        recommended: false,
        isLite: false,
        estimatedDownloadSize: 645_000_000,
        memoryRecommendation: 1_200_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Reranker-0.6B-mxfp8", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-Reranker-0.6B-mxfp8", revision: nil),
        ],
        files: mlxConfigFiles)

    static let reranker4B = LocalAIModelCatalogEntry(
        id: "qwen3-reranker-4b-mxfp8",
        displayName: "Qwen3 Reranker 4B mxfp8",
        type: .reranker,
        capability: .rerank,
        recommended: false,
        isLite: false,
        estimatedDownloadSize: 4_200_000_000,
        memoryRecommendation: 7_000_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Reranker-4B-mxfp8", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-Reranker-4B-mxfp8", revision: nil),
        ],
        files: mlxConfigFiles)

    // MARK: - LLM（6）

    /// 最新一代推荐：Qwen3.5 4B（mlx-swift-lm 锁定版本原生支持 Qwen3_5 架构）。
    static let llm = LocalAIModelCatalogEntry(
        id: "qwen3.5-4b-mlx-4bit",
        displayName: "Qwen3.5 4B 4bit",
        type: .llm,
        capability: .chat,
        recommended: true,
        isLite: false,
        estimatedDownloadSize: 3_100_000_000,
        memoryRecommendation: 5_500_000_000,
        contextLength: nil,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3.5-4B-MLX-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3.5-4B-MLX-4bit", revision: nil),
        ],
        files: llmConfigFiles)

    /// 上一代 4B：Qwen3.5 出问题时的稳妥回退（双源已长期验证）。
    static let llmQwen3_4B = LocalAIModelCatalogEntry(
        id: "qwen3-4b-instruct-2507-4bit",
        displayName: "Qwen3 4B Instruct 4bit",
        type: .llm,
        capability: .chat,
        recommended: false,
        isLite: false,
        estimatedDownloadSize: 2_500_000_000,
        memoryRecommendation: 4_000_000_000,
        contextLength: 262_144,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: nil),
        ],
        files: llmConfigFiles)

    /// MiniCPM5 2B：标准 LlamaForCausalLM 架构，面向 Apple Silicon 的官方 4bit 权重。
    ///
    /// 上游把聊天模板放在独立的 `chat_template.jinja`，未嵌入 tokenizer_config.json；
    /// 该文件必须随模型安装，否则 swift-transformers 无法构造多轮对话输入。
    static let llmMiniCPM5 = LocalAIModelCatalogEntry(
        id: "minicpm5-2b-mlx-4bit",
        displayName: "MiniCPM5 2B 4bit",
        type: .llm,
        capability: .chat,
        recommended: false,
        isLite: false,
        estimatedDownloadSize: 1_430_000_000,
        memoryRecommendation: 3_000_000_000,
        contextLength: 131_072,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "openbmb/MiniCPM5-2B-MLX", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "OpenBMB/MiniCPM5-2B-MLX", revision: nil),
        ],
        files: llmConfigFiles + [.required("chat_template.jinja")])

    /// Defiant Fable 9B 的社区 MLX 转换版。固定 revision 以匹配已验证的分片与独立聊天模板。
    /// ModelScope 尚无已验证镜像，沿用设置页的下载源可用性判断。
    static let llmDefiantFable = LocalAIModelCatalogEntry(
        id: "qwen3.5-9b-defiant-fable-mlx-4bit",
        displayName: "Qwen3.5 9B Defiant Fable 4bit",
        type: .llm,
        capability: .chat,
        recommended: false,
        isLite: false,
        estimatedDownloadSize: 5_970_000_000,
        memoryRecommendation: 7_000_000_000,
        contextLength: nil,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(
                kind: .huggingFace,
                repo: "pipenetwork/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-MLX-4bit",
                revision: "99a39b89e05082eecefb02f0dd93e2cd111166c0"),
        ],
        files: [
            .required("config.json"),
            .required("tokenizer.json"),
            .required("tokenizer_config.json"),
            .required("chat_template.jinja"),
            .required("model.safetensors.index.json"),
            .required("model-00001-of-00002.safetensors"),
            .required("model-00002-of-00002.safetensors"),
            .optional("generation_config.json"),
        ])

    static let llmQwen35Lite = LocalAIModelCatalogEntry(
        id: "qwen3.5-0.8b-mlx-4bit",
        displayName: "Qwen3.5 0.8B 4bit",
        type: .llm,
        capability: .chat,
        recommended: false,
        isLite: true,
        estimatedDownloadSize: 650_000_000,
        memoryRecommendation: 1_600_000_000,
        contextLength: nil,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3.5-0.8B-MLX-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3.5-0.8B-MLX-4bit", revision: nil),
        ],
        files: llmConfigFiles)

    static let llmLite = LocalAIModelCatalogEntry(
        id: "qwen3-1.7b-4bit",
        displayName: "Qwen3 1.7B 4bit",
        type: .llm,
        capability: .chat,
        recommended: false,
        isLite: true,
        estimatedDownloadSize: 1_100_000_000,
        memoryRecommendation: 2_200_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-1.7B-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-1.7B-4bit", revision: nil),
        ],
        files: llmConfigFiles)

    /// 全部目录项。顺序即下拉顺序（推荐在前）。
    static let entries: [LocalAIModelCatalogEntry] = [
        embedding,
        embeddingGemma,
        embeddingLFM8bit,
        embeddingLFM4bit,
        reranker,
        rerankerMXFP8,
        reranker4B,
        llm,
        llmQwen3_4B,
        llmMiniCPM5,
        llmDefiantFable,
        llmQwen35Lite,
        llmLite,
    ]

    static func entry(id: String) -> LocalAIModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// 某类别下的目录项（设置页分组下拉的顺序 = 数组顺序，推荐在前）。
    static func entries(of type: LocalAIModelType) -> [LocalAIModelCatalogEntry] {
        entries.filter { $0.type == type }
    }

    /// Catalog 内 repo 名是否声明为 reranker。`RerankerModelFactory` 依赖
    /// repo / 目录名包含 "rerank" 才肯加载 Qwen3 判别式权重，目录命名必须保持该约定。
    static func usesRerankerVerifiedNaming(_ id: String) -> Bool {
        id.localizedCaseInsensitiveContains("rerank")
    }
}
