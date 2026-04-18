//
//  AlbumArtColorExtractor.swift
//  MusicPlugin
//
//  Pulls an average color out of an NSImage, then boosts saturation
//  and brightness so the resulting tint works as a background gradient
//  behind white text. Runs on a background queue; posts completion back
//  to the main queue.
//
//  Adapted from the SuperIsland AlbumArtView extension, specialized for
//  our background-gradient use case (we want stronger saturation than
//  a glow layer wants).
//

import AppKit
import CoreGraphics
import SwiftUI

enum AlbumArtColorExtractor {
    /// Extract a "tint-ready" color from an album art image. Computes
    /// an average color, skips near-black results (replaces with a soft
    /// neutral), and boosts saturation/brightness so the color reads
    /// well as a background gradient. Result is delivered on the main
    /// queue.
    static func extract(from image: NSImage?, completion: @escaping (NSColor?) -> Void) {
        guard let image else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let color = averageColor(of: image).map { boost($0) }
            DispatchQueue.main.async { completion(color) }
        }
    }

    /// Produce a two-stop LinearGradient for the expanded view
    /// background. Fallback is a plain near-black gradient when no
    /// color is available.
    static func backgroundGradient(for color: NSColor?) -> LinearGradient {
        guard let color else {
            return LinearGradient(
                colors: [
                    Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0),
                    Color(red: 0x05 / 255.0, green: 0x05 / 255.0, blue: 0x05 / 255.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // Top: the boosted tint at ~35% opacity over a near-black base.
        // Bottom: fades back to near-black so text remains readable.
        let top = Color(nsColor: color).opacity(0.35)
        let bottom = Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0)
        return LinearGradient(
            colors: [top, bottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Internals

    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // Downscale to a small thumbnail before averaging. Avoids scanning
        // millions of pixels for a 2000x2000 album art.
        let targetSide = 40
        let width = targetSide
        let height = targetSide
        let totalPixels = width * height
        guard totalPixels > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        let pointer = data.bindMemory(to: UInt32.self, capacity: totalPixels)
        var totalRed: UInt64 = 0
        var totalGreen: UInt64 = 0
        var totalBlue: UInt64 = 0

        for index in 0..<totalPixels {
            let color = pointer[index]
            totalRed += UInt64(color & 0xFF)
            totalGreen += UInt64((color >> 8) & 0xFF)
            totalBlue += UInt64((color >> 16) & 0xFF)
        }

        let r = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
        let g = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
        let b = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0

        // Near-black album art (cover is mostly black). Return a soft
        // neutral so the background doesn't collapse to pure black with
        // zero tint.
        if r < 0.04, g < 0.04, b < 0.04 {
            return NSColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1.0)
        }
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Push the HSB up so we get a saturated, bright tint suitable for
    /// a background gradient. Clamps so extremely neon sources don't
    /// blow out.
    private static func boost(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            hue: hue,
            saturation: min(max(saturation * 1.35, 0.55), 0.95),
            brightness: min(max(brightness * 1.25, 0.65), 0.92),
            alpha: alpha
        )
    }
}
