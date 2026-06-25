//
//  GitHubStarListsAPI.swift
//  Starcat
//
//  GitHub Stars List GraphQL API 封装。
//
//  设计动机：
//  - Stars List 目前只在 GraphQL 暴露完整 CRUD / membership mutation。
//  - 不引入 Apollo；沿用 `GitHubAPIClient.graphql` 的手写 query + Decodable 模式。
//  - `updateUserListsForItem` 是替换式写入，所以调用方必须传入 repo 的完整目标 list id 集合。
//

import Foundation

extension GitHubAPIClient {

    /// 拉取指定用户的全部 GitHub Stars List 与其中的 Repository items。
    ///
    /// GitHub `User.lists` 与 `UserList.items` 都是 connection；这里在 API 层完整翻页，
    /// 上层同步服务只处理一个完整快照，避免把分页细节泄漏到业务层。
    func starLists(login: String) async throws -> GitHubStarListRemoteSnapshot {
        var lists: [GitHubStarListRemoteRecord] = []
        var memberships: [GitHubStarListRemoteMembership] = []
        var listAfter: String?
        var hasMoreLists = true
        var position = 0

        while hasMoreLists {
            let page = try await starListPage(login: login, after: listAfter)
            for node in page.user?.lists.nodes ?? [] {
                lists.append(node.remoteRecord(position: position))
                memberships.append(contentsOf: node.memberships)
                position += 1

                var itemAfter = node.items?.pageInfo.endCursor
                var hasMoreItems = node.items?.pageInfo.hasNextPage ?? false
                while hasMoreItems {
                    let itemPage = try await starListItems(listId: node.id, after: itemAfter)
                    memberships.append(contentsOf: itemPage.node?.memberships ?? [])
                    itemAfter = itemPage.node?.items.pageInfo.endCursor
                    hasMoreItems = itemPage.node?.items.pageInfo.hasNextPage ?? false
                }
            }
            listAfter = page.user?.lists.pageInfo.endCursor
            hasMoreLists = page.user?.lists.pageInfo.hasNextPage ?? false
        }

        return GitHubStarListRemoteSnapshot(lists: lists, memberships: memberships)
    }

    func createUserList(name: String, description: String?, isPrivate: Bool) async throws -> GitHubStarListRemoteRecord {
        let query = """
        mutation($name: String!, $description: String, $isPrivate: Boolean!) {
          createUserList(input: { name: $name, description: $description, isPrivate: $isPrivate }) {
            list {
              id
              name
              description
              isPrivate
              createdAt
              updatedAt
            }
          }
        }
        """

        struct Response: Decodable {
            let createUserList: Payload
            struct Payload: Decodable {
                let list: ListNode
            }
        }

        let response = try await graphql(
            query: query,
            variables: [
                "name": name,
                "description": description.map { $0 as Any } ?? NSNull(),
                "isPrivate": isPrivate
            ],
            as: Response.self
        )
        return response.createUserList.list.remoteRecord(position: 0)
    }

    func updateUserList(
        id: String,
        name: String,
        description: String?,
        isPrivate: Bool
    ) async throws -> GitHubStarListRemoteRecord {
        let query = """
        mutation($listId: ID!, $name: String!, $description: String, $isPrivate: Boolean!) {
          updateUserList(input: { listId: $listId, name: $name, description: $description, isPrivate: $isPrivate }) {
            list {
              id
              name
              description
              isPrivate
              createdAt
              updatedAt
            }
          }
        }
        """

        struct Response: Decodable {
            let updateUserList: Payload
            struct Payload: Decodable {
                let list: ListNode
            }
        }

        let response = try await graphql(
            query: query,
            variables: [
                "listId": id,
                "name": name,
                "description": description.map { $0 as Any } ?? NSNull(),
                "isPrivate": isPrivate
            ],
            as: Response.self
        )
        return response.updateUserList.list.remoteRecord(position: 0)
    }

    func deleteUserList(id: String) async throws {
        let query = """
        mutation($listId: ID!) {
          deleteUserList(input: { listId: $listId }) {
            user { login }
          }
        }
        """

        struct Response: Decodable {
            let deleteUserList: Payload
            struct Payload: Decodable {
                let user: UserNode?
                struct UserNode: Decodable {
                    let login: String
                }
            }
        }

        _ = try await graphql(
            query: query,
            variables: ["listId": id],
            as: Response.self
        )
    }

