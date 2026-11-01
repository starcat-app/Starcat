//
//  RepoIssuesViewModelTests.swift
//  StarcatTests
//
//  Issues 浮层数据层：首屏 / 分页去重、状态筛选、客户端搜索 + Search API 兜底、
//  精确计数、新建回填高亮、仓库切换复位、错误文案映射。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("RepoIssuesViewModel")
struct RepoIssuesViewModelTests {

    private func makeIssue(
        id: Int64,
        number: Int,
        title: String,
        state: GitHubRepoIssueState = .open
    ) -> GitHubRepoIssue {
        GitHubRepoIssue(
            id: id,
            number: number,
            title: title,
            state: state,
            body: nil,
            htmlURL: URL(string: "https://github.com/starcat-app/Starcat/issues/\(number)")!,
            authorLogin: "dong4j",
            labels: [],
            commentsCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            closedAt: nil
        )
    }

    private func listResponse(
        _ issues: [GitHubRepoIssue],
        nextPage: Int? = nil
    ) -> APIResponse<[GitHubRepoIssue]> {
        APIResponse(
            value: issues,
            linkHeader: LinkHeader(nextPage: nextPage, lastPage: nextPage.map { $0 + 1 }),
            rateLimit: .empty,
            statusCode: 200,
            etag: nil
        )
    }

    private func makeEnv() -> (vm: RepoIssuesViewModel, mock: MockGitHubAPIClient) {
        let mock = MockGitHubAPIClient()
        let vm = RepoIssuesViewModel(client: mock)
        vm.prepare(owner: "starcat-app", repo: "Starcat")
        return (vm, mock)
    }

    // MARK: - 列表 / 分页

    @Test("首屏加载并按 Link 头判断 hasMore")
    func firstPageLoads() async throws {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, _, page, _ in
            listResponse([makeIssue(id: 1, number: 12, title: "a")], nextPage: page == 1 ? 2 : nil)
        }

        await vm.loadFirstPageIfNeeded()

