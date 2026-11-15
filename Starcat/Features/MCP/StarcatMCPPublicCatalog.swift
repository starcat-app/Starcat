//
//  StarcatMCPPublicCatalog.swift
//  Starcat
//
//  新增公共能力的单一目录：Schema 与工具注册共用，CLI 动态发现后即可调用。
//  目录声明支持范围；实际账号、Pro、写入与隐私状态仍由 App 执行期检查。
//

import Foundation
import MCP

/// 新能力必须在同一条目描述权限、副作用、联网与任务语义，禁止为 CLI 另维护业务名单。
struct StarcatMCPPublicSpec {
    let name: String
    let summary: String
    let properties: [String: Value]
    var required: [String] = []
    var permission = "read"
    var network = "none"
    var task = false

    var schema: Value {
        .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)
        ])
    }

    var tool: Tool {
        Tool(
            name: "starcat.\(name)", title: summary, description: summary,
            inputSchema: schema,
            annotations: .init(readOnlyHint: permission == "read", openWorldHint: network != "none")
        )
    }
}

/// 只开放真实可装配执行器，不把 GUI、系统授权和规划功能伪装成可执行工具。
@MainActor
enum StarcatMCPPublicCatalog {
    static func string(_ values: [String]? = nil) -> Value {
        var value: [String: Value] = ["type": .string("string"), "minLength": .int(1), "maxLength": .int(16_384)]
        if let values { value["enum"] = .array(values.map(Value.string)) }
        return .object(value)
    }

    static func integer(_ minimum: Int = 1, _ maximum: Int = 200) -> Value {
        .object(["type": .string("integer"), "minimum": .int(minimum), "maximum": .int(maximum)])
    }

    static let boolean: Value = .object(["type": .string("boolean")])
    static let selector: [String: Value] = [
        "repo_id": integer(1, Int.max), "owner": string(), "name": string()
    ]
    static let pagination: [String: Value] = ["limit": integer(), "offset": integer(0, 10_000)]
    static let preview: [String: Value] = ["dry_run": .object(["type": .string("boolean"), "default": .bool(true)])]
    static let ids: Value = .object([
        "type": .string("array"), "items": integer(1, Int.max), "minItems": .int(1), "maxItems": .int(30)
    ])
    static let radar: [String: Value] = [
        "category": string(), "period": string(["daily", "weekly", "monthly"]),
        "language": string(), "fallback": boolean, "date_from": string(), "date_to": string(),
        "catalog_revision": string(), "cursor": string(), "limit": integer(1, 100)
    ]

