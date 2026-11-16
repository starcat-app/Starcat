//
//  StarcatMCPRAGOperations.swift
//  Starcat
//
//  RAG 会话公共适配。会话 ID 是账号数据库中的稳定身份，任务 ID 只表示一次执行。
//  没有打开窗口时使用相同工作台编排对象；不依赖 GUI 自动化。
//

import Foundation
import MCP

extension AppDependencies {
    /// 复用已打开工作台以保留取消、标题和草稿生命周期；无窗口时创建仅执行业务的实例。
    func publicRAGWorkspace() -> KnowledgeRAGWorkspaceViewModel {
        if let activeKnowledgeRAGWorkspace { return activeKnowledgeRAGWorkspace }
        let home = HomeViewModel(
            repository: repoRepository, tagRepository: tagRepository, repoTagRepository: repoTagRepository,
            repoNoteRepository: repoNoteRepository, repoHealthRepository: repoHealthRepository,
            releaseRepository: releaseRepository, releaseSubscriptionRepository: releaseSubscriptionRepository,
            openSSFScoreRepository: openSSFScoreRepository, smartCollectionRepository: smartCollectionRepository,
            semanticSearchService: semanticSearchService
        )
        return KnowledgeRAGWorkspaceViewModel(dependencies: self, homeViewModel: home)
    }
}

extension StarcatMCPPublicFacade {
    /// 读取返回有界消息页；问答、删除和改名复用 App 的会话业务入口。
    func callRAGOperation(name: String, arguments: [String: Value], app: AppDependencies) async throws -> Value {
        let dryRun = arguments["dry_run"]?.boolValue ?? true
        let limit = arguments["limit"]?.intValue ?? 20
        let offset = arguments["offset"]?.intValue ?? 0
        if name == "list_rag_conversations" {
            let conversations = try await app.ragConversationStore.listConversations()
            return .object([
                "items": .array(conversations.dropFirst(offset).prefix(limit).map(Self.ragSummary)),
                "has_more": .bool(conversations.count > offset + limit),
                "next_offset": conversations.count > offset + limit ? .int(offset + limit) : .null
            ])
        }
        if name == "create_rag_conversation" {
            if dryRun { return preview(name, target: arguments["title"] ?? .null) }
            let conversation = try await app.ragConversationStore.createConversation(title: arguments["title"]?.stringValue, groupID: nil)
            app.activeKnowledgeRAGWorkspace?.conversations = try await app.ragConversationStore.listConversations()
            return Self.ragSummary(conversation)
        }
        guard ["get_rag_conversation", "delete_rag_conversation", "rename_rag_conversation", "pin_rag_conversation", "ask_rag"].contains(name) else {
            throw StarcatMCPError.unsupported("Unknown public capability: \(name)")
        }
        guard let id = arguments["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw StarcatMCPError.invalidArguments("A RAG conversation UUID is required.")
        }
        guard let detail = try await app.ragConversationStore.loadConversation(id: id) else {
            throw StarcatMCPError.notFound("RAG conversation not found.")
        }
        if name == "get_rag_conversation" { return Self.ragDetail(detail, limit: limit, offset: offset) }
        if dryRun { return preview(name, target: Self.ragSummary(detail.summary)) }
        let workspace = app.publicRAGWorkspace()
        switch name {
        case "delete_rag_conversation":
            try await workspace.deleteConversationOperation(id)
            return .object(["deleted": .bool(try await app.ragConversationStore.loadConversation(id: id) == nil), "id": .string(id.uuidString)])
        case "rename_rag_conversation":
            await workspace.renameConversation(id: id, title: try nonBlank(arguments, key: "title"))
        case "pin_rag_conversation":
            await workspace.setConversationPinned(id: id, isPinned: arguments["pinned"]?.boolValue ?? false)
        case "ask_rag":
            let question = try nonBlank(arguments, key: "question")
            var repos: [Repo] = []
            for value in arguments["repo_ids"]?.arrayValue ?? [] {
                repos.append(try await resolve(["repo_id": value], app: app, scope: .knowledge))
            }
            return try tasks.start(kind: "ask_rag") {
                let result = try await workspace.answerConversationOperation(id: id, question: question, repos: repos)
                return Self.ragDetail(result, limit: 2, offset: max(0, result.messages.count - 2))
            }
        default: break
        }
        guard let updated = try await app.ragConversationStore.loadConversation(id: id) else { throw StarcatMCPError.notFound("RAG conversation not found.") }
        if name == "rename_rag_conversation", updated.summary.title != (try nonBlank(arguments, key: "title")) {
            throw StarcatPublicCapabilityError(code: "OPERATION_FAILED", message: "Conversation rename failed.")
        }
        if name == "pin_rag_conversation", updated.summary.isPinned != (arguments["pinned"]?.boolValue ?? false) {
            throw StarcatPublicCapabilityError(code: "OPERATION_FAILED", message: "Conversation pin update failed.")
        }
        return Self.ragSummary(updated.summary)
    }

    /// 显式投影避免输出调试文件路径或底层 provider 的鉴权字段。
    static func ragSummary(_ summary: RAGConversationSummary) -> Value {
        .object([
            "id": .string(summary.id.uuidString), "title": .string(summary.title),
            "pinned": .bool(summary.isPinned), "group_id": summary.groupID.map { .string($0.uuidString) } ?? .null,
            "created_at": .string(summary.createdAt), "updated_at": .string(summary.updatedAt)
        ])
    }

    static func ragDetail(_ detail: RAGConversationDetail, limit: Int, offset: Int) -> Value {
        .object([
            "conversation": ragSummary(detail.summary),
            "messages": .array(detail.messages.dropFirst(offset).prefix(limit).map { message in
                .object([
                    "id": .string(message.id.uuidString), "role": .string(message.role.rawValue),
                    "content": .string(message.content), "model": message.model.map(Value.string) ?? .null,
                    "created_at": .string(message.createdAt),
                    "citations": .array(message.citations.map { citation in
                        .object([
                            "id": .string(citation.id.uuidString), "marker": .string(citation.marker),
                            "repo_id": citation.repoID.map { .int(Int($0)) } ?? .null,
                            "repository": .string(citation.repoFullName),
                            "source": .string(citation.source.rawValue), "section_title": .string(citation.sectionTitle),
                            "source_url": citation.sourceURL.map { .string($0.absoluteString) } ?? .null,
                            "evidence": citation.evidenceContent.map(Value.string) ?? .null
                        ])
                    })
                ])
            }),
            "message_count": .int(detail.messages.count), "has_more": .bool(detail.messages.count > offset + limit),
            "next_offset": detail.messages.count > offset + limit ? .int(offset + limit) : .null
        ])
    }
}
