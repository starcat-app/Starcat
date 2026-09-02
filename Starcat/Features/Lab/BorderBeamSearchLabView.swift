//
//  BorderBeamSearchLabView.swift
//  Starcat
//
//  Border Beam 搜索条实验窗口内容。
//
//  入口：DEBUG 菜单「Who's Your Daddy → Border Beam Search Lab」。
//  用途：对照上游 demo（beam.jakubantalik.com）验收 `size: .line` 视觉，
//  不替换、不接线正式 `SmartSearchField`。
//

#if DEBUG
import BorderBeamKit
import SwiftUI

/// Border Beam Search 实验台：可调 colorVariant / theme / strength / active。
struct BorderBeamSearchLabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var lastSubmitted = ""
    @State private var colorVariant: BeamColorVariant = .colorful
    @State private var theme: BeamTheme = .auto
    @State private var isBeamActive = true
    @State private var strength: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            BorderBeamSearchField(
                text: $query,
                isBeamActive: isBeamActive,
                colorVariant: colorVariant,
                theme: theme,
                strength: strength,
                onSubmit: { submitted in
                    lastSubmitted = submitted
                }
            )
            .frame(maxWidth: 420)

            controls

            footer
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Border Beam Search Lab")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)

            Text(verbatim: "Independent from SmartSearchField. Validate upstream line beam before replacing toolbar search.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        Form {
            Picker(selection: $colorVariant) {
                ForEach(BeamColorVariant.allCases, id: \.self) { variant in
                    Text(verbatim: variant.rawValue.capitalized).tag(variant)
                }
            } label: {
                Text(verbatim: "Color Variant")
            }
            .pickerStyle(.segmented)

            Picker(selection: $theme) {
                Text(verbatim: "Auto").tag(BeamTheme.auto)
                Text(verbatim: "Dark").tag(BeamTheme.dark)
                Text(verbatim: "Light").tag(BeamTheme.light)
            } label: {
                Text(verbatim: "Theme")
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $isBeamActive) {
                Text(verbatim: "Beam Active")
            }

            HStack {
                Text(verbatim: "Strength")
                Slider(value: $strength, in: 0...1, step: 0.05)
                Text(verbatim: String(format: "%.2f", strength))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Preset: size=.line  duration=3.1  borderRadius=20  height=42")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(verbatim: "Color scheme: \(colorScheme == .dark ? "dark" : "light") · Reduce Motion: \(reduceMotion ? "on" : "off")")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            if !lastSubmitted.isEmpty {
                Text(verbatim: "Last submit: \(lastSubmitted)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("BorderBeamSearchLabView") {
    BorderBeamSearchLabView()
}
#endif
