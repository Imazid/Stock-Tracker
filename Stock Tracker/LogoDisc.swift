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

    /// Per logo URL: its brand colour, or nil for a black / white / grey mark.
    private static var brandColors: [String: UIColor?] = [:]

    /// The logo's dominant saturated colour (NVIDIA green, Tesla red), for the glow behind a
    /// stock page (Fey / Luma derive the backdrop from the subject). Black, white and grey
    /// marks (Apple) have none, and the page keeps the brand blue.
    static func brandColor(of image: UIImage, key: String) -> Color? {
        if let known = brandColors[key] { return known.map(Color.init(uiColor:)) }
        let side = 32
        guard let cg = image.cgImage,
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        // Hue buckets weighted by saturation; the heaviest bucket's average is the brand colour.
        var weight = [Double](repeating: 0, count: 12)
        var members = [Double](repeating: 0, count: 12)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: 12)
        for i in 0..<(side * side) {
            let alpha = Double(px[i * 4 + 3])
            guard alpha > 160 else { continue }
            let r = Double(px[i * 4]) / alpha, g = Double(px[i * 4 + 1]) / alpha, b = Double(px[i * 4 + 2]) / alpha
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.35, brightness > 0.25 else { continue }
            let bucket = min(11, Int(hue * 12))
            weight[bucket] += Double(saturation)
            members[bucket] += 1
            sums[bucket].r += r; sums[bucket].g += g; sums[bucket].b += b
        }
        var result: UIColor?
        // At least a dozen coloured pixels, so a stray anti-aliased edge doesn't count.
        if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), members[best] >= 12 {
            let n = members[best]
            result = UIColor(red: sums[best].r / n, green: sums[best].g / n, blue: sums[best].b / n, alpha: 1)
        }
        brandColors[key] = result
        return result.map(Color.init(uiColor:))
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
