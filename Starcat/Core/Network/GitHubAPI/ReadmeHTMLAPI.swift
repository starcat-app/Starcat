//
//  ReadmeHTMLAPI.swift
//  Starcat
//
//  GET /repos/{owner}/{repo}/readme 端点封装（D-02 引入）。
//
//  - Accept: `application/vnd.github.html` → 返回 GitHub 服务端渲染好的 HTML 片段
//    （拒绝 `application/vnd.github.raw` 原始 markdown，理由见 `ReadmeAPI.swift` 头注释）
//  - 支持 If-None-Match / If-Modified-Since 条件请求（304 触发本地缓存命中）
//
//  本文件存在的意义（与 StarsAPI / UserAPI 同风格按端点拆分）：
//  把"业务端点"从底层 `client.getBytes(path:...)` 拼路径写法抽出来，让协议层（D-02
//  `GitHubAPIClientProtocol`）能以业务语义暴露，而非泄漏 path / accept 等实现细节。
//

import Foundation

extension GitHubAPIClient {

    /// 拉取 README HTML 片段。
    /// 详细 doc 见 `GitHubAPIClientProtocol.readmeHTML(...)`。
    func readmeHTML(
        owner: String,
        repo: String,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil
    ) async throws -> BytesResponse {
        try await getBytes(
            path: "/repos/\(owner)/\(repo)/readme",
            accept: "application/vnd.github.html",
            ifNoneMatch: ifNoneMatch,
            ifModifiedSince: ifModifiedSince
        )
    }
}
