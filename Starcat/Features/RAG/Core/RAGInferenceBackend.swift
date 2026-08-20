//
//  RAGInferenceBackend.swift
//  Starcat
//
//  知识库 RAG 的文本推理后端选择。这里只描述 Planner / Generator 使用哪条推理链，
//  不影响 Embedding、Rerank、README 翻译、笔记或其它 AI 功能。
//

import Foundation

/// RAG 文本推理后端。
///
/// `.codexCLI` / `.claudeCLI` 都属于 Direct-only 外部工具桥接。本枚举可以落盘，但真正
/// 创建进程前仍必须经过 `DistributionGate`，不能把 UI 隐藏当成安全边界。
enum RAGInferenceBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case api
    case codexCLI
    case claudeCLI

    var id: String { rawValue }

    var isCLI: Bool { self != .api }

    /// CLI 自己决定实际模型；该标识只用于 RAG 会话、Debug 和错误诊断，不发送给 API。
    var runtimeModelName: String {
        switch self {
        case .api: return "api"
        case .codexCLI: return "codex-cli"
        case .claudeCLI: return "claude-code-cli"
        }
    }

    var titleKey: String {
        switch self {
        case .api: return "rag.workspace.inference.backend.api"
        case .codexCLI: return "rag.workspace.inference.backend.codex"
        case .claudeCLI: return "rag.workspace.inference.backend.claude"
        }
    }

    var hintKey: String {
        switch self {
        case .api: return "rag.workspace.inference.backend.api.hint"
        case .codexCLI: return "rag.workspace.inference.backend.codex.hint"
        case .claudeCLI: return "rag.workspace.inference.backend.claude.hint"
        }
    }

    var systemImage: String {
        switch self {
        case .api: return "network"
        case .codexCLI: return "terminal"
        case .claudeCLI: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 未安装时只打开官方说明，不在 Starcat 内执行 npm / curl 等安装命令。
    var installationURL: URL? {
        switch self {
        case .api:
            return nil
        case .codexCLI:
            return URL(string: "https://help.openai.com/en/articles/11096431")
        case .claudeCLI:
            return URL(string: "https://docs.anthropic.com/en/docs/claude-code/getting-started")
        }
    }

    static func available(using distributionGate: DistributionGate) -> [RAGInferenceBackend] {
        guard distributionGate.isAvailable(.externalToolBridge) else { return [.api] }
        return allCases
    }
}
