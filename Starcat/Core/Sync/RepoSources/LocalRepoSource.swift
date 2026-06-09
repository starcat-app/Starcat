//
//  LocalRepoSource.swift
//  Starcat
//
//  R-01 RepoSource chain 第一节：从本地 SQLite 查 repo。
//
//  适用场景：Manage 详情（必命中）/ Trending / Weekly 详情页该 repo 已 star
//  （命中后展示 tags / notes / release 三段）。
//
//  匹配键：`full_name`（owner/name 拼起来）。GRDBRepoRepository.findByOwnerName
//  已建唯一索引 + case-sensitive 匹配（GitHub login 本身大小写不敏感但官方约定保留
//  原始大小写返回，本地直接精确比对足够）。
//

import Foundation

struct LocalRepoSource: RepoSource {
    let name = "LocalRepoSource"

    private let repository: any RepoRepositoryProtocol

    init(repository: any RepoRepositoryProtocol) {
        self.repository = repository
    }

    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo? {
        // 调用 protocol 方法；不存在返回 nil，调用方继续询问链上下一个 source
        try await repository.findByOwnerName(owner: owner, name: name)
    }
}
