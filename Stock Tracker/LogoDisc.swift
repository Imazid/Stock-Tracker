//
//  LogoDisc.swift
//  Stock Tracker
//
//  The disc behind a company / coin logo. Most logos are drawn for a white
//  background, but some are white marks on a transparent PNG (Visa, XRP,
//  Cardano, QQQ, Amazon's wordmark) and vanished on a white disc. Those get a
//  dark disc; everything else gets white, toned down in dark mode so a list of
//  logos doesn't glare (MoonPay / Phantom on Mobbin use soft or brand discs).
//

import SwiftUI

@MainActor
enum LogoDisc {
    /// Per logo URL: true when its visible pixels are almost all light.
    private static var lightMarks: [String: Bool] = [:]

    static func fill(for image: Image, key: String, dark: Bool) -> Color {
        if isLightMark(image, key: key) { return Color(white: 0.13) }
        return dark ? Color(white: 0.9) : .white
    }

    /// Renders the logo once at 24×24 and looks at its opaque pixels: a mostly
    /// transparent image whose ink is near-white needs a dark backdrop. Logos with
    /// their own solid background (BHP, Apple) are mostly opaque and stay on white.
    static func isLightMark(_ image: Image, key: String) -> Bool {
        if let known = lightMarks[key] { return known }
        let side = 24
        let renderer = ImageRenderer(content: image.resizable().scaledToFit().frame(width: CGFloat(side), height: CGFloat(side)))
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return false }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var opaque = 0
        var luminance = 0.0
        for i in 0..<(side * side) {
            let alpha = Double(px[i * 4 + 3])
            guard alpha > 128 else { continue }
            opaque += 1
            let r = Double(px[i * 4]) / alpha, g = Double(px[i * 4 + 1]) / alpha, b = Double(px[i * 4 + 2]) / alpha
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let coverage = Double(opaque) / Double(side * side)
        let result = opaque > 0 && coverage < 0.9 && luminance / Double(opaque) > 0.85
        lightMarks[key] = result
        return result
    }
}
