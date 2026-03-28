import SwiftUI

struct ExpandableStatsSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 0) {
            // Header (always visible)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Icon with circle backing
                    ZStack {
                        Circle()
                            .fill(appTheme.accentColor.opacity(0.15))
                            .frame(width: 32, height: 32)
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(appTheme.accentColor)
                    }

                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(theme.glassBackground)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Expandable Content
            if isExpanded {
                content()
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }
}
