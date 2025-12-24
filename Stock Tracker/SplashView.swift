//
//  SplashView.swift
//  Stock Tracker
//

import SwiftUI

struct SplashView: View {
    @State private var startAnimation = false
    @State private var showLogo = false
    @State private var chartProgress: CGFloat = 0.0
    @State private var particleOffset: CGFloat = 0.0
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            BackgroundGlowLayers()
                .opacity(startAnimation ? 1 : 0)
            
            RisingParticles()
                .offset(y: particleOffset)
                .opacity(startAnimation ? 1 : 0)
            
            GlowingLineChart(progress: chartProgress)
                .opacity(startAnimation ? 0.6 : 0)
            
            VStack(spacing: 32) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 90, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .blue.opacity(0.8), radius: 20)
                    .shadow(color: .purple.opacity(0.6), radius: 40)
                    .scaleEffect(showLogo ? 1.0 : 0.5)
                    .opacity(showLogo ? 1.0 : 0)
                
                Text("Markets")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .blue.opacity(0.5), radius: 10)
                    .opacity(showLogo ? 1.0 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0)) {
                startAnimation = true
            }
            
            withAnimation(.easeOut(duration: 2.5).delay(0.5)) {
                chartProgress = 1.0
            }
            
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                particleOffset = -UIScreen.main.bounds.height * 2
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                    showLogo = true
                }
            }
        }
    }
}

// MARK: - Safe Glowing Line Chart
struct GlowingLineChart: View {
    let progress: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            if geo.size.width > 0 && geo.size.height > 0 {  // Safety guard
                Path { path in
                    let width = geo.size.width
                    let height = geo.size.height
                    let points = generateChartPoints(count: 30, width: width, height: height)
                    
                    guard !points.isEmpty else { return }
                    
                    path.move(to: points[0])
                    
                    let maxIndex = min(points.count - 1, max(1, Int(CGFloat(points.count) * progress)))
                    for i in 1...maxIndex {
                        path.addLine(to: points[i])
                    }
                }
                .strokedPath(StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan.opacity(0.8), .blue, .purple.opacity(0.9)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: .cyan.opacity(0.8), radius: 10)
                .shadow(color: .purple.opacity(0.6), radius: 20)
            }
        }
        .padding(40)
    }
    
    private func generateChartPoints(count: Int, width: CGFloat, height: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        guard count > 1 && width > 0 else { return points }
        
        let step = width / CGFloat(count - 1)
        var previousY = height * 0.8
        
        points.append(CGPoint(x: 0, y: previousY))
        
        for i in 1..<count {
            let x = CGFloat(i) * step
            let randomFluctuation = CGFloat.random(in: -30...30)
            var newY = previousY - CGFloat.random(in: 15...40) + randomFluctuation
            newY = max(min(newY, height * 0.9), height * 0.2)
            points.append(CGPoint(x: x + CGFloat.random(in: -1...1), y: newY))  // Tiny x jitter to avoid duplicates
            previousY = newY
        }
        
        return points
    }
}

// RisingParticles and BackgroundGlowLayers remain unchanged from previous version

struct RisingParticles: View {
    var body: some View {
        ForEach(0..<15) { i in
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.cyan.opacity(0.8), .purple.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: CGFloat.random(in: 6...14))
                .shadow(color: .blue.opacity(0.6), radius: 8)
                .offset(x: CGFloat.random(in: -180...180))
                .offset(y: CGFloat.random(in: 0...UIScreen.main.bounds.height))
        }
    }
}

struct BackgroundGlowLayers: View {
    @State private var pulse: CGFloat = 0.8
    
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.blue.opacity(0.2), .purple.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                .frame(width: 600)
                .offset(x: -100, y: -200)
                .blur(radius: 100)
                .scaleEffect(pulse)
            
            Circle()
                .fill(LinearGradient(colors: [.cyan.opacity(0.15), .blue.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 500)
                .offset(x: 150, y: -300)
                .blur(radius: 120)
                .scaleEffect(pulse * 1.1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                pulse = 1.3
            }
        }
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
