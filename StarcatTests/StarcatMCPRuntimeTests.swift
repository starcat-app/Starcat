//
//  StarcatMCPRuntimeTests.swift
//  StarcatTests
//
//  MCP 协议运行时回归测试。
//
//  这组测试覆盖的是之前漏掉的 HTTP/MCP 会话层，而不是业务 facade 本身：
//  - registry 必须跟随 SDK Server 会话存活，tools/list 不能退化为空；
//  - tools/call 必须能进入真实 facade，不应返回 registry unavailable；
//  - Claude 重新 initialize 时，Starcat 需要重建 SDK 会话，不能复用已初始化的 Server。
//

import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor
@Suite("StarcatMCPRuntime")
struct StarcatMCPRuntimeTests {

    @Test("initialize 后 tools/list 返回完整工具列表且 tools/call 可用")
    func listsAndCallsToolsAfterInitialize() async throws {
        let runtime = try await Self.makeRuntime()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let initialize = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        #expect(initialize.statusCode == 200)
        let initializeJSON = try Self.jsonObject(from: initialize)
        let initializeResult = try #require(initializeJSON["result"] as? [String: Any])
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        let initializedServerVersion = try #require(serverInfo["version"] as? String)
        #expect(initializedServerVersion == StarcatMCPServerMetadata.version)

        let initialized = await runtime.handle(Self.notification(method: "notifications/initialized"))
        #expect(initialized.statusCode == 202)

        let list = await runtime.handle(Self.request(id: 2, method: "tools/list"))
        let listJSON = try Self.jsonObject(from: list)
        let tools = try #require((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 25)
        #expect(tools.contains { $0["name"] as? String == "starcat.get_capabilities" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_overview_statistics" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_ai_usage_statistics" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_knowledge_base_statistics" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_repo_context" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_repo_summary" })
        #expect(tools.contains { $0["name"] as? String == "starcat.generate_repo_summary" })
        #expect(tools.contains { $0["name"] as? String == "starcat.search_repos" })
        #expect(tools.contains { $0["name"] as? String == "starcat.semantic_search" })
        #expect(tools.contains { $0["name"] as? String == "starcat.global_search_repos" })
        #expect(tools.contains { $0["name"] as? String == "starcat.star_repo" })
        #expect(tools.contains { $0["name"] as? String == "starcat.unstar_repo" })
        #expect(tools.contains { $0["name"] as? String == "starcat.list_repos_by_tag" })
        #expect(tools.contains { $0["name"] as? String == "starcat.batch_organize_repos" })
        // 轻量 Runtime fixture 不装配 AppDependencies；扩展目录在完整 App 中单独装配。
        #expect(tools.contains { $0["name"] as? String == "starcat.search_knowledge" } == false)
        let searchTool = try #require(tools.first { $0["name"] as? String == "starcat.search_repos" })
        let inputSchema = try #require(searchTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let querySchema = try #require(properties["query"] as? [String: Any])
        let scopeSchema = try #require(properties["scope"] as? [String: Any])
        let limitSchema = try #require(properties["limit"] as? [String: Any])
        #expect(querySchema["type"] as? String == "string")
        #expect(scopeSchema["type"] as? String == "string")
        #expect(scopeSchema["enum"] as? [String] == ["starred", "knowledge", "all"])
        #expect(limitSchema["type"] as? String == "integer")
        #expect(limitSchema["default"] as? Int == 20)

        let generateTool = try #require(tools.first { $0["name"] as? String == "starcat.generate_repo_summary" })
        let generateSchema = try #require(generateTool["inputSchema"] as? [String: Any])
        let generateProperties = try #require(generateSchema["properties"] as? [String: Any])
        let externalContextSchema = try #require(generateProperties["allow_external_context"] as? [String: Any])
        #expect(externalContextSchema["type"] as? String == "boolean")
        #expect(externalContextSchema["default"] as? Bool == false)

        let usageTool = try #require(tools.first { $0["name"] as? String == "starcat.get_ai_usage_statistics" })
        let usageSchema = try #require(usageTool["inputSchema"] as? [String: Any])
        let usageProperties = try #require(usageSchema["properties"] as? [String: Any])
        let timeRangeSchema = try #require(usageProperties["time_range"] as? [String: Any])
        #expect(timeRangeSchema["enum"] as? [String] == ["today", "seven_days", "thirty_days", "all"])
        #expect(timeRangeSchema["default"] as? String == "all")

        let call = await runtime.handle(Self.request(
            id: 3,
            method: "tools/call",
            params: [
                "name": "starcat.search_repos",
                "arguments": ["limit": 1]
            ]
        ))
        let callJSON = try Self.jsonObject(from: call)
        let result = try #require(callJSON["result"] as? [String: Any])
        #expect(result["isError"] as? Bool != true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["total"] as? Int == 1)

        let knowledgeSearchCall = await runtime.handle(Self.request(
            id: 4,
            method: "tools/call",
            params: [
                "name": "starcat.search_repos",
                "arguments": ["query": "codex", "scope": "knowledge", "limit": 5]
            ]
        ))
        let knowledgeJSON = try Self.jsonObject(from: knowledgeSearchCall)
        let knowledgeResult = try #require(knowledgeJSON["result"] as? [String: Any])
        #expect(knowledgeResult["isError"] as? Bool != true)
        let knowledgeStructured = try #require(knowledgeResult["structuredContent"] as? [String: Any])
        let repos = try #require(knowledgeStructured["repos"] as? [[String: Any]])
        #expect(knowledgeStructured["total"] as? Int == 1)
        #expect(repos.first?["full_name"] as? String == "openai/codex")

        let getRepoCall = await runtime.handle(Self.request(
            id: 28,
            method: "tools/call",
            params: [
                "name": "starcat.get_repo",
                "arguments": ["owner": "apple", "name": "swift"]
            ]
        ))
        let getRepoJSON = try Self.jsonObject(from: getRepoCall)
        let getRepoResult = try #require(getRepoJSON["result"] as? [String: Any])
        #expect(getRepoResult["isError"] as? Bool != true)
        let getRepo = try #require(getRepoResult["structuredContent"] as? [String: Any])
        #expect(getRepo["full_name"] as? String == "apple/swift")
        #expect(getRepo["owner"] as? String == "apple")
        #expect(getRepo["name"] as? String == "swift")

        let capabilitiesCall = await runtime.handle(Self.request(
            id: 20,
            method: "tools/call",
            params: ["name": "starcat.get_capabilities", "arguments": [:]]
        ))
        let capabilitiesJSON = try Self.jsonObject(from: capabilitiesCall)
        let capabilitiesResult = try #require(capabilitiesJSON["result"] as? [String: Any])
        let capabilities = try #require(capabilitiesResult["structuredContent"] as? [String: Any])
        let capabilityServerVersion = try #require(capabilities["server_version"] as? String)
        #expect(capabilityServerVersion == StarcatMCPServerMetadata.version)
        #expect(capabilityServerVersion == initializedServerVersion)
        #expect(capabilities["read"] as? Bool == true)
        #expect(capabilities["statistics_read"] as? Bool == true)
        #expect(capabilities["write"] as? Bool == true)
        #expect(capabilities["local_writes"] == nil)
        #expect(capabilities["private_notes_read"] == nil)
        #expect(capabilities["loopback_only"] as? Bool == true)

        let starDryRunCall = await runtime.handle(Self.request(
            id: 29,
            method: "tools/call",
            params: [
                "name": "starcat.star_repo",
                "arguments": ["owner": "github", "name": "hub", "dry_run": true]
            ]
        ))
        let starDryRunJSON = try Self.jsonObject(from: starDryRunCall)
        let starDryRunResult = try #require(starDryRunJSON["result"] as? [String: Any])
        #expect(starDryRunResult["isError"] as? Bool != true)
        let starDryRun = try #require(starDryRunResult["structuredContent"] as? [String: Any])
        #expect(starDryRun["target_full_name"] as? String == "github/hub")
        #expect(starDryRun["dry_run"] as? Bool == true)

        let reposByTagCall = await runtime.handle(Self.request(
            id: 30,
            method: "tools/call",
            params: [
                "name": "starcat.list_repos_by_tag",
                "arguments": ["tag": "act/test", "limit": 10]
            ]
        ))
        let reposByTagJSON = try Self.jsonObject(from: reposByTagCall)
        let reposByTagResult = try #require(reposByTagJSON["result"] as? [String: Any])
        #expect(reposByTagResult["isError"] as? Bool != true)
        let reposByTag = try #require(reposByTagResult["structuredContent"] as? [String: Any])
        let matchedTag = try #require(reposByTag["tag"] as? [String: Any])
        let taggedRepos = try #require(reposByTag["repos"] as? [[String: Any]])
        #expect(matchedTag["name"] as? String == "act/test")
        #expect(reposByTag["total"] as? Int == 1)
        #expect(taggedRepos.first?["full_name"] as? String == "apple/swift")

        let missingTagCall = await runtime.handle(Self.request(
            id: 31,
            method: "tools/call",
            params: [
                "name": "starcat.list_repos_by_tag",
                "arguments": ["tag": "act/missing"]
            ]
        ))
        let missingTagJSON = try Self.jsonObject(from: missingTagCall)
        let missingTagResult = try #require(missingTagJSON["result"] as? [String: Any])
        #expect(missingTagResult["isError"] as? Bool == true)
        let missingTagError = try #require(missingTagResult["structuredContent"] as? [String: Any])
        #expect(missingTagError["code"] as? String == "NOT_FOUND")
        #expect(missingTagError["message"] as? String == "Tag not found: act/missing")

        let batchDryRunCall = await runtime.handle(Self.request(
            id: 32,
            method: "tools/call",
            params: [
                "name": "starcat.batch_organize_repos",
                "arguments": [
                    "items": [
                        ["repo_id": 1, "tags": ["act/test"], "note": "queued"],
                        ["owner": "openai", "name": "codex", "note": ""]
                    ],
                    "create_missing": false,
                    "dry_run": true
                ]
            ]
        ))
        let batchDryRunJSON = try Self.jsonObject(from: batchDryRunCall)
        let batchDryRunResult = try #require(batchDryRunJSON["result"] as? [String: Any])
        #expect(batchDryRunResult["isError"] as? Bool != true)
        let batchDryRun = try #require(batchDryRunResult["structuredContent"] as? [String: Any])
        #expect(batchDryRun["dry_run"] as? Bool == true)
        #expect(batchDryRun["requested_count"] as? Int == 2)
        #expect(batchDryRun["succeeded_count"] as? Int == 2)
        #expect(batchDryRun["failed_count"] as? Int == 0)

        let contextCall = await runtime.handle(Self.request(
            id: 21,
            method: "tools/call",
            params: [
                "name": "starcat.get_repo_context",
                "arguments": ["owner": "apple", "name": "swift"]
            ]
        ))
        let contextJSON = try Self.jsonObject(from: contextCall)
        let contextResult = try #require(contextJSON["result"] as? [String: Any])
        let context = try #require(contextResult["structuredContent"] as? [String: Any])
        let contextRepo = try #require(context["repo"] as? [String: Any])
        #expect(contextRepo["full_name"] as? String == "apple/swift")
        #expect(context["private_notes_exposed"] as? Bool == true)

        let overviewCall = await runtime.handle(Self.request(
            id: 22,
            method: "tools/call",
            params: ["name": "starcat.get_overview_statistics", "arguments": [:]]
        ))
        let overviewJSON = try Self.jsonObject(from: overviewCall)
        let overviewResult = try #require(overviewJSON["result"] as? [String: Any])
        let overview = try #require(overviewResult["structuredContent"] as? [String: Any])
        #expect(overview["starred_repository_count"] as? Int == 1)
        #expect(overview["knowledge_base_project_count"] as? Int == 1)
        let overviewUsage = try #require(overview["ai_usage"] as? [String: Any])
        #expect(overviewUsage["total_tokens"] as? Int == 42)
        let overviewIndex = try #require(overview["rag_index"] as? [String: Any])
        #expect(overviewIndex["total_chunks"] as? Int == 1)
        #expect(overviewIndex["pending_chunks"] as? Int == 1)

        let usageCall = await runtime.handle(Self.request(
            id: 23,
            method: "tools/call",
            params: [
                "name": "starcat.get_ai_usage_statistics",
                "arguments": ["time_range": "all", "provider_id": "test-provider"]
            ]
        ))
        let usageJSON = try Self.jsonObject(from: usageCall)
        let usageResult = try #require(usageJSON["result"] as? [String: Any])
        let usage = try #require(usageResult["structuredContent"] as? [String: Any])
        let usageSummary = try #require(usage["summary"] as? [String: Any])
        #expect(usageSummary["total_tokens"] as? Int == 42)
        let providers = try #require(usage["by_provider"] as? [[String: Any]])
        #expect(providers.first?["key"] as? String == "test-provider")

        let invalidUsageCall = await runtime.handle(Self.request(
            id: 25,
            method: "tools/call",
            params: [
                "name": "starcat.get_ai_usage_statistics",
                "arguments": ["time_range": "yesterday"]
            ]
        ))
        let invalidUsageJSON = try Self.jsonObject(from: invalidUsageCall)
        let invalidUsageResult = try #require(invalidUsageJSON["result"] as? [String: Any])
        #expect(invalidUsageResult["isError"] as? Bool == true)

        let invalidGlobalSearchCall = await runtime.handle(Self.request(
            id: 26,
            method: "tools/call",
            params: [
                "name": "starcat.global_search_repos",
                "arguments": ["query": "swift", "limit": 51]
            ]
        ))
        let invalidGlobalSearchJSON = try Self.jsonObject(from: invalidGlobalSearchCall)
        let invalidGlobalSearchResult = try #require(invalidGlobalSearchJSON["result"] as? [String: Any])
        #expect(invalidGlobalSearchResult["isError"] as? Bool == true)
        let structuredError = try #require(invalidGlobalSearchResult["structuredContent"] as? [String: Any])
        #expect(structuredError["schema_version"] as? Int == 1)
        #expect(structuredError["code"] as? String == "INVALID_ARGUMENTS")
        #expect(structuredError["message"] as? String == "arguments.limit: above maximum")

        let unsupportedToolCall = await runtime.handle(Self.request(
            id: 27,
            method: "tools/call",
            params: ["name": "starcat.future_tool", "arguments": [:]]
        ))
        let unsupportedToolJSON = try Self.jsonObject(from: unsupportedToolCall)
        let unsupportedToolResult = try #require(unsupportedToolJSON["result"] as? [String: Any])
        let unsupportedError = try #require(unsupportedToolResult["structuredContent"] as? [String: Any])
        #expect(unsupportedError["code"] as? String == "UPGRADE_REQUIRED")

        let knowledgeStatisticsCall = await runtime.handle(Self.request(
            id: 24,
            method: "tools/call",
            params: ["name": "starcat.get_knowledge_base_statistics", "arguments": [:]]
        ))
        let knowledgeStatsJSON = try Self.jsonObject(from: knowledgeStatisticsCall)
        let knowledgeStatsResult = try #require(knowledgeStatsJSON["result"] as? [String: Any])
        let knowledgeStats = try #require(knowledgeStatsResult["structuredContent"] as? [String: Any])
        #expect(knowledgeStats["project_count"] as? Int == 1)
        #expect(knowledgeStats["retained_after_unstar_count"] as? Int == 1)
        #expect(knowledgeStats["private_notes_exposed"] as? Bool == true)

        let resourcesList = await runtime.handle(Self.request(id: 5, method: "resources/list"))
        let resourcesJSON = try Self.jsonObject(from: resourcesList)
        let resources = try #require((resourcesJSON["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        let uris = Set(resources.compactMap { $0["uri"] as? String })
        #expect(uris.contains("starcat://repos/starred/apple/swift"))
        #expect(uris.contains("starcat://repos/knowledge/openai/codex"))
        #expect(uris.contains("starcat://repos/all/openai/codex"))
    }