    static let specs: [StarcatMCPPublicSpec] = [
        .init(name: "get_public_settings", summary: "Read non-secret integration settings and channel information.", properties: [:]),
        .init(name: "get_repo_health", summary: "Read the cached health snapshot without refreshing or fetching.", properties: selector),
        .init(name: "get_repo_security", summary: "Read the cached OpenSSF snapshot without fetching.", properties: selector),
        .init(name: "get_repo_star_history", summary: "Read a bounded page of cached Star history for a local repository.", properties: selector.merging(pagination) { _, new in new }),
        .init(name: "get_repo_insights", summary: "Read a named cached repository insight dataset; missing cache never starts a refresh.", properties: selector.merging([
            "dataset": string(RepositoryInsightsDataset.allCases.map(\.rawValue)),
            "range": string(RepositoryInsightsRangeKey.allCases.map(\.rawValue))
        ]) { _, new in new }, required: ["dataset"]),
        .init(name: "list_releases", summary: "Read cached releases by repository, or the local release timeline.", properties: selector.merging(pagination) { _, new in new }),
        .init(name: "list_release_subscriptions", summary: "Read the local release subscription state.", properties: pagination),
        .init(name: "list_notifications", summary: "Read the cached notification and Issue/PR inbox without remote hydration.", properties: pagination),
        .init(name: "get_notification", summary: "Read one cached notification or Issue/PR conversation.", properties: ["id": string()], required: ["id"]),
        .init(name: "list_collections", summary: "Read local smart collection definitions.", properties: pagination),
        .init(name: "list_languages", summary: "Read language aggregates for Starred or Knowledge repositories.", properties: ["scope": string(["starred", "knowledge"])]),
        .init(name: "list_trending", summary: "Read cached Trending with period, language and pagination.", properties: pagination.merging([
            "period": string(["daily", "weekly", "monthly"]), "language": string()
        ]) { _, new in new }),
        .init(name: "list_discovery", summary: "Read cached Discovery repositories; never fetch missing data.", properties: pagination.merging(["query": string()]) { _, new in new }),
        .init(name: "list_weekly", summary: "Read cached Weekly repositories and source provenance.", properties: pagination.merging(["query": string(), "language": string()]) { _, new in new }),
        .init(name: "list_awesome_sources", summary: "Read Awesome sources, availability and subscription state.", properties: pagination),
        .init(name: "list_awesome_repos", summary: "Read cached Awesome repositories and source evidence.", properties: pagination.merging(["source_id": string()]) { _, new in new }),
        .init(name: "list_awesome_resources", summary: "Read cached non-repository Awesome resources.", properties: pagination.merging(["source_id": string()]) { _, new in new }),
        .init(name: "list_daily_radar_catalog", summary: "Read the cached Daily Radar / Weekly AI Highlights catalog within the configured service namespace.", properties: radar),
        .init(name: "list_daily_radar", summary: "Read a cached Daily Radar page with source, revision and cursor; a cache miss never fetches.", properties: radar),
        .init(name: "get_daily_radar_report", summary: "Read a pinned cached Daily Radar report; exact language and revision are required.", properties: [
            "id": string(), "language": string(), "revision": string()
        ], required: ["id", "language", "revision"]),
        .init(name: "get_repo_recommendations", summary: "Read cached similar repositories in the current recommendation service scope.", properties: selector.merging(pagination) { _, new in new }),
        .init(name: "get_repo_skills", summary: "Read already loaded repository Skill evidence without starting a scan or installing files.", properties: selector),
        .init(name: "get_repo_library_state", summary: "Read Knowledge membership without returning the private note body.", properties: selector),
        .init(name: "set_repo_library_state", summary: "Preview or change Knowledge membership for a local repository. Existing App index follow-up may run; removal requires destructive writes.", properties: selector.merging(preview) { _, new in new }.merging([
            "state": string(LibraryState.allCases.map(\.rawValue))
        ]) { _, new in new }, required: ["state"], permission: "write", network: "configured_index_follow_up"),
        .init(name: "get_repo_translation", summary: "Read an existing README translation cache; never start translation, a WebView or a system permission prompt.", properties: selector.merging([
            "target_language": string(ReadmeTranslationLanguage.allCases.filter { $0 != .auto }.map(\.rawValue)),
            "mode": string(["segmented", "full"]), "engine": string(["ai", "system", "google"])
        ]) { _, new in new }, required: ["target_language"]),
        .init(name: "start_translation", summary: "Explicitly translate caller-supplied plain-text segments using the configured AI. Separate cache; does not modify repository README or its DOM translation cache.", properties: preview.merging([
            "target_language": string(ReadmeTranslationLanguage.allCases.filter { $0 != .auto }.map(\.rawValue)),
            "segments": .object([
                "type": .string("array"), "minItems": .int(1), "maxItems": .int(30),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object(["id": string(), "text": string()]),
                    "required": .array([.string("id"), .string("text")]),
                    "additionalProperties": .bool(false)
                ])
            ])
        ]) { _, new in new }, required: ["target_language", "segments"], permission: "generate", network: "configured_ai", task: true),
        .init(name: "list_ai_models", summary: "Read configured provider/model availability, without keys, endpoints, parameters or connection tests.", properties: pagination),
        .init(name: "list_agent_runs", summary: "Read Direct-channel run identifiers and states, without prompts, context, traces or artifacts.", properties: pagination),
        .init(name: "get_diagnostic_health", summary: "Read aggregate diagnostic storage health only; no raw log, file path or refresh.", properties: [:]),
        .init(name: "list_knowledge_chunks", summary: "Read bounded indexed Knowledge content; private notes require explicit permission.", properties: selector.merging(pagination) { _, new in new }.merging([
            "include_private_notes": boolean
        ]) { _, new in new }),
        .init(name: "knowledge_search", summary: "Retrieve evidence and citations within explicit Knowledge repository IDs; no answer generation or index rebuild.", properties: [
            "query": string(), "repo_ids": ids, "include_private_notes": boolean
        ], required: ["query", "repo_ids"], network: "configured_embedding_and_reranker"),
        .init(name: "start_summary", summary: "Explicitly start cached-or-generated repository summary as an App-owned task; may consume AI quota.", properties: selector.merging(preview) { _, new in new }, permission: "generate", network: "configured_ai", task: true),
        .init(name: "start_tag_suggestions", summary: "Explicitly generate tag suggestions; suggestions are never automatically applied.", properties: selector.merging(preview) { _, new in new }, permission: "generate", network: "configured_ai", task: true),
        .init(name: "start_note_draft", summary: "Explicitly generate a note draft from cached README. Optional existing notes require private-note permission. Returns a draft and never saves the user's note.", properties: selector.merging(preview) { _, new in new }.merging([
            "include_private_notes": boolean
        ]) { _, new in new }, permission: "generate", network: "configured_ai", task: true),
        .init(name: "start_sync", summary: "Start a real GitHub Stars synchronization. Query task status after timeout; never blindly replay.", properties: preview.merging(["force": boolean]) { _, new in new }, permission: "write", network: "github", task: true),
        .init(name: "get_sync_status", summary: "Read the real Stars sync state and known progress; no fabricated percentages.", properties: [:]),
        .init(name: "start_knowledge_index", summary: "Explicitly rebuild Knowledge sources and configured indexes as an App task; may download README and consume embedding quota. Optional selector limits to one Knowledge repository.", properties: selector.merging(preview) { _, new in new }, permission: "write", network: "github_and_configured_indexes", task: true),
        .init(name: "get_task_status", summary: "Read a process-local public task state; retained for one hour after completion.", properties: ["task_id": string()], required: ["task_id"]),
        .init(name: "get_task_result", summary: "Read a finished public task result; account change and App restart invalidate handles.", properties: ["task_id": string()], required: ["task_id"]),
        .init(name: "cancel_task", summary: "Request cancellation of a public task. Cancelling is not cancelled until its executor exits.", properties: preview.merging(["task_id": string()]) { _, new in new }, required: ["task_id"], permission: "write"),
        .init(name: "mark_release_read", summary: "Preview or set a cached Release read state, with read-back verification.", properties: preview.merging([
            "release_id": integer(1, Int.max), "is_read": boolean
        ]) { _, new in new }, required: ["release_id", "is_read"], permission: "write"),
        .init(name: "unsubscribe_release", summary: "Preview or cancel a Release subscription for a local repository.", properties: selector.merging(preview) { _, new in new }, permission: "write"),
        .init(name: "set_release_notifications", summary: "Preview or change notification delivery for an existing Release subscription.", properties: selector.merging(preview) { _, new in new }.merging([
            "enabled": boolean
        ]) { _, new in new }, required: ["enabled"], permission: "write"),
        .init(name: "export_repositories", summary: "Render a bounded Starred or Knowledge collection as Markdown/HTML. Returns content; the CLI caller owns output files. Does not include private notes.", properties: [
            "scope": string(["starred", "knowledge"]), "format": string(["markdown", "html"]), "limit": integer(1, 1000)
        ])
    ]
}

