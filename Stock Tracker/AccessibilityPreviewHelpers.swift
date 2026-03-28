//
//  AccessibilityPreviewHelpers.swift
//  Stock Tracker
//

#if DEBUG
import SwiftUI

// MARK: - Accessibility Preview Wrapper

/// Shows a view at multiple Dynamic Type sizes for testing
struct AccessibilityPreview<Content: View>: View {
    let content: Content
    let sizes: [DynamicTypeSize]

    init(
        sizes: [DynamicTypeSize] = [.medium, .xxxLarge, .accessibility3],
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.sizes = sizes
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(sizes, id: \.self) { size in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dynamic Type: \(String(describing: size))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        content
                            .dynamicTypeSize(size)
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
}

// MARK: - Colorblind Mode Preview

/// Shows a view in all colorblind modes side by side
struct ColorblindPreview<Content: View>: View {
    let content: (Theme) -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(ColorblindMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.rawValue)
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal)

                        content(Theme(colorScheme: .dark, colorblindMode: mode))
                            .padding()
                            .background(Color.black)
                            .cornerRadius(12)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
}
#endif
