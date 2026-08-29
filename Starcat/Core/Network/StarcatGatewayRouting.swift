//
//  StarcatGatewayRouting.swift
//  Starcat
//
//  自建后端聚合网关分流约定（B 方案）：
//  - 默认生产 baseURL 统一为 https://starcat-api.fly.dev
//  - 业务请求与 `/api/v1/ping` 带短头 `X-SC-Svc: <service>`；聚合 `/healthz` 不带头
//  - 用户自托管：设置页改各服务 baseURL 即可；仍可带同一头（独立进程会忽略未知头）
//
//  与 supports/starcat-api/internal/gateway.HeaderService 必须保持同名同值。
//

import Foundation

/// Starcat 聚合 API 网关的客户端路由辅助。
enum StarcatGatewayRouting {
    /// 与网关 `gateway.HeaderService` 一致。
    static let serviceHeaderName = "X-SC-Svc"

    /// 七个业务 API 的默认聚合入口（不含 license）。
    static let aggregatedProductionURL = URL(string: "https://starcat-api.fly.dev")!

    /// 在请求上写入分流头。`service` 的 rawValue 即网关 byName 键。
    static func applyServiceHeader(to request: inout URLRequest, service: ThirdPartyService) {
        request.setValue(service.rawValue, forHTTPHeaderField: serviceHeaderName)
    }

    /// Star History 已从 Discovery 拆成独立后端，但当前不进入「设置 → 服务」列表，
    /// 因此使用专用入口写入稳定的 `history` 路由名，避免为了一个分流头扩大设置模型。
    static func applyHistoryServiceHeader(to request: inout URLRequest) {
        request.setValue("history", forHTTPHeaderField: serviceHeaderName)
    }
}
