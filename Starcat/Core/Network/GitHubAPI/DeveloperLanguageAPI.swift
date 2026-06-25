//
//  DeveloperLanguageAPI.swift
//  Starcat
//
//  分享卡“开发语言”数据源端点封装。
//
//  这里刻意不复用 HomeViewModel.languageStats：那份数据统计的是用户 star 过的项目语言，
//  表达的是“兴趣分布”；分享卡需要的是用户自己开发过的公开仓库语言，表达的是“开发画像”。
//

import Foundation

extension GitHubAPIClient {

    /// 拉取当前授权用户拥有的公开仓库。
    ///
    /// GitHub `/user/repos` 默认会混入协作仓库和私有仓库；分享卡只应该展示用户自己的公开
    /// 开发语言，因此调用方固定传 `visibility=public` + `affiliation=owner`。私有仓库不纳入
    /// 分享图统计，避免导出图片泄露“我有私有仓库”的暗示。
    func ownedPublicRepositories(page: Int, perPage: Int = 100) async throws -> APIResponse<[GitHubRepoDTO]> {
        precondition(page >= 1, "page must be >= 1")
        precondition(perPage >= 1 && perPage <= 100, "perPage must be in [1, 100]")

        let query: [URLQueryItem] = [
            URLQueryItem(name: "visibility", value: "public"),
            URLQueryItem(name: "affiliation", value: "owner"),
            URLQueryItem(name: "sort", value: "pushed"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]

        return try await get(
            path: AppEndpoints.GitHubREST.Paths.currentUserRepos,
            queryItems: query
        )
    }

    /// 拉取单个仓库的语言字节分布。
    ///
    /// GitHub 返回的是 `[language: bytes]`，不是百分比。百分比必须在聚合全部仓库后统一计算，
    /// 否则“大仓库”和“小仓库”会被错误地等权相加。
    func repositoryLanguages(owner: String, repo: String) async throws -> [String: Int] {
        let response: APIResponse<[String: Int]> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoLanguages(owner: owner, repo: repo)
        )
        return response.value
    }
}
