//
//  LocalAIModelCatalogTests.swift
//  StarcatTests
//
//  内置模型目录的契约测试：唯一性、能力标签、reranker 命名约定（RerankerModelFactory
//  的 verified-naming 依赖目录名包含 "rerank"）。
//

import Foundation
import Testing
@testable import Starcat

@Suite("LocalAIModelCatalog")
struct LocalAIModelCatalogTests {

    @Test("entry id 唯一且非空")
    func uniqueIDs() {
        let ids = LocalAIModelCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { !$0.isEmpty })
    }

    @Test("每类至少有一个推荐模型，且推荐项唯一")
    func recommendedPerType() {
        for type in LocalAIModelType.allCases {
            let entries = LocalAIModelCatalog.entries.filter { $0.type == type }
            #expect(!entries.isEmpty)
            #expect(entries.filter(\.recommended).count == 1)
        }
    }

    @Test("capability 与类型对齐")
    func capabilityMapping() {
        for entry in LocalAIModelCatalog.entries {
            switch entry.type {
            case .embedding:
                #expect(entry.capability == .embedding)
                #expect(entry.embeddingDimension != nil)
            case .llm:
                #expect(entry.capability == .chat)
            case .reranker:
                #expect(entry.capability == .rerank)
            }
        }
    }

    @Test("reranker 目录命名满足 RerankerModelFactory verified-naming")
    func rerankerVerifiedNaming() {
        for entry in LocalAIModelCatalog.entries where entry.type == .reranker {
            #expect(LocalAIModelCatalog.usesRerankerVerifiedNaming(entry.id))
        }
    }

    @Test("预估体积与必填文件集非空")
    func sizesAndFiles() {
        for entry in LocalAIModelCatalog.entries {
            #expect(entry.estimatedDownloadSize > 0)
            #expect(entry.memoryRecommendation > 0)
            #expect(entry.files.contains(.required("config.json")))
            #expect(entry.files.contains { $0.isRequired && $0.name.hasSuffix(".safetensors") })
            #expect(!entry.sources.isEmpty)
            #expect(entry.source(for: .huggingFace) != nil)
        }
    }

    @Test("ModelScope 仅收录已验证镜像")
    func modelScopeWhitelist() {
        // 2026-09-12 全量核验：12 个模型在 HF 与魔塔均有可用仓库；大多数来自
        // mlx-community，MiniCPM5 使用 OpenBMB 官方双源仓库。
        for entry in LocalAIModelCatalog.entries where entry.id != LocalAIModelCatalog.llmDefiantFable.id {
            #expect(entry.isAvailable(on: .modelScope), "\(entry.id) 应有魔塔镜像")
            #expect(entry.isAvailable(on: .huggingFace), "\(entry.id) 应有 HF 仓库")
        }
    }

    @Test("Defiant Fable 固定 Hugging Face 版本并安装双分片与独立模板")
    func defiantFableContract() throws {
        let entry = try #require(LocalAIModelCatalog.entry(id: "qwen3.5-9b-defiant-fable-mlx-4bit"))

        #expect(entry.type == .llm)
        #expect(entry.capability == .chat)
        #expect(!entry.recommended)
        #expect(!entry.isLite)
        #expect(entry.sources == [
            LocalAIModelSource(
                kind: .huggingFace,
                repo: "pipenetwork/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-MLX-4bit",
                revision: "99a39b89e05082eecefb02f0dd93e2cd111166c0"),
        ])
        #expect(entry.files == [
            .required("config.json"),
            .required("tokenizer.json"),
            .required("tokenizer_config.json"),
            .required("chat_template.jinja"),
            .required("model.safetensors.index.json"),
            .required("model-00001-of-00002.safetensors"),
            .required("model-00002-of-00002.safetensors"),
            .optional("generation_config.json"),
        ])
    }

    @Test("MiniCPM5 使用官方双源并携带独立聊天模板")
    func miniCPM5Contract() throws {
        let entry = try #require(LocalAIModelCatalog.entry(id: "minicpm5-2b-mlx-4bit"))

        #expect(entry.displayName == "MiniCPM5 2B 4bit")
        #expect(entry.type == .llm)
        #expect(entry.capability == .chat)
        #expect(entry.contextLength == 131_072)
        #expect(entry.source(for: .huggingFace)?.repo == "openbmb/MiniCPM5-2B-MLX")
        #expect(entry.source(for: .modelScope)?.repo == "OpenBMB/MiniCPM5-2B-MLX")
        #expect(entry.files.contains { $0.name == "chat_template.jinja" && $0.isRequired })
    }

    @Test("内置 profile id 与 catalog 解析稳定")
    func builtInProfileIDLookup() {
        #expect(LocalAIModelCatalog.builtInProfileID == "built-in.local-ai")
        #expect(LocalAIModelCatalog.entry(id: "qwen3-embedding-0.6b-8bit") != nil)
        #expect(LocalAIModelCatalog.entry(id: "not-exist") == nil)
    }
}
