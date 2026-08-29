//
//  StarcatGatewayRoutingTests.swift
//  StarcatTests
//
//  固化聚合网关 B 方案的客户端契约：七个服务共用生产 Host，
//  业务请求仍通过 X-SC-Svc 精确选择后端服务；聚合 /healthz 是无头例外。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Starcat 聚合网关路由")
struct StarcatGatewayRoutingTests {
    @Test("七个服务生产 URL 统一指向聚合入口")
    func productionURLsUseAggregateHost() {
        let expected = URL(string: "https://starcat-api.fly.dev")!
        let productionURLs = [
            AppEndpoints.Trending.productionURL,
            AppEndpoints.Weekly.productionURL,
            AppEndpoints.Sharing.productionURL,
            AppEndpoints.Wiki.productionURL,
            AppEndpoints.Recommend.productionURL,
            AppEndpoints.Discovery.productionURL,
            AppEndpoints.History.productionURL,
        ]

        #expect(productionURLs.allSatisfy { $0 == expected })
    }

    @Test("服务枚举 rawValue 写入 X-SC-Svc")
    func appliesServiceHeaderForEveryService() {
        for service in ThirdPartyService.allCases {
            var request = URLRequest(url: StarcatGatewayRouting.aggregatedProductionURL)
            StarcatGatewayRouting.applyServiceHeader(to: &request, service: service)

            #expect(
                request.value(forHTTPHeaderField: StarcatGatewayRouting.serviceHeaderName) == service.rawValue,
                "\(service.rawValue) 必须写入聚合分流头"
            )
        }
    }

    @Test("History 使用独立聚合路由名")
    func appliesHistoryServiceHeader() {
        var request = URLRequest(url: StarcatGatewayRouting.aggregatedProductionURL)
        StarcatGatewayRouting.applyHistoryServiceHeader(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-SC-Svc") == "history")
    }
}
