//
//  AgentRepositoryReadCapabilitySource.swift
//  Starcat
//
//  Agent 冻结仓库上下文到统一 Repository Read Capability 的数据源适配器。
//
//  关键约束：该适配器只持有 Agent run 启动时生成的快照，任何查询都不能回读实时数据库。
//  这样即使 MCP 与 Agent 共用业务 executor，Agent 的 `.only / .prefer / .exclude` 边界也
//  不会在长任务执行期间随数据库变化而扩大。
//

import Foundation

extension AgentRepoSnapshot: RepositoryCapabilityItem {}

/// 把单次 Agent run 的仓库快照暴露为只读 Capability Source。
struct FrozenRepositoryReadCapabilitySource: RepositoryReadCapabilitySource {
    let repositories: [AgentRepoSnapshot]

    /// 返回完整冻结集合；调用方仍可通过 capability request 施加更窄的 repo ID 限制。
    func list() async throws -> [AgentRepoSnapshot] { repositories }

    /// 在冻结集合内提供本地文本匹配。
    ///
    /// 当前迁移的 Agent tools 没有 query 参数，此实现只保证 Source 协议完备，不能宣称与
    /// MCP 数据库 FTS 等价。
    func search(query: String) async throws -> [AgentRepoSnapshot] {
        repositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.language?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// 仅在冻结集合中按 GitHub repo ID 精确选择。
    func findByID(_ repoID: Int64) async throws -> AgentRepoSnapshot? {
        repositories.first { $0.id == repoID }
    }

    /// 仅在冻结集合中按 owner/name 大小写不敏感地精确选择。
    func findByOwnerName(owner: String, name: String) async throws -> AgentRepoSnapshot? {
        repositories.first {
            $0.owner.caseInsensitiveCompare(owner) == .orderedSame
                && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
