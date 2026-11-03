//
//  IssueTemplatesAPI.swift
//  Starcat
//
//  仓库 Issue 模板拉取：`GET /repos/{owner}/{repo}/contents/.github/ISSUE_TEMPLATE`
//  列目录 + 逐文件 raw 原文，供 AI 按模板生成 Issue（2026-11-01 dong4j 需求）。
//
//  关键约束：
//  - 没有模板目录（404）是常态，不算失败 → 返回空数组。
//  - `.md`（传统模板）与 `.yml`（Issue Form）都收；`config.yml` 是配置不是模板，跳过。
//  - raw 走 `Accept: application/vnd.github.raw`（与 README markdown 同通道），
//    单文件拉取失败不拖垮整批（丢该文件，其余继续）。
//

import Foundation

/// 单条 Issue 模板：文件名（展示用）+ 原文（`.md` 为 Markdown，`.yml` 为表单定义）。
struct GitHubIssueTemplate: Equatable, Sendable {
    let name: String
    let content: String
}

extension GitHubAPIClient {

    /// 拉取仓库的 Issue 模板原文。无目录 / 私仓不可见 / 网络失败一律空数组兜底，
    /// 让 AI 生成退化为「无模板按惯例结构」，不阻塞主流程。
    func issueTemplates(
        owner: String,
        repo: String
    ) async throws -> [GitHubIssueTemplate] {
        struct EntryDTO: Decodable, Sendable {
            let name: String?
            let path: String
            let type: String?
        }

        let listPath = AppEndpoints.GitHubREST.Paths.repoContents(
            owner: owner,
            repo: repo,
            path: ".github/ISSUE_TEMPLATE"
        )
        let entries: APIResponse<[EntryDTO]>
        do {
            entries = try await get(path: listPath, queryItems: [])
        } catch NetworkError.notFound {
            // 没有 ISSUE_TEMPLATE 目录 = 未提供模板，正常状态。
            return []
        }
        let files = entries.value.filter { entry in
            guard (entry.type == "file"), let name = entry.name?.lowercased() else { return false }
            return name.hasSuffix(".md") || name.hasSuffix(".yml")
        }
        guard !files.isEmpty else { return [] }

        var templates: [GitHubIssueTemplate] = []
        for entry in files.prefix(5) {
            let fileName = entry.name ?? (entry.path as NSString).lastPathComponent
            // config.yml 是 blank_issues / contact_links 配置，不是模板正文。
            if fileName.lowercased() == "config.yml" { continue }
            do {
                let raw = try await getBytes(
                    path: AppEndpoints.GitHubREST.Paths.repoContents(owner: owner, repo: repo, path: entry.path),
                    accept: "application/vnd.github.raw",
                    ifNoneMatch: nil,
                    ifModifiedSince: nil,
                    requestTimeout: nil
                )
                let content = String(data: raw.data, encoding: .utf8) ?? ""
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                templates.append(GitHubIssueTemplate(name: fileName, content: content))
            } catch {
                // 单文件失败丢该文件，其余模板继续。
                AppLog.network.warning(
                    "Issue template fetch skipped file=\(fileName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return templates
    }
}