    /// 替换某个 repository 所属的完整 Stars List 集合。
    ///
    /// GitHub mutation 要求 `itemId` 是 GraphQL node id，而 Starcat 本地 repo 主键是
    /// REST numeric id，所以这里先按 owner/name 查询 repository node id。
    func updateUserListsForRepository(
        owner: String,
        name: String,
        listIds: [String]
    ) async throws -> [GitHubStarListRemoteRecord] {
        let itemId = try await repositoryNodeID(owner: owner, name: name)
        let query = """
        mutation($itemId: ID!, $listIds: [ID!]!) {
          updateUserListsForItem(input: { itemId: $itemId, listIds: $listIds }) {
            lists {
              id
              name
              description
              isPrivate
              createdAt
              updatedAt
            }
          }
        }
        """

        struct Response: Decodable {
            let updateUserListsForItem: Payload
            struct Payload: Decodable {
                let lists: [ListNode]?
            }
        }

        let response = try await graphql(
            query: query,
            variables: ["itemId": itemId, "listIds": listIds],
            as: Response.self
        )
        return (response.updateUserListsForItem.lists ?? []).enumerated().map { index, node in
            node.remoteRecord(position: index)
        }
    }

    func repositoryNodeID(owner: String, name: String) async throws -> String {
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            id
          }
        }
        """

        struct Response: Decodable {
            let repository: RepositoryNode?
            struct RepositoryNode: Decodable {
                let id: String
            }
        }

        let response = try await graphql(
            query: query,
            variables: ["owner": owner, "name": name],
            as: Response.self
        )
        guard let id = response.repository?.id else {
            throw NetworkError.notFound
        }
        return id
    }

    // MARK: - Internal pages

    private func starListPage(login: String, after: String?) async throws -> StarListPageResponse {
        let query = """
        query($login: String!, $after: String) {
          user(login: $login) {
            lists(first: 100, after: $after) {
              nodes {
                id
                name
                description
                isPrivate
                createdAt
                updatedAt
                items(first: 100) {
                  nodes {
                    ... on Repository {
                      id
                      owner { login }
                      name
                    }
                  }
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
        """
        return try await graphql(
            query: query,
            variables: ["login": login, "after": after.map { $0 as Any } ?? NSNull()],
            as: StarListPageResponse.self
        )
    }

    private func starListItems(listId: String, after: String?) async throws -> StarListItemsPageResponse {
        let query = """
        query($listId: ID!, $after: String) {
          node(id: $listId) {
            ... on UserList {
              id
              items(first: 100, after: $after) {
                nodes {
                  ... on Repository {
                    id
                    owner { login }
                    name
                  }
                }
                pageInfo {
                  hasNextPage
                  endCursor
                }
              }
            }
          }
        }
        """
        return try await graphql(
            query: query,
            variables: ["listId": listId, "after": after.map { $0 as Any } ?? NSNull()],
            as: StarListItemsPageResponse.self
        )
    }
}

// MARK: - Remote Snapshot

struct GitHubStarListRemoteSnapshot: Equatable, Sendable {
    var lists: [GitHubStarListRemoteRecord]
    var memberships: [GitHubStarListRemoteMembership]
}

// MARK: - GraphQL DTOs

private struct StarListPageResponse: Decodable {
    let user: UserNode?

    struct UserNode: Decodable {
        let lists: ListConnection
    }
}

private struct StarListItemsPageResponse: Decodable {
    let node: ListItemsNode?
}

private struct ListConnection: Decodable {
    let nodes: [ListNode]
    let pageInfo: PageInfo
}

private struct ListNode: Decodable {
    let id: String
    let name: String
    let description: String?
    let isPrivate: Bool
    let createdAt: String?
    let updatedAt: String?
    let items: ItemConnection?

    func remoteRecord(position: Int) -> GitHubStarListRemoteRecord {
        GitHubStarListRemoteRecord(
            id: id,
            name: name,
            description: description,
            isPrivate: isPrivate,
            position: position,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var memberships: [GitHubStarListRemoteMembership] {
        (items?.nodes ?? []).map {
            GitHubStarListRemoteMembership(
                listId: id,
                repoFullName: "\($0.owner.login)/\($0.name)"
            )
        }
    }
}

private struct ListItemsNode: Decodable {
    let id: String
    let items: ItemConnection

    var memberships: [GitHubStarListRemoteMembership] {
        items.nodes.map {
            GitHubStarListRemoteMembership(
                listId: id,
                repoFullName: "\($0.owner.login)/\($0.name)"
            )
        }
    }
}

private struct ItemConnection: Decodable {
    let nodes: [RepositoryListItemNode]
    let pageInfo: PageInfo
}

private struct RepositoryListItemNode: Decodable {
    let id: String
    let owner: OwnerNode
    let name: String

    struct OwnerNode: Decodable {
        let login: String
    }
}

private struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}
