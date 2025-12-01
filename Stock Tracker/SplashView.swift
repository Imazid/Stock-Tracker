//
//  SplashView.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 1/12/2025.
//


import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            // Dark background to match the app
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.05, green: 0.05, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 16) {
                // App icon style circle
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                }
                
                Text("Markets")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Loading your stocks & crypto…")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                
//                ProgressView()
//                    .progressViewStyle(.circular)
//                    .tint(.white)
//                    .padding(.top, 8)
            }
        }
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