/// 公共工具入口再次验证结构与范围。CLI 校验仅用于早反馈，不能成为 App 的信任边界。
enum StarcatMCPInputValidator {
    static func validate(_ value: Value, schema: Value, path: String = "arguments") throws {
        let rules = schema.objectValue ?? [:]
        func invalid(_ reason: String) throws {
            throw StarcatMCPError.invalidArguments("\(path): \(reason)")
        }
        switch rules["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue else { try invalid("must be an object"); return }
            let properties = rules["properties"]?.objectValue ?? [:]
            for key in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
                try invalid("missing required argument \(key)")
            }
            for (key, nested) in object {
                guard let field = properties[key] else {
                    if rules["additionalProperties"]?.boolValue == false { try invalid("unknown argument \(key)") }
                    continue
                }
                try validate(nested, schema: field, path: "\(path).\(key)")
            }
        case "array":
            guard let array = value.arrayValue else { try invalid("must be an array"); return }
            if let minimum = rules["minItems"]?.intValue, array.count < minimum { try invalid("too few items") }
            if let maximum = rules["maxItems"]?.intValue, array.count > maximum { try invalid("too many items") }
            if let items = rules["items"] {
                for (index, nested) in array.enumerated() { try validate(nested, schema: items, path: "\(path)[\(index)]") }
            }
        case "string":
            guard let text = value.stringValue else { try invalid("must be a string"); return }
            if let minimum = rules["minLength"]?.intValue, text.count < minimum { try invalid("too short") }
            if let maximum = rules["maxLength"]?.intValue, text.count > maximum { try invalid("too long") }
            if let choices = rules["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.contains(text) { try invalid("unknown value") }
        case "integer":
            guard let number = value.intValue else { try invalid("must be an integer"); return }
            if let minimum = rules["minimum"]?.intValue, number < minimum { try invalid("below minimum") }
            if let maximum = rules["maximum"]?.intValue, number > maximum { try invalid("above maximum") }
        case "boolean":
            guard value.boolValue != nil else { try invalid("must be a boolean"); return }
        default:
            break
        }
    }
}
