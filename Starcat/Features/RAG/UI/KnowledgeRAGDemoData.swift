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
    static var conversations: [RAGDemoConversation] {
        [
            .init(id: "local-rag", title: String.l10n("rag.demo.conversation.localRAG.title"), subtitle: String.l10n("rag.demo.conversation.localRAG.subtitle"), time: "09:41", citationIndex: 0),
            .init(id: "markdown", title: String.l10n("rag.demo.conversation.markdown.title"), subtitle: String.l10n("rag.demo.conversation.markdown.subtitle"), time: String.l10n("rag.demo.time.yesterday"), citationIndex: 1),
            .init(id: "vector-db", title: String.l10n("rag.demo.conversation.vectorDB.title"), subtitle: String.l10n("rag.demo.conversation.vectorDB.subtitle"), time: String.l10n("rag.demo.time.yesterday"), citationIndex: 2),
            .init(id: "concurrency", title: String.l10n("rag.demo.conversation.concurrency.title"), subtitle: String.l10n("rag.demo.conversation.concurrency.subtitle"), time: String.l10n("rag.demo.time.fiveDaysAgo"), citationIndex: 2)
        ]
    }

    static var repoBundles: [RAGDemoRepoBundle] { [
        .init(
            id: "grdb",
            repo: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            description: "A toolkit for SQLite databases, with a focus on application development.",
            language: "Swift",
            stars: "7.8k",
            status: String.l10n("rag.demo.repo.status.inKnowledgeBase"),
            sources: ["README", String.l10n("rag.demo.source.notes"), "Metadata"],
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
            status: String.l10n("rag.demo.repo.status.inKnowledgeBase"),
            sources: ["README", String.l10n("rag.demo.source.aiSummary")],
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
            status: String.l10n("rag.demo.repo.status.githubCitation"),
            sources: [String.l10n("rag.demo.source.aiSummary"), "Metadata"],
            citationIDs: ["mcp-tools"],
            localDetailAvailable: false
        )
    ] }

    static var citations: [RAGDemoCitation] { [
        .init(
            id: "grdb-install",
            rank: 1,
            repo: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            source: "README",
            sourceDetail: String.l10n("rag.demo.sourceDetail.readmeCache"),
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
            source: String.l10n("rag.demo.source.notes"),
            sourceDetail: String.l10n("rag.demo.sourceDetail.privateNote"),
            sectionPath: String.l10n("rag.demo.citation.grdbRecords.sectionPath"),
            title: String.l10n("rag.demo.citation.grdbRecords.title"),
            parentTitle: "Notes",
            score: 0.89,
            snippet: String.l10n("rag.demo.citation.grdbRecords.snippet"),
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
            sourceDetail: String.l10n("rag.demo.sourceDetail.readmeCache"),
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
            source: String.l10n("rag.demo.source.aiSummary"),
            sourceDetail: String.l10n("rag.demo.sourceDetail.repoSummary"),
            sectionPath: "Tool Calling",
            title: "MCP tool surface",
            parentTitle: "AI Summary > Tool Calling",
            score: 0.81,
            snippet: "The Swift SDK provides client and server primitives for MCP tools. It is useful when local context needs to be exposed through a typed tool surface.",
            isTruncated: true,
            localDetailAvailable: false,
            githubURL: URL(string: "https://github.com/modelcontextprotocol/swift-sdk")!
        )
    ] }
}