        #expect(vm.issues.count == 1)
        #expect(vm.issues.first?.number == 12)
        #expect(vm.hasMore)
        #expect(vm.errorMessage == nil)
        #expect(mock.repoIssuesCalls.count == 1)
        #expect(mock.repoIssuesCalls.first?.state == .open)
    }

    @Test("加载更多追加并按 id 去重")
    func loadMoreDedupes() async {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, _, page, _ in
            switch page {
            case 1:
                return listResponse([makeIssue(id: 1, number: 1, title: "a")], nextPage: 2)
            default:
                // 跨页重复（GitHub 翻页期间 issue 被 update 会出现）：id=1 再次返回。
                return listResponse([
                    makeIssue(id: 1, number: 1, title: "a"),
                    makeIssue(id: 2, number: 2, title: "b")
                ], nextPage: nil)
            }
        }

        await vm.loadFirstPageIfNeeded()
        await vm.loadMoreIfNeeded()

        #expect(vm.issues.map(\.number) == [1, 2])
        #expect(vm.hasMore == false)
        #expect(mock.repoIssuesCalls.count == 2)
    }

    @Test("切换状态筛选触发带新 state 的重载并清空列表")
    func stateFilterReloads() async throws {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, state, _, _ in
            listResponse(state == .open
                ? [makeIssue(id: 1, number: 1, title: "open one")]
                : [makeIssue(id: 9, number: 9, title: "closed one", state: .closed)]
            )
        }
        await vm.loadFirstPageIfNeeded()
        #expect(vm.issues.count == 1)

        vm.setStateFilter(.closed)
        // setStateFilter 内部用 fire-and-forget Task 调 loadFirstPage，等待其完成。
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.stateFilter == .closed)
        #expect(vm.issues.first?.number == 9)
        let calls = mock.repoIssuesCalls
        #expect(calls.count == 2)
        #expect(calls.last?.state == .closed)
    }

    // MARK: - 搜索

    @Test("客户端过滤：标题包含与编号精确匹配")
    func clientFiltering() async {
        let (vm, mock) = makeEnv()
        let issues = [
            makeIssue(id: 1, number: 12, title: "支持按仓库保存草稿"),
            makeIssue(id: 2, number: 34, title: "阅读位置丢失")
        ]
        mock.repoIssuesHandler = { _, _, _, _, _ in listResponse(issues, nextPage: nil) }
        // 兜底搜索挂一个空实现，避免测试结束时未取消的 debounce 任务 fatalError。
        mock.searchIssuesHandler = { _, _, _ in
            APIResponse(
                value: GitHubRepoIssueSearchResult(totalCount: 0, items: []),
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: .empty,
                statusCode: 200,
                etag: nil
            )
        }
        await vm.loadFirstPageIfNeeded()

        // 标题包含（大小写不敏感语义由 localizedCaseInsensitiveContains 承担）。
        vm.searchText = "草稿"
        vm.searchTextChanged()
        #expect(vm.displayedIssues.count == 1)
        #expect(vm.displayedIssues.first?.number == 12)
        #expect(vm.clientFilteredIsEmpty == false)

        // 编号精确匹配。
        vm.searchText = "34"
        vm.searchTextChanged()
        #expect(vm.displayedIssues.count == 1)
        #expect(vm.displayedIssues.first?.number == 34)

        // 都不命中 → 客户端过滤为空（将触发远程兜底）。
        vm.searchText = "9"
        vm.searchTextChanged()
        #expect(vm.displayedIssues.isEmpty)
        #expect(vm.clientFilteredIsEmpty == true)

        // 收尾清空，取消挂起的兜底任务。
        vm.searchText = ""
        vm.searchTextChanged()
    }

    @Test("客户端过滤为空时 debounce 走 Search API 兜底")
    func remoteSearchFallback() async throws {
        let (vm, mock) = makeEnv()
        let issues = [makeIssue(id: 1, number: 12, title: "支持按仓库保存草稿")]
        mock.repoIssuesHandler = { _, _, _, _, _ in listResponse(issues, nextPage: nil) }
        await vm.loadFirstPageIfNeeded()
        #expect(mock.searchIssuesCalls.isEmpty)

        mock.searchIssuesHandler = { query, _, _ in
            APIResponse(
                value: GitHubRepoIssueSearchResult(
                    totalCount: 1,
                    items: [makeIssue(id: 2, number: 99, title: "远程兜底结果")]
                ),
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: .empty,
                statusCode: 200,
                etag: nil
            )
        }

        // 输入不存在于已加载页的关键词 → 客户端过滤为空 → 触发兜底。
        vm.searchText = "完全没有的词"
        vm.searchTextChanged()
        // debounce 350ms，测试里放宽到 900ms 再断言。
        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(mock.searchIssuesCalls.count == 1)
        let query = try #require(mock.searchIssuesCalls.first?.query)
        #expect(query.contains("repo:starcat-app/Starcat"))
        #expect(query.contains("is:issue"))
        #expect(query.contains("is:open"))
        #expect(query.contains("完全没有的词"))
        #expect(vm.displayedIssues.first?.number == 99)
        #expect(vm.remoteSearchTotalCount == 1)
    }

    @Test("清空搜索后回到全量列表")
    func clearingSearchRestoresList() async throws {
        let (vm, mock) = makeEnv()
        let issues = [makeIssue(id: 1, number: 12, title: "支持按仓库保存草稿")]
        mock.repoIssuesHandler = { _, _, _, _, _ in listResponse(issues, nextPage: nil) }
        await vm.loadFirstPageIfNeeded()

        mock.searchIssuesHandler = { _, _, _ in
            APIResponse(
                value: GitHubRepoIssueSearchResult(totalCount: 0, items: []),
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: .empty,
                statusCode: 200,
                etag: nil
            )
        }
        vm.searchText = "zzz"
        vm.searchTextChanged()
        try await Task.sleep(nanoseconds: 900_000_000)
        #expect(vm.displayedIssues.isEmpty)

        vm.searchText = ""
        vm.searchTextChanged()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(vm.remoteSearchResults == nil)
        #expect(vm.displayedIssues.count == 1)
    }

    // MARK: - 精确计数

    @Test("打开时拉取 open / closed 两个精确计数")
    func refreshCounts() async throws {
        let (vm, mock) = makeEnv()
        mock.searchIssuesHandler = { query, _, _ in
            let isOpen = query.contains("is:open")
            return APIResponse(
                value: GitHubRepoIssueSearchResult(totalCount: isOpen ? 12 : 38, items: []),
                linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
                rateLimit: .empty,
                statusCode: 200,
                etag: nil
            )
        }

        await vm.refreshCountsIfNeeded()

        #expect(vm.openCount == 12)
        #expect(vm.closedCount == 38)
        #expect(mock.searchIssuesCalls.count == 2)

        // 已有计数不再重复拉（Search API 限流独立）。
        await vm.refreshCountsIfNeeded()
        #expect(mock.searchIssuesCalls.count == 2)
    }

    // MARK: - 新建回填

    @Test("提交成功后记录高亮并重载列表，随后自动清除高亮")
    func issueDidCreateHighlightsAndReloads() async throws {
        let (vm, mock) = makeEnv()
        let created = makeIssue(id: 3, number: 42, title: "新提交的 issue")
        var responses = 0
        mock.repoIssuesHandler = { _, _, _, _, _ in
            responses += 1
            return listResponse(responses == 1
                ? [makeIssue(id: 1, number: 1, title: "旧 issue")]
                : [created, makeIssue(id: 1, number: 1, title: "旧 issue")]
            )
        }
        await vm.loadFirstPageIfNeeded()

        vm.searchText = "keyword"
        vm.issueDidCreate(created)

        #expect(vm.highlightIssueNumber == 42)
        #expect(vm.searchText == "")
        // 重载被调度（新 issue 按 updated 排第一）。
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(vm.issues.first?.number == 42)

        try await Task.sleep(nanoseconds: 4_200_000_000)
        #expect(vm.highlightIssueNumber == nil)
    }

    // MARK: - 仓库切换 / 错误

    @Test("prepare 切换仓库时整体复位")
    func prepareResetsOnRepoChange() async {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, _, _, _ in
            listResponse([makeIssue(id: 1, number: 1, title: "a")], nextPage: nil)
        }
        await vm.loadFirstPageIfNeeded()
        #expect(vm.issues.isEmpty == false)

        vm.searchText = "keyword"
        vm.setStateFilter(.closed)
        vm.prepare(owner: "other", repo: "repo")

        #expect(vm.issues.isEmpty)
        #expect(vm.searchText == "")
        #expect(vm.stateFilter == .open)
        #expect(vm.openCount == nil)
        #expect(vm.hasMore == false)
    }

    @Test("prepare 同仓库重复调用不清状态")
    func prepareIsIdempotentForSameRepo() async {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, _, _, _ in
            listResponse([makeIssue(id: 1, number: 1, title: "a")], nextPage: nil)
        }
        await vm.loadFirstPageIfNeeded()
        let issuesBefore = vm.issues

        vm.prepare(owner: "starcat-app", repo: "Starcat")
        #expect(vm.issues.count == issuesBefore.count)
    }

    @Test("首屏失败写入错误信息，404 映射为不可访问提示")
    func firstPageFailureMapsError() async throws {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, _, _, _ in
            throw NetworkError.notFound
        }

        await vm.loadFirstPageIfNeeded()

        #expect(vm.issues.isEmpty)
        #expect(vm.hasMore == false)
        let message = try #require(vm.errorMessage)
        #expect(message == RepoIssuesViewModel.listErrorMessage(NetworkError.notFound))
        #expect(message.contains("无法访问"))
    }

    @Test("加载更多失败保留当前页内容")
    func loadMoreFailureKeepsPage() async {
        let (vm, mock) = makeEnv()
        mock.repoIssuesHandler = { _, _, _, page, _ in
            if page == 1 {
                return listResponse([makeIssue(id: 1, number: 1, title: "a")], nextPage: 2)
            }
            throw NetworkError.transport(underlying: URLError(.timedOut))
        }

        await vm.loadFirstPageIfNeeded()
        await vm.loadMoreIfNeeded()

        #expect(vm.issues.count == 1)
        #expect(vm.errorMessage == nil) // 加载更多失败不打断已展示内容
    }
}
