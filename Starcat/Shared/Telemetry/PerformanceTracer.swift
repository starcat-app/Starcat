//
//  PerformanceTracer.swift
//  Starcat
//
//  Local performance tracing backed by OSSignposter.
//
//  These spans are for Instruments / Points of Interest, not remote analytics.
//  The names are centralized because `OSSignposter` requires `StaticString`;
//  allowing arbitrary runtime strings would either fail to compile or tempt
//  call sites to smuggle user data into signpost names.
//

import Foundation
import OSLog

enum PerformanceSpan: Sendable {
    case appBootstrap
    case manageInitialLoad
    case manageLoadMore
    case activityInitialLoad
    case activityLoadMore
    case searchQuery
    case readmeLoad
    case aiStreamResponse
    case repoContextPack
}

final class PerformanceTracer: @unchecked Sendable {

    static let shared = PerformanceTracer()

    private let signposter = OSSignposter(
        logger: Logger(subsystem: AppConstants.bundleIdentifier, category: "performance")
    )

    private init() {}

    @discardableResult
    func trace<T>(_ span: PerformanceSpan, operation: () throws -> T) rethrows -> T {
        switch span {
        case .appBootstrap:
            return try trace("app.bootstrap", operation: operation)
        case .manageInitialLoad:
            return try trace("manage.initial_load", operation: operation)
        case .manageLoadMore:
            return try trace("manage.load_more", operation: operation)
        case .activityInitialLoad:
            return try trace("activity.initial_load", operation: operation)
        case .activityLoadMore:
            return try trace("activity.load_more", operation: operation)
        case .searchQuery:
            return try trace("search.query", operation: operation)
        case .readmeLoad:
            return try trace("readme.load", operation: operation)
        case .aiStreamResponse:
            return try trace("ai.stream_response", operation: operation)
        case .repoContextPack:
            return try trace("repo_context.pack", operation: operation)
        }
    }

    @discardableResult
    func trace<T>(_ span: PerformanceSpan, operation: () async throws -> T) async rethrows -> T {
        switch span {
        case .appBootstrap:
            return try await trace("app.bootstrap", operation: operation)
        case .manageInitialLoad:
            return try await trace("manage.initial_load", operation: operation)
        case .manageLoadMore:
            return try await trace("manage.load_more", operation: operation)
        case .activityInitialLoad:
            return try await trace("activity.initial_load", operation: operation)
        case .activityLoadMore:
            return try await trace("activity.load_more", operation: operation)
        case .searchQuery:
            return try await trace("search.query", operation: operation)
        case .readmeLoad:
            return try await trace("readme.load", operation: operation)
        case .aiStreamResponse:
            return try await trace("ai.stream_response", operation: operation)
        case .repoContextPack:
            return try await trace("repo_context.pack", operation: operation)
        }
    }

    @discardableResult
    private func trace<T>(_ name: StaticString, operation: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try operation()
    }

    @discardableResult
    private func trace<T>(_ name: StaticString, operation: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await operation()
    }
}
