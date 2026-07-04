//
//  KnowledgeRAGDemoData.swift
//  Starcat
//
//  知识库 RAG 工作台迁移验证使用的静态数据。
//
//  这些类型只服务当前纯 UI 验证,字段按后续真实 RAG ViewModel 能拿到的数据收敛:
//  repo 元信息来自现有本地库,chunk / section / score 来自未来 rag_chunks 与 Retriever。
//  不放检索内部调试字段,避免 UI 验证阶段误把 demo-only 数据做成产品承诺。
//

import Foundation

struct RAGDemoConversation: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let time: String
    let citationIndex: Int
}

struct RAGDemoRepoBundle: Identifiable {
    let id: String
    let repo: String
    let fullName: String
    let description: String
    let language: String
    let stars: String
    let status: String
    let sources: [String]
    let citationIDs: [String]
    let localDetailAvailable: Bool
}

struct RAGDemoCitation: Identifiable {
    let id: String
    let rank: Int
    let repo: String
    let fullName: String
    let source: String
    let sourceDetail: String
    let sectionPath: String
    let title: String
    let parentTitle: String
    let score: Double
    let snippet: String
    let isTruncated: Bool
    let localDetailAvailable: Bool
    let githubURL: URL
}

enum RAGDemoData {
    static let conversations: [RAGDemoConversation] = [
        .init(id: "local-rag", title: "本地 RAG 方案", subtitle: "Swift 项目对比", time: "09:41", citationIndex: 0),
        .init(id: "markdown", title: "Swift Markdown 渲染", subtitle: "解析库与 README 清洗", time: "昨天", citationIndex: 1),
        .init(id: "vector-db", title: "向量数据库对比", subtitle: "桌面 app 选型", time: "昨天", citationIndex: 2),
        .init(id: "concurrency", title: "Swift 并发最佳实践", subtitle: "actor / task cancellation", time: "5 天前", citationIndex: 2)
    ]

    static let repoBundles: [RAGDemoRepoBundle] = [
        .init(
            id: "grdb",
            repo: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            description: "A toolkit for SQLite databases, with a focus on application development.",
            language: "Swift",
            stars: "7.8k",
            status: "已在知识库",
            sources: ["README", "笔记", "Metadata"],
            citationIDs: ["grdb-install", "grdb-records"],
            localDetailAvailable: true
        ),
        .init(
            id: "swift-markdown",
            repo: "swift-markdown",
            fullName: "swiftlang/swift-markdown",
            description: "A Swift package for parsing, building, editing, and analyzing Markdown documents.",
            language: "Swift",
            stars: "3.1k",
            status: "已在知识库",
            sources: ["README", "AI 摘要"],
            citationIDs: ["swift-markdown-overview"],
            localDetailAvailable: true
        ),
        .init(
            id: "mcp-swift",
            repo: "swift-sdk",
            fullName: "modelcontextprotocol/swift-sdk",
            description: "Swift SDK for Model Context Protocol clients and servers.",
            language: "Swift",
            stars: "1.4k",
            status: "GitHub 引用",
            sources: ["AI 摘要", "Metadata"],
            citationIDs: ["mcp-tools"],
            localDetailAvailable: false
        )
    ]

    static let citations: [RAGDemoCitation] = [
        .init(
            id: "grdb-install",
            rank: 1,
            repo: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            source: "README",
            sourceDetail: "README 缓存",
            sectionPath: "Installation > SQLite",
            title: "SQLite installation",
            parentTitle: "README > Installation",
            score: 0.92,
            snippet: "GRDB is a Swift SQL database toolkit built on top of SQLite. Add GRDB to your project using Swift Package Manager.",
            isTruncated: false,
            localDetailAvailable: true,
            githubURL: URL(string: "https://github.com/groue/GRDB.swift")!
        ),
        .init(
            id: "grdb-records",
            rank: 2,
            repo: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            source: "笔记",
            sourceDetail: "私有笔记",
            sectionPath: "本地存储选型",
            title: "SQLite + GRDB 作为本地缓存层",
            parentTitle: "Notes",
            score: 0.89,
            snippet: "本地优先应用需要可控的事务、迁移和 FTS 能力。GRDB 已在 Starcat 主库中使用,适合作为 RAG chunk 与 citation 的本地存储基础。",
            isTruncated: false,
            localDetailAvailable: true,
            githubURL: URL(string: "https://github.com/groue/GRDB.swift")!
        ),
        .init(
            id: "swift-markdown-overview",
            rank: 3,
            repo: "swift-markdown",
            fullName: "swiftlang/swift-markdown",
            source: "README",
            sourceDetail: "README 缓存",
            sectionPath: "Overview > Parsing",
            title: "Markdown parsing",
            parentTitle: "README > Overview",
            score: 0.88,
            snippet: "Swift Markdown is a Swift package for parsing, building, editing, and analyzing Markdown documents. The parser preserves structured block nodes for downstream processing.",
            isTruncated: false,
            localDetailAvailable: true,
            githubURL: URL(string: "https://github.com/swiftlang/swift-markdown")!
        ),
        .init(
            id: "mcp-tools",
            rank: 4,
            repo: "swift-sdk",
            fullName: "modelcontextprotocol/swift-sdk",
            source: "AI 摘要",
            sourceDetail: "仓库摘要",
            sectionPath: "Tool Calling",
            title: "MCP tool surface",
            parentTitle: "AI Summary > Tool Calling",
            score: 0.81,
            snippet: "The Swift SDK provides client and server primitives for MCP tools. It is useful when local context needs to be exposed through a typed tool surface.",
            isTruncated: true,
            localDetailAvailable: false,
            githubURL: URL(string: "https://github.com/modelcontextprotocol/swift-sdk")!
        )
    ]
}
