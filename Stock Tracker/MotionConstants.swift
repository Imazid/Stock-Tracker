//
//  MotionConstants.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 27/1/2026.
//


//
//  MotionSystem.swift
//  Stock Tracker
//
//  PHASE 10 - Sliding Cards & Focus-Based Motion System
//

import SwiftUI

// MARK: - Motion Constants

struct MotionConstants {
    // Scale values
    static let focusedScale: CGFloat = 1.05
    static let unfocusedScale: CGFloat = 0.95
    
    // Opacity values
    static let focusedOpacity: Double = 1.0
    static let unfocusedOpacity: Double = 0.6
    
    // Elevation
    static let focusedShadowRadius: CGFloat = 20
    static let unfocusedShadowRadius: CGFloat = 5
    
    // Animation curves
    static let springResponse: Double = 0.4
    static let springDamping: Double = 0.75
    
    // Timing
    static let transitionDuration: Double = 0.3
}

// MARK: - Focus Card Modifier

struct FocusCardModifier: ViewModifier {
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1.0 : (isFocused ? MotionConstants.focusedScale : MotionConstants.unfocusedScale))
            .opacity(isFocused ? MotionConstants.focusedOpacity : MotionConstants.unfocusedOpacity)
            .shadow(
                color: .black.opacity(isFocused ? 0.3 : 0.1),
                radius: isFocused ? MotionConstants.focusedShadowRadius : MotionConstants.unfocusedShadowRadius,
                y: isFocused ? 10 : 3
            )
            .animation(
                reduceMotion ? nil : .spring(response: MotionConstants.springResponse, dampingFraction: MotionConstants.springDamping),
                value: isFocused
            )
    }
}

extension View {
    func focusCard(isFocused: Bool) -> some View {
        modifier(FocusCardModifier(isFocused: isFocused))
    }
}

// MARK: - Scrollable Focus Card Container

struct ScrollableFocusCards<Content: View>: View {
    let cardWidth: CGFloat
    let spacing: CGFloat
    let content: Content
    
    @State private var focusedIndex: Int = 0
    
    init(
        cardWidth: CGFloat = 320,
        spacing: CGFloat = 20,
        @ViewBuilder content: () -> Content
    ) {
        self.cardWidth = cardWidth
        self.spacing = spacing
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    content
                        .frame(width: cardWidth)
                }
                .padding(.horizontal, (geometry.size.width - cardWidth) / 2)
            }
            .scrollTargetBehavior(.paging)
        }
    }
}

// MARK: - Focus-Aware Card Wrapper

struct FocusAwareCard<Content: View>: View {
    let content: Content
    let index: Int
    @Binding var focusedIndex: Int
    
    init(
        index: Int,
        focusedIndex: Binding<Int>,
        @ViewBuilder content: () -> Content
    ) {
        self.index = index
        self._focusedIndex = focusedIndex
        self.content = content()
    }
    
    var body: some View {
        content
            .focusCard(isFocused: focusedIndex == index)
    }
}