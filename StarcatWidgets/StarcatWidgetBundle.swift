//
//  StarcatWidgetBundle.swift
//  StarcatWidgets
//
//  Store 与 Direct Widget Extension 共用的唯一入口。
//

import SwiftUI
import WidgetKit

@main
struct StarcatWidgetBundle: WidgetBundle {
    var body: some Widget {
        StarcatFocusWidget()
        StarcatRediscoveryWidget()
        StarcatReleaseWatchWidget()
        StarcatCollectionTrendWidget()
    }
}
