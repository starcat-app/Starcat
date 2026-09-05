//
//  AmbientCellView.swift
//  Starcat
//
//  单个稳定槽位的方形内容。只在 Engine 明确标记该 slot 变化时执行两段式
//  Y 轴翻转；在 90° 侧面不可见时换卡，避免新旧 artwork 穿帮或镜像显示。
//

import Foundation
import SwiftUI

/// Ambient 网格中的单格展示。
struct AmbientCellView: View {
    let snapshot: AmbientSlotSnapshot
    let tilePointSize: Double
    let flipDuration: TimeInterval
    let animatesCardChange: Bool

    @State private var displayedCard: AmbientCardModel?
    @State private var rotationDegrees = 0.0
    @State private var transitionGeneration: UInt64 = 0

    init(
        snapshot: AmbientSlotSnapshot,
        tilePointSize: Double,
        flipDuration: TimeInterval,
        animatesCardChange: Bool
    ) {
        self.snapshot = snapshot
        self.tilePointSize = tilePointSize
        self.flipDuration = flipDuration
        self.animatesCardChange = animatesCardChange
        _displayedCard = State(initialValue: snapshot.card)
    }

    var body: some View {
        ZStack {
            if let displayedCard {
                ZStack(alignment: .bottomLeading) {
                    AmbientArtworkView(card: displayedCard, tilePointSize: tilePointSize)

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: tilePointSize * 0.42)

                    Text(displayedCard.title)
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(10)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(displayedCard.title))
            } else {
                Color.black
            }
        }
        .frame(width: tilePointSize, height: tilePointSize)
        .clipped()
        .rotation3DEffect(
            .degrees(rotationDegrees),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.7
        )
        .onChange(of: snapshot.card) { _, newCard in
            updateDisplayedCard(to: newCard)
        }
    }

    private func updateDisplayedCard(to newCard: AmbientCardModel?) {
        guard displayedCard != newCard else { return }
        transitionGeneration &+= 1
        let requestedGeneration = transitionGeneration
        guard animatesCardChange,
              displayedCard != nil,
              newCard != nil,
              flipDuration > 0 else {
            replaceWithoutAnimation(with: newCard)
            return
        }

        let halfDuration = flipDuration / 2
        withAnimation(.easeIn(duration: halfDuration)) {
            rotationDegrees = 90
        } completion: {
            // 场景或 geometry 在翻转中变化时，旧 completion 不能把过期卡片写回当前槽位。
            guard transitionGeneration == requestedGeneration else { return }
            // 正好侧对用户时无动画换面，再从另一侧翻回；角度不越过 90°，不会露出镜像背面。
            replaceWithoutAnimation(with: newCard, rotationDegrees: -90)
            withAnimation(.easeOut(duration: halfDuration)) {
                rotationDegrees = 0
            }
        }
    }

    private func replaceWithoutAnimation(
        with card: AmbientCardModel?,
        rotationDegrees: Double = 0
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedCard = card
            self.rotationDegrees = rotationDegrees
        }
    }
}
