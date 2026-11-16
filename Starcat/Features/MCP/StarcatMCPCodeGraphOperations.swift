//
//  StarcatMCPCodeGraphOperations.swift
//  Starcat
//
//  代码分析公共适配：复用原快照、解压、索引与持久化流程，仅分离打开浏览器这一步。
//  CodeFlow 的实际可视化分析在浏览器执行，因此准备 HTML 不能冒称已完成图分析。
//

import Foundation
import MCP

extension StarcatMCPPublicCatalog {
    static let codeGraphSpecs: [StarcatMCPPublicSpec] = [
        .init(name: "get_code_analysis", summary: "Read stored CodeFlow or Codebase Memory metadata without indexing or opening a browser.", properties: selector.merging(["engine": string(["codeflow", "codebase_memory"])]) { _, new in new }, required: ["engine"]),
        .init(name: "prepare_codeflow", summary: "Prepare the App's CodeFlow HTML artifact without opening a browser. Analysis runs when the user opens the downloaded HTML. Read bytes using read_export_chunk.", properties: selector.merging(preview) { _, new in new }.merging(["branch": string()]) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "index_codebase_memory", summary: "Run the App's full source indexing and metadata persistence without starting its Web UI or opening a browser.", properties: selector.merging(preview) { _, new in new }.merging(["branch": string()]) { _, new in new }, permission: "write", network: "github_and_configured_indexer", task: true)
    ]
}

extension StarcatMCPPublicFacade {
    /// 参数只标识已有仓库和分支；客户端不能提供待执行脚本或任意本机源码目录。
    func callCodeGraphOperation(name: String, arguments: [String: Value], app: AppDependencies) async throws -> Value {
        let repo = try await resolve(arguments, app: app)
        if name == "get_code_analysis" {
            if arguments["engine"]?.stringValue == "codeflow" {
                guard let project = try CodeFlowStorage().existingProject(owner: repo.owner, name: repo.name) else {
                    return .object(["cache_hit": .bool(false)])
                }
                return .object(["cache_hit": .bool(true), "metadata": try StarcatMCPJSON.value(project.metadata)])
            }
            guard let project = try CodebaseMemoryStorage().existingProject(owner: repo.owner, name: repo.name) else {
                return .object(["cache_hit": .bool(false)])
            }
            return .object(["cache_hit": .bool(true), "metadata": try StarcatMCPJSON.value(project.metadata)])
        }
        let branch = arguments["branch"]?.stringValue ?? repo.defaultBranch ?? "main"
        if arguments["dry_run"]?.boolValue ?? true {
            return preview(name, target: .object(["repository": .string(repo.fullName), "branch": .string(branch), "opens_browser": .bool(false)]))
        }
        return try tasks.start(kind: name) {
            if name == "prepare_codeflow" {
                let model = CodeFlowViewModel(repo: repo)
                model.selectedBranchName = branch
                let project = try await model.prepareAndWait(maximumArchiveBytes: app.settings.aiRepoContextMaximumArchiveMB * 1_000_000)
                let artifactID = UUID().uuidString.lowercased()
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("starcat-public-codeflow-\(artifactID).html")
                try FileManager.default.copyItem(at: project.pageURL, to: copy)
                self.diagnosticExports[artifactID] = (copy, Date())
                return .object(["artifact_id": .string(artifactID), "format": .string("html"),
                                "analysis_state": .string("requires_browser"), "branch": .string(branch),
                                "retention_seconds": .int(3600)])
            }
            let model = CodebaseMemoryViewModel(repo: repo)
            model.selectedBranchName = branch
            let project = try await model.indexAndWait(maximumArchiveBytes: app.settings.aiRepoContextMaximumArchiveMB * 1_000_000)
            return .object(["indexed": .bool(true), "metadata": try StarcatMCPJSON.value(project.metadata)])
        }
    }
}
