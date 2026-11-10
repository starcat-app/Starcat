//
//  GitHubGitTreeAPI.swift
//  Starcat
//
//  `GET /repos/{owner}/{repo}/git/trees/{ref}?recursive=1`
//
//  详情页「下载文件」需要整棵可勾选的文件树。Contents API 只能按目录懒加载，
//  勾选一个未展开的文件夹还得再打 N 次请求。Trees recursive 一次拿齐路径，
//  代价是超过约 10 万条目会被截断（DTO.truncated），UI 必须提示而不是静默缺文件。
//

import Foundation

extension GitHubAPIClient {

    /// GitHub 明确要求省略 recursive 参数才会返回单层树；不能传 recursive=0。
    func repositoryGitTreeLevel(owner: String, repo: String, ref: String) async throws -> GitHubGitTreeDTO {
        let response: APIResponse<GitHubGitTreeDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoGitTree(owner: owner, repo: repo, ref: ref)
        )
        return response.value
    }

    /// 递归拉取指定 ref 的 git tree。
    func repositoryGitTree(owner: String, repo: String, ref: String) async throws -> GitHubGitTreeDTO {
        let response: APIResponse<GitHubGitTreeDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoGitTree(owner: owner, repo: repo, ref: ref),
            queryItems: [URLQueryItem(name: "recursive", value: "1")]
        )
        return response.value
    }

    /// 分页拉分支名。超过 20 页就停，避免异常仓库把 Sheet 卡在分支请求上。
    func repositoryBranches(owner: String, repo: String) async throws -> [GitHubRepoBranchDTO] {
        var page = 1
        var result: [GitHubRepoBranchDTO] = []
        while page <= 20 {
            let response: APIResponse<[GitHubRepoBranchDTO]> = try await get(
                path: AppEndpoints.GitHubREST.Paths.repoBranches(owner: owner, repo: repo),
                queryItems: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
            result.append(contentsOf: response.value)
            guard let nextPage = response.linkHeader.nextPage else { break }
            page = nextPage
        }
        return result
    }

    /// 指定 path 在 ref 上的最近一次提交。没有历史时返回 nil，不把空列表当成错误。
    func repositoryLatestCommit(
        owner: String,
        repo: String,
        path: String,
        ref: String
    ) async throws -> GitHubCommitSummaryDTO? {
        let response: APIResponse<[GitHubCommitSummaryDTO]> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoCommits(owner: owner, repo: repo),
            queryItems: [
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "sha", value: ref),
                URLQueryItem(name: "per_page", value: "1")
            ]
        )
        return response.value.first
    }
}
