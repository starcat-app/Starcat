//
//  CompanionRequestParser.swift
//  Starcat
//
//  Chrome Companion 本机 HTTP 服务的最小请求解析器。
//
//  设计约束:
//  - 本服务只服务 loopback 上的 Chrome 插件, 不需要实现完整 HTTP server 语义;
//  - 解析边界必须显式失败, 不能使用 `Dictionary(uniqueKeysWithValues:)` 这类
//    遇到重复 key 会触发运行时 trap 的 API;
//  - query 使用严格策略: 重复 key 视为 bad request, 避免调用方拿到不确定参数;
//  - header 使用宽松策略: 重复 header 保留 first value, 因为现实 HTTP 客户端可能
//    合法发送多个同名 header, Companion 只读取 Authorization/Origin/Host 等单值头。
//

import Foundation

struct CompanionHTTPRequest: Equatable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

enum CompanionHTTPRequestError: Error, Equatable {
    case headerTooLarge
    case bodyTooLarge
    case malformedRequest
    case invalidTarget
    case duplicateQueryKey(String)
}

enum CompanionRequestParser {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    static func parse(_ data: Data) throws -> CompanionHTTPRequest {
        guard data.count <= maximumHeaderBytes + maximumBodyBytes else {
            throw CompanionHTTPRequestError.bodyTooLarge
        }
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw CompanionHTTPRequestError.malformedRequest
        }
        guard headerRange.lowerBound <= maximumHeaderBytes else {
            throw CompanionHTTPRequestError.headerTooLarge
        }

        let headerData = data[..<headerRange.lowerBound]
        let bodyStart = headerRange.upperBound
        let body = Data(data[bodyStart...])
        guard body.count <= maximumBodyBytes else {
            throw CompanionHTTPRequestError.bodyTooLarge
        }
        guard let rawHeader = String(data: headerData, encoding: .utf8) else {
            throw CompanionHTTPRequestError.malformedRequest
        }

        let lines = rawHeader.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw CompanionHTTPRequestError.malformedRequest
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3 else {
            throw CompanionHTTPRequestError.malformedRequest
        }

        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let (path, query) = try parseTarget(target)
        let headers = parseHeaders(lines.dropFirst())

        return CompanionHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func parseTarget(_ target: String) throws -> (String, [String: String]) {
        guard target.hasPrefix("/") else {
            throw CompanionHTTPRequestError.invalidTarget
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              let path = components.path.removingPercentEncoding,
              path.hasPrefix("/") else {
            throw CompanionHTTPRequestError.invalidTarget
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil else {
                throw CompanionHTTPRequestError.duplicateQueryKey(item.name)
            }
            query[item.name] = item.value ?? ""
        }
        return (path, query)
    }

    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { continue }
            headers[key] = value
        }
        return headers
    }
}
