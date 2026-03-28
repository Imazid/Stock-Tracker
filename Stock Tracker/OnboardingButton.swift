//
//  OnboardingButton.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 24/1/2026.
//


//
//  OnboardingButton.swift
//  Stock Tracker
//

import SwiftUI

struct OnboardingButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }) {
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        colors: disabled ? [.gray, .gray.opacity(0.8)] : [.blue, .blue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(16)
                .shadow(color: disabled ? .clear : .blue.opacity(0.4), radius: 15, y: 8)
                .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .disabled(disabled)
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        isPressed = false
                    }
                }
        )
    }
}