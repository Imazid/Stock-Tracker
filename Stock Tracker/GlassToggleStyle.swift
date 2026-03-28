//
//  GlassToggleStyle.swift
//  Stock Tracker
//
//  Clean, aesthetic custom toggle style.
//

import SwiftUI

struct GlassToggleStyle: ToggleStyle {

    var tint: Color? = nil

    private let trackWidth: CGFloat = 52
    private let trackHeight: CGFloat = 31
    private let knobSize: CGFloat = 27
    private let knobPadding: CGFloat = 2.0

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label

            ZStack {
                // Track
                Capsule()
                    .fill(configuration.isOn ? activeColor : offColor)
                    .frame(width: trackWidth, height: trackHeight)
                    .shadow(
                        color: configuration.isOn ? activeColor.opacity(0.35) : Color.clear,
                        radius: 8,
                        x: 0,
                        y: 3
                    )

                // Knob
                HStack {
                    if configuration.isOn { Spacer() }

                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
                        .frame(width: knobSize, height: knobSize)

                    if !configuration.isOn { Spacer() }
                }
                .padding(.horizontal, knobPadding)
                .frame(width: trackWidth, height: trackHeight)
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    configuration.isOn.toggle()
                }
            }
        }
    }

    private var activeColor: Color {
        tint ?? Color(red: 0.35, green: 0.55, blue: 0.52)
    }

    private var offColor: Color {
        Color(UIColor.systemGray4)
    }
}

// MARK: - Convenience

extension ToggleStyle where Self == GlassToggleStyle {
    static var glass: GlassToggleStyle { GlassToggleStyle() }

    static func glass(tint: Color) -> GlassToggleStyle {
        GlassToggleStyle(tint: tint)
    }
}