    @Test("重复 initialize 会重建 SDK 会话，不返回 Server is already initialized")
    func repeatedInitializeRecreatesSession() async throws {
        let runtime = try await Self.makeRuntime()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let first = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        #expect(first.statusCode == 200)

        let second = await runtime.handle(Self.request(id: 2, method: "initialize", params: Self.initializeParams()))
        #expect(second.statusCode == 200)
        let secondJSON = try Self.jsonObject(from: second)
        #expect(secondJSON["error"] == nil)
        #expect((secondJSON["result"] as? [String: Any])?["serverInfo"] != nil)

        let list = await runtime.handle(Self.request(id: 3, method: "tools/list"))
        let listJSON = try Self.jsonObject(from: list)
        let tools = try #require((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 25)
    }

    @Test("临时 Runtime 只暴露 Agent allowlist 并拒绝越权调用")
    func transientRuntimeEnforcesToolAllowlist() async throws {
        let runtime = try await Self.makeRuntime(
            allowedToolNames: ["starcat.search_repos"],
            exposesResources: false
        )
        defer { Task { @MainActor in await runtime.shutdown() } }

        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))

        let list = await runtime.handle(Self.request(id: 2, method: "tools/list"))
        let listJSON = try Self.jsonObject(from: list)
        let tools = try #require((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["starcat.search_repos"])

        // tools/list 只是模型可见性，真正的权限边界必须在 tools/call 再校验一次。
        let denied = await runtime.handle(Self.request(
            id: 3,
            method: "tools/call",
            params: ["name": "starcat.set_repo_status", "arguments": ["repo_id": 1, "status": "read"]]
        ))
        let deniedJSON = try Self.jsonObject(from: denied)
        let deniedResult = try #require(deniedJSON["result"] as? [String: Any])
        #expect(deniedResult["isError"] as? Bool == true)
        let deniedError = try #require(deniedResult["structuredContent"] as? [String: Any])
        #expect(deniedError["code"] as? String == "UPGRADE_REQUIRED")

        let resourcesList = await runtime.handle(Self.request(id: 4, method: "resources/list"))
        let resourcesJSON = try Self.jsonObject(from: resourcesList)
        let resources = try #require((resourcesJSON["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        #expect(resources.isEmpty)
    }

    @Test("临时 Loopback Bridge 等待端口就绪并完成 MCP 请求")
    func transientLoopbackBridgeIsReadyBeforeMCPRequest() async throws {
        let runtime = try await Self.makeRuntime(
            allowedToolNames: ["starcat.search_repos"],
            exposesResources: false
        )
        let port = try StarcatMCPPortAvailability.availableDynamicPort()
        let token = "test-run-token"
        let server = StarcatMCPLoopbackHTTPServer(
            port: port,
            runtime: runtime,
            requestValidator: { request in
                guard request.path == "/mcp" else { return .notFound }
                guard request.header("Authorization") == "Bearer \(token)" else {
                    return .unauthorized
                }
                return nil
            }
        )
        defer {
            server.stop()
            Task { @MainActor in await runtime.shutdown() }
        }

        let boundPort = try await server.startAndWaitUntilReady()
        #expect(boundPort == port)

        let initialized = try await Self.sendHTTPRequest(
            port: boundPort,
            body: Self.jsonData(id: 1, method: "initialize", params: Self.initializeParams()),
            bearerToken: token
        )
        #expect(initialized.statusCode == 200)

        let listed = try await Self.sendHTTPRequest(
            port: boundPort,
            body: Self.jsonData(id: 2, method: "tools/list", params: nil),
            bearerToken: token
        )
        #expect(listed.statusCode == 200)
        let listedJSON = try #require(JSONSerialization.jsonObject(with: listed.body) as? [String: Any])
        let tools = try #require((listedJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["starcat.search_repos"])
    }

    @Test("业务 Agent MCP Runtime 暴露原始工具定义并回传结构化结果")
    func agentToolRuntimeListsAndCallsBusinessTool() async throws {
        let recorder = AgentMCPToolCallRecorder()
        let definition = AgentToolDefinition(
            name: "context_resolve_repos",
            description: "Resolve repositories from frozen Starcat context.",
            inputSchema: AgentJSONSchema(
                type: .object,
                properties: ["limit": AgentJSONSchema(type: .integer)],
                required: ["limit"]
            )
        )
        let runtime = AgentToolMCPRuntime(
            tools: [definition],
            originValidator: .localhost()
        ) { request in
            await recorder.record(request)
            return ExternalAgentToolExecutionResult(
                output: .object([
                    "status": .string("completed"),
                    "summary": .string("30 repos"),
                ]),
                modelText: "{\"status\":\"completed\",\"summary\":\"30 repos\"}",
                isError: false,
                artifactMarkdown: nil
            )
        }
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        let list = await runtime.handle(Self.request(id: 2, method: "tools/list"))
        let listJSON = try Self.jsonObject(from: list)
        let tools = try #require((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == [definition.name])
        let inputSchema = try #require(tools.first?["inputSchema"] as? [String: Any])
        #expect(inputSchema["required"] as? [String] == ["limit"])

        let call = await runtime.handle(Self.request(
            id: 3,
            method: "tools/call",
            params: ["name": definition.name, "arguments": ["limit": 30]]
        ))
        let callJSON = try Self.jsonObject(from: call)
        let result = try #require(callJSON["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(structured["summary"] as? String == "30 repos")
        let recordedRequest = await recorder.request()
        let recorded = try #require(recordedRequest)
        #expect(recorded.name == definition.name)
        #expect(recorded.input.objectValue?["limit"]?.integerValue == 30)
    }

    @Test("业务 Agent MCP Runtime 在 tools/call 入口再次拒绝越权工具")
    func agentToolRuntimeRejectsToolOutsideAllowlist() async throws {
        let definition = AgentToolDefinition(
            name: "context_resolve_repos",
            description: "Resolve repositories.",
            inputSchema: AgentJSONSchema(type: .object)
        )
        let runtime = AgentToolMCPRuntime(
            tools: [definition],
            originValidator: .localhost()
        ) { _ in
            Issue.record("越权工具不应进入业务执行器")
            return ExternalAgentToolExecutionResult(
                output: .object([:]),
                modelText: "",
                isError: false,
                artifactMarkdown: nil
            )
        }
        try await runtime.start()
        defer { Task { @MainActor in await runtime.shutdown() } }

        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        let denied = await runtime.handle(Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "artifact_build_weekly_report", "arguments": [:]]
        ))
        let deniedJSON = try Self.jsonObject(from: denied)
        let result = try #require(deniedJSON["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect((structured["summary"] as? String)?.contains("not allowed") == true)
    }

    @Test("资源 URI 的 starred 和 knowledge 范围必须与真实归属一致")
    func resourcesRespectRepositoryScope() async throws {
        let runtime = try await Self.makeRuntime()
        defer { Task { @MainActor in await runtime.shutdown() } }
        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        let allowed = await runtime.handle(Self.request(
            id: 2, method: "resources/read",
            params: ["uri": "starcat://repos/knowledge/openai/codex"]
        ))
        #expect(try Self.jsonObject(from: allowed)["result"] != nil)
        for (index, uri) in [
            "starcat://repos/starred/openai/codex",
            "starcat://repos/knowledge/apple/swift",
            "starcat://repos/all/apple/swift/unknown"
        ].enumerated() {
            let denied = await runtime.handle(Self.request(
                id: index + 3, method: "resources/read", params: ["uri": uri]
            ))
            #expect(try Self.jsonObject(from: denied)["error"] != nil)
        }
    }

    @Test("笔记统计属于默认读取，不需要独立权限")
    func knowledgeStatisticsRespectPrivateNotesCapability() async throws {
        let runtime = try await Self.makeRuntime()
        defer { Task { @MainActor in await runtime.shutdown() } }

        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        let call = await runtime.handle(Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "starcat.get_knowledge_base_statistics", "arguments": [:]]
        ))
        let json = try Self.jsonObject(from: call)
        let result = try #require(json["result"] as? [String: Any])
        let statistics = try #require(result["structuredContent"] as? [String: Any])

        #expect(statistics["private_notes_exposed"] as? Bool == true)
        #expect(statistics["private_note_project_count"] != nil)
        #expect(statistics["ai_generated_note_project_count"] != nil)
        #expect(statistics["private_notes_edited_in_last_30_days_project_count"] != nil)
    }

    @Test("可信网络 hostname 可访问，未授权 Host 仍返回 421")
    func validatesConfiguredRemoteHost() async throws {
        let port = 5_555
        let runtime = try await Self.makeRuntime(originValidator: OriginValidator(
            allowedHosts: [
                "127.0.0.1:\(port)",
                "localhost:\(port)",
                "[::1]:\(port)",
                "studio.local:\(port)"
            ],
            allowedOrigins: ["https://studio.local:\(port)"]
        ))
        defer { Task { @MainActor in await runtime.shutdown() } }

        let allowed = await runtime.handle(Self.request(
            id: 1,
            method: "initialize",
            params: Self.initializeParams(),
            host: "studio.local:\(port)"
        ))
        #expect(allowed.statusCode == 200)

        let rejected = await runtime.handle(Self.request(
            id: 2,
            method: "initialize",
            params: Self.initializeParams(),
            host: "attacker.example:\(port)"
        ))
        #expect(rejected.statusCode == 421)
        let body = try #require(rejected.bodyData.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("Host header not allowed"))
    }

    @Test("写关闭后笔记与资源仍可读，生成及所有原有写工具统一拒绝")
    func readDefaultWriteDisabled() async throws {
        let runtime = try await Self.makeRuntime(allowWrites: false)
        defer { Task { @MainActor in await runtime.shutdown() } }
        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        for (index, name) in ["starcat.get_repo_note", "starcat.get_repo_context", "starcat.get_capabilities"].enumerated() {
            let response = await runtime.handle(Self.request(id: index + 2, method: "tools/call", params: [
                "name": name, "arguments": name == "starcat.get_capabilities" ? [:] : ["repo_id": 1]
            ]))
            let result = try #require(Self.jsonObject(from: response)["result"] as? [String: Any])
            #expect(result["isError"] as? Bool != true)
        }
        let writes: [(String, [String: Any])] = [
            ("generate_repo_summary", ["repo_id": 1]),
            ("star_repo", ["owner": "apple", "name": "swift"]),
            ("unstar_repo", ["repo_id": 1]),
            ("upsert_repo_note", ["repo_id": 1, "content": "blocked"]),
            ("set_repo_status", ["repo_id": 1, "status": "to_read"]),
            ("create_tag", ["name": "blocked"]),
            ("add_repo_tags", ["repo_id": 1, "tags": ["blocked"]]),
            ("remove_repo_tags", ["repo_id": 1, "tags": ["blocked"]]),
            ("set_repo_tags", ["repo_id": 1, "tags": ["blocked"]]),
            ("batch_organize_repos", ["items": [["repo_id": 1, "note": "blocked"]]])
        ]
        for (index, entry) in writes.enumerated() {
            let response = await runtime.handle(Self.request(id: index + 10, method: "tools/call", params: [
                "name": "starcat.\(entry.0)", "arguments": entry.1
            ]))
            let result = try #require(Self.jsonObject(from: response)["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["code"] as? String == "WRITE_DISABLED")
        }
        let listed = await runtime.handle(Self.request(id: 30, method: "tools/list", params: [:]))
        let listing = try #require(Self.jsonObject(from: listed)["result"] as? [String: Any])
        let tools = try #require(listing["tools"] as? [[String: Any]])
        let allWrites = tools.filter { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false }
        #expect(allWrites.count == writes.count)
        for (index, tool) in allWrites.enumerated() {
            let response = await runtime.handle(Self.request(id: index + 40, method: "tools/call", params: [
                "name": try #require(tool["name"] as? String), "arguments": [:]
            ]))
            let result = try #require(Self.jsonObject(from: response)["result"] as? [String: Any])
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["code"] as? String == "WRITE_DISABLED")
        }
        let resource = await runtime.handle(Self.request(id: 80, method: "resources/read", params: [
            "uri": "starcat://capabilities"
        ]))
        let resourceResult = try #require(Self.jsonObject(from: resource)["result"] as? [String: Any])
        #expect(resourceResult["contents"] is [[String: Any]])
    }

    /// 真实 DeepSeek smoke 也复用同一份内存数据，避免为跨进程 MCP 验证再造一套假协议。
    static func makeRuntime(
        originValidator: OriginValidator = .localhost(),
        allowedToolNames: Set<String>? = nil,
        exposesResources: Bool = true,
        allowWrites: Bool = true,
        database: InMemoryDatabaseManager? = nil,
        publicCapabilities: StarcatMCPPublicFacade? = nil
    ) async throws -> StarcatMCPRuntime {
        let parts = try await makeFacades(allowWrites: allowWrites, database: database, publicCapabilities: publicCapabilities)
        let runtime = StarcatMCPRuntime(
            facade: parts.facade,
            writeFacade: parts.writeFacade,
            originValidator: originValidator,
            allowedToolNames: allowedToolNames,
            exposesResources: exposesResources
        )
        try await runtime.start()
        return runtime
    }

    /// 协议会话和服务启动门槛共用生产门面，只把账户库、权益及钥匙串替换为隔离测试依赖。
    static func makeFacades(allowWrites: Bool, database: InMemoryDatabaseManager?,
                            publicCapabilities: StarcatMCPPublicFacade?, isPro: Bool = true,
                            entitlementProvider: (any ProEntitlementProviding)? = nil) async throws ->
        (facade: StarcatMCPFacade, writeFacade: StarcatMCPWriteFacade, settings: AppSettings,
         gate: EntitlementGate, keychain: InMemoryKeychain) {
        let db = try database ?? InMemoryDatabaseManager()
        if database == nil { try await seedRuntimeData(in: db) }

        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.starcat.mcp.runtime.\(UUID().uuidString)")!)
        settings.mcpAllowWrites = allowWrites

        let gate = EntitlementGate(
            entitlementProvider: entitlementProvider ?? MCPRuntimeTestEntitlementProvider(isPro: isPro),
            userIDProvider: { 1 }
        )
        let repoRepository = GRDBRepoRepository(database: db)
        let tagRepository = GRDBTagRepository(database: db)
        let repoTagRepository = GRDBRepoTagRepository(database: db)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        let readmeRepository = ReadmeRepository(database: db)
        let summaryRepository = GRDBAISummaryRepository(database: db)
        let testKeychain = InMemoryKeychain()
        let semanticSearch = SemanticSearchService(
            embeddingRepository: GRDBRepoEmbeddingRepository(database: db),
            settings: settings,
            readmeRepository: readmeRepository,
            noteRepository: noteRepository,
            summaryRepository: summaryRepository,
            entitlementGate: gate,
            keychain: testKeychain
        )
        let insightService = RepoAIInsightService(
            summaryRepository: summaryRepository,
            readmeRepository: readmeRepository,
            settings: settings,
            keychain: testKeychain,
            entitlementGate: gate
        )
        let facade = StarcatMCPFacade(
            repoRepository: repoRepository,
            readmeRepository: readmeRepository,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository,
            repoNoteRepository: noteRepository,
            semanticSearchService: semanticSearch,
            repoAIInsightService: insightService,
            database: db,
            aiUsageRepository: GRDBAIUsageRepository(database: db),
            knowledgeBaseMetadataSnapshotCache: KnowledgeBaseMetadataSnapshotCache(),
            entitlementGate: gate,
            settings: settings
        )
        facade.publicCapabilities = publicCapabilities
        let writeFacade = StarcatMCPWriteFacade(
            repoRepository: repoRepository,
            metadataCapability: RepositoryMetadataCapabilityExecutor(
                source: DatabaseRepositoryMetadataCapabilitySource(
                    repoRepository: repoRepository,
                    repoNoteRepository: noteRepository
                )
            ),
            tagCapability: RepositoryTagCapabilityExecutor(
                source: DatabaseRepositoryTagCapabilitySource(
                    repoRepository: repoRepository,
                    tagRepository: GatedTagRepository(base: tagRepository, entitlementGate: gate),
                    repoTagRepository: repoTagRepository
                )
            ),
            starMutationService: MCPRuntimeStarMutationServiceStub(),
            settings: settings,
            entitlementGate: gate,
            auditLog: StarcatMCPAuditLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("starcat-mcp-runtime-\(UUID().uuidString).jsonl"))
        )
        return (facade, writeFacade, settings, gate, testKeychain)
    }

    /// 常规协议用例使用既有数据，注入领域样例时避免混入其他仓库或标签。
    private static func seedRuntimeData(in db: InMemoryDatabaseManager) async throws {
        try await db.insertRepoFixture(id: 1, owner: "apple", name: "swift")
        try await db.insertRepoFixture(id: 2, owner: "openai", name: "codex")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id = 2")
        }

        let tagRepository = GRDBTagRepository(database: db)
        let repoTagRepository = GRDBRepoTagRepository(database: db)
        let actionTag = Tag.fixture(id: "mcp-act-test", name: "act/test")
        try await tagRepository.create(actionTag)
        try await repoTagRepository.addTag(repoId: 1, tagId: actionTag.id)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        try await noteRepository.updateLibraryState(repoId: 2, state: .inLibrary)
        try await db.writer.write { database in
            try database.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES (
                    2, 'readme', '', 'readme', 'readme', 'README', 'readme:0',
                    0, '', 'README', 'pending content', 'mcp-pending', 2, 0,
                    NULL, 'pending', datetime('now'), datetime('now')
                )
                """)
        }
        try await GRDBAIUsageRepository(database: db).insert(AIUsageEvent(
            id: "mcp-test-usage",
            startedAt: 1,
            completedAt: 2,
            durationMs: 1_000,
            providerId: "test-provider",
            providerKind: "openAICompatible",
            model: "test-model",
            feature: AIUsageFeature.mcp.rawValue,
            phase: "statistics_test",
            operation: AIUsageOperation.chat.rawValue,
            inputTokens: 30,
            outputTokens: 12,
            totalTokens: 42,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 1,
            usageSource: AIUsageSource.provider.rawValue,
            status: AIUsageStatus.succeeded.rawValue,
            errorCategory: nil,
            correlationId: nil
        ))
    }

    static func initializeParams() -> [String: Any] {
        [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": [
                "name": "StarcatRuntimeTests",
                "version": "1.0"
            ]
        ]
    }

    private static func jsonData(
        id: Int,
        method: String,
        params: [String: Any]?
    ) throws -> Data {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            object["params"] = params
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func sendHTTPRequest(
        port: Int,
        body: Data,
        bearerToken: String?,
        host: String = "127.0.0.1"
    ) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 5
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        return (httpResponse.statusCode, data)
    }

    static func request(
        id: Int,
        method: String,
        params: [String: Any]? = nil,
        host: String? = nil
    ) -> HTTPRequest {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return httpRequest(object, host: host)
    }

    static func notification(method: String, params: [String: Any]? = nil) -> HTTPRequest {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return httpRequest(object)
    }

    private static func httpRequest(_ object: [String: Any], host: String? = nil) -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var headers = [
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-03-26"
        ]
        if let host {
            headers["Host"] = host
        }
        return HTTPRequest(
            method: "POST",
            headers: headers,
            body: body,
            path: "/mcp"
        )
    }

    private static func jsonObject(from response: HTTPResponse) throws -> [String: Any] {
        #expect(response.statusCode == 200)
        let body = try #require(response.bodyData)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("切换跨设备开关时本机 HTTP 地址不变，开启后可用网络 IPv4 调用")
    func httpSurvivesRemoteToggle() async throws {
        let engine = DecisionHTTPStubEngine()
        let (service, settings, port) = try await Self.startDecisionServer(engine)
        defer { service.stop() }
        settings.decisionHTTPServiceEnabled = true
        let endpoint = "http://127.0.0.1:\(port)/mcp"
        let token = service.bearerToken
        let decision = Data(#"{"state":"http fixture","questions":{"useful":{"type":"noul","instructions":"Is this useful?"}}}"#.utf8)
        let initialize = try Self.jsonData(id: 1, method: "initialize", params: Self.initializeParams())
        let lanHost = StarcatMCPService.localIPv4Hosts().first

        for allowRemote in [false, true, false] {
            if settings.mcpAllowRemoteConnections != allowRemote {
                settings.mcpAllowRemoteConnections = allowRemote
                service.restartForCurrentSettings()
                try await Self.waitForDecisionServer(service)
            }
            #expect(service.endpointURL == endpoint)
            let loopback = try await Self.sendDecisionRequest(port: port, body: decision, bearerToken: token)
            #expect(loopback.statusCode == 200)
            if allowRemote, let lanHost {
                #expect(service.remoteEndpointURL?.hasPrefix("http://") == true)
                let rest = try await Self.sendDecisionRequest(
                    port: port, body: decision, bearerToken: token, host: lanHost
                )
                #expect(rest.statusCode == 200)
                let mcp = try await Self.sendHTTPRequest(
                    port: port, body: initialize, bearerToken: token, host: lanHost
                )
                #expect(mcp.statusCode == 200)
            } else if !allowRemote {
                #expect(service.remoteEndpointURL == nil)
                if let lanHost {
                    await #expect(throws: URLError.self) {
                        _ = try await Self.sendDecisionRequest(
                            port: port, body: decision, bearerToken: token, host: lanHost
                        )
                    }
                }
            }
        }
    }

    @Test("决策 HTTP 按开关实时启停，沿用 MCP 门禁与兼容响应")
    func decisionHTTPRouteReusesMCPGates() async throws {
        let engine = DecisionHTTPStubEngine()
        let entitlementProvider = MCPRuntimeTestEntitlementProvider(isPro: true)
        let (service, settings, port) = try await Self.startDecisionServer(engine, entitlementProvider: entitlementProvider)
        defer { service.stop() }
        let token = service.bearerToken

        let request = try JSONSerialization.data(withJSONObject: [
            "state": "http fixture",
            "questions": [
                "useful": ["type": "noul", "instructions": "Is this useful?"],
                "team": ["type": "choice", "criteria": ["billing": "Billing", "other": "Other"]],
                "severity": ["type": "score", "criteria": ["Low", "High"]]
            ]
        ])
        let initiallyDisabled = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        #expect(initiallyDisabled.statusCode == 403)
        let disabledError = try #require(JSONSerialization.jsonObject(with: initiallyDisabled.body) as? [String: String])
        #expect(disabledError["error"] == String.l10n("settings.decision.http.disabled"))
        #expect(engine.received.isEmpty)

        settings.decisionHTTPServiceEnabled = true
        let success = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        #expect(success.statusCode == 200)
        let successJSON = try #require(JSONSerialization.jsonObject(with: success.body) as? [String: Any])
        let answers = try #require(successJSON["answers"] as? [String: Any])
        #expect((answers["useful"] as? [String: Any])?["noul"] as? Double == 0.9)
        #expect((answers["team"] as? [String: Any])?["choice"] as? String == "billing")
        #expect((answers["severity"] as? [String: Any])?["legend"] as? [String: String] == ["0": "Low", "1": "High"])
        #expect(successJSON["model"] as? String == "decision-http-stub")
        #expect(successJSON["usage"] as? [String: Int] == ["input_tokens": 3, "output_tokens": 1])

        let invalidOrigin = try await Self.sendDecisionRequest(
            port: port, body: request, bearerToken: token, headers: ["Origin": "http://invalid.example"]
        )
        #expect(invalidOrigin.statusCode == 403)
        let invalidHost = try await Self.sendDecisionRequest(
            port: port, body: request, bearerToken: token, headers: ["Host": "invalid.example"]
        )
        #expect(invalidHost.statusCode == 421)
        let unauthorized = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token + "-invalid")
        #expect(unauthorized.statusCode == 401)

        let compressed = try await Self.sendDecisionRequest(
            port: port, body: request, bearerToken: token, headers: ["Content-Encoding": "zstd"]
        )
        #expect(compressed.statusCode == 415)

        settings.decisionEngineEnabled = false
        let engineDisabled = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        let engineError = try #require(JSONSerialization.jsonObject(with: engineDisabled.body) as? [String: String])
        #expect(engineDisabled.statusCode == 503)
        #expect(engineError["error"] == "Decision engine is disabled in Settings")
        settings.decisionEngineEnabled = true

        settings.mcpAllowWrites = false
        let writeDisabled = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        #expect(writeDisabled.statusCode == 403)
        settings.mcpAllowWrites = true

        entitlementProvider.entitlement = .inactive
        let noPro = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        #expect(noPro.statusCode == 403)
        entitlementProvider.entitlement = .testEnvironment

        settings.decisionHTTPServiceEnabled = false
        let httpDisabled = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        #expect(httpDisabled.statusCode == 403)
        let initialize = try Self.jsonData(id: 1, method: "initialize", params: Self.initializeParams())
        let mcp = try await Self.sendHTTPRequest(port: port, body: initialize, bearerToken: token)
        #expect(mcp.statusCode == 200)

        settings.decisionHTTPServiceEnabled = true
        settings.mcpServiceEnabled = false
        let serviceDisabled = try await Self.sendDecisionRequest(port: port, body: request, bearerToken: token)
        #expect(serviceDisabled.statusCode == 403)
        #expect(engine.received.count == 1)
    }

    @Test("决策 HTTP 路由归一化 multipart 图片请求")
    func decisionHTTPRouteNormalizesMultipart() async throws {
        let engine = DecisionHTTPStubEngine()
        let (service, settings, port) = try await Self.startDecisionServer(engine)
        defer { service.stop() }
        settings.decisionHTTPServiceEnabled = true

        let requestJSON = """
        {"state":"photo","questions":{"q":{"type":"box","instructions":"Locate the button."}},"assets":{"photo":{"type":"image","part":"photo"}}}
        """
        var body = Data()
        body.append(Data("--decision-boundary\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"request\"\r\n".utf8))
        body.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        body.append(Data(requestJSON.utf8))
        body.append(Data("\r\n".utf8))
        body.append(Data("--decision-boundary\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.png\"\r\n".utf8))
        body.append(Data("Content-Type: image/png\r\n\r\n".utf8))
        let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
        body.append(image)
        body.append(Data("\r\n--decision-boundary--\r\n".utf8))

        let contentType = "multipart/form-data; boundary=decision-boundary"
        let missingHeader = try await Self.sendDecisionRequest(
            port: port, body: body, bearerToken: service.bearerToken, contentType: contentType
        )
        #expect(missingHeader.statusCode == 400)

        let response = try await Self.sendDecisionRequest(
            port: port,
            body: body,
            bearerToken: service.bearerToken,
            contentType: contentType,
            headers: ["TypeSafe-Danger-Zone-Images": "true"]
        )
        #expect(response.statusCode == 200)
        let payload = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let answers = try #require(payload["answers"] as? [String: [String: Any]])
        #expect(answers["q"]?["confidence"] is NSNull)
        #expect(engine.received.count == 1)
        let asset = try #require(engine.received.first?.assets?["photo"])
        #expect(asset.format == "png")
        #expect(asset.part == nil)
        #expect(asset.dataBase64 == image.base64EncodedString())
    }

    @Test("System One 按请求体计算 32 MiB 上限并保留 MCP 原上限")
    func decisionHTTPBodyLimit() throws {
        let decisionLimit = 32 * 1024 * 1024
        func headers(path: String, length: Int) -> Data {
            Data("POST \(path) HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n".utf8)
        }
        let path = "/v1/systemone"
        #expect(try StarcatHTTPServerRequest(data: headers(path: path, length: decisionLimit)) == nil)
        #expect {
            try StarcatHTTPServerRequest(data: headers(path: path, length: decisionLimit + 1))
        } throws: { error in
            guard case StarcatHTTPServerError.payloadTooLarge = error else { return false }
            return true
        }
        #expect {
            try StarcatHTTPServerRequest(data: headers(path: "/mcp", length: 8 * 1024 * 1024 + 1))
        } throws: { error in
            guard case StarcatHTTPServerError.payloadTooLarge = error else { return false }
            return true
        }
    }

    /// 通过真实 listener 验证调用方看到的响应，所有网络推理与权限变更均使用测试替身。
    private static func startDecisionServer(
        _ engine: DecisionHTTPStubEngine,
        entitlementProvider: (any ProEntitlementProviding)? = nil
    ) async throws -> (StarcatMCPService, AppSettings, Int) {
        let port = try StarcatMCPPortAvailability.availableDynamicPort()
        let parts = try await makeFacades(
            allowWrites: true, database: nil, publicCapabilities: nil, entitlementProvider: entitlementProvider
        )
        parts.settings.mcpServicePort = port
        parts.settings.mcpServiceEnabled = true
        parts.settings.mcpAllowRemoteConnections = false
        parts.settings.decisionEngineEnabled = true
        parts.settings.decisionEngineID = .jev
        let decisionService = DecisionSystemOneService(
            engineRegistry: DecisionEngineRegistry(engines: [engine]),
            settings: parts.settings
        )
        let service = StarcatMCPService(
            settings: parts.settings,
            entitlementGate: parts.gate,
            localAPIKeyStore: .init(keychain: parts.keychain),
            deviceStore: .init(keychain: parts.keychain),
            facade: parts.facade,
            writeFacade: parts.writeFacade,
            decisionSystemOneService: decisionService
        )
        service.start()
        try await waitForDecisionServer(service)
        return (service, parts.settings, port)
    }

    private static func waitForDecisionServer(_ service: StarcatMCPService) async throws {
        for _ in 0..<100 {
            if case .running = service.state { return }
            if case .failed(let message) = service.state {
                throw StarcatMCPError.invalidArguments(message)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        service.stop()
        throw StarcatMCPError.invalidArguments("MCP service did not start for the decision HTTP test.")
    }

    private static func sendDecisionRequest(
        port: Int,
        body: Data,
        bearerToken: String,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        host: String = "127.0.0.1"
    ) async throws -> (statusCode: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/v1/systemone")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 5
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        return (httpResponse.statusCode, data)
    }
}

/// HTTP 路由测试只需验证传输层归一化与门禁；用固定答案避免真实付费推理。
@MainActor
private final class DecisionHTTPStubEngine: DecisionEngineProviding {
    let id: DecisionEngineID = .jev
    var availability: DecisionEngineAvailability = .available
    private(set) var received: [DecisionEvaluationRequest] = []

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse {
        received.append(request)
        return DecisionEvaluationResponse(
            answers: request.questions.mapValues { question in
                switch question.type {
                case .noul:
                    return DecisionAnswer(type: "noul", noul: 0.9)
                case .choice:
                    return DecisionAnswer(
                        type: "choice", choice: "billing", confidence: 0.9,
                        probabilities: ["billing": 0.9, "other": 0.1]
                    )
                case .score:
                    return DecisionAnswer(
                        type: "score", score: 1, confidence: 0.9, probabilities: ["0": 0, "1": 1],
                        legend: .object(["0": .string("Low"), "1": .string("High")])
                    )
                case .box:
                    return DecisionAnswer(type: "box", box: .init(top: 0.1, bottom: 0.8, left: 0.2, right: 0.9))
                }
            },
            model: "decision-http-stub",
            usage: TypeSafeUsage(inputTokens: 3, outputTokens: 1)
        )
    }
}

private actor AgentMCPToolCallRecorder {
    private var value: ExternalAgentToolRequest?

    func record(_ request: ExternalAgentToolRequest) {
        value = request
    }

    func request() -> ExternalAgentToolRequest? {
        value
    }
}

@MainActor
private final class MCPRuntimeTestEntitlementProvider: ProEntitlementProviding {
    var entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}

/// Runtime 测试只验证 MCP 协议分发；任何非 dry-run 调用都不应触达真实 GitHub。
@MainActor
private final class MCPRuntimeStarMutationServiceStub: MCPStarMutationServicing {
    func star(owner: String, repo: String, displayedStarsCount: Int?) async throws -> Repo {
        Repo.makeMinimal(owner: owner, name: repo)
    }

    func unstar(repo: Repo) async throws {}
}
