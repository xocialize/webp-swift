//
// WebPStillEncoder.swift — WebPSwift
//
// The `ExternalStillEncoder` for WebP. libwebp (vendored source, target `CWebP`) driven at the exact
// settings Chrome's canvas encoder uses — Blink hands Skia `quality × 100`, Skia encodes with
// `WEBP_PRESET_DEFAULT` and `method = 3` — so a native deliverable is the *same encoder* as the web
// build's, not an approximation of it. Measured on the Forge signage corpus at floor ≥ 80: mean −29.8%
// under the native JPEG deliverable, smaller on 10/10; the web build measured −30.2% (WEBP-NATIVE.md).
//
// Two rules that are easy to get wrong and are therefore stated in code, not comments alone:
//
//   1. The search's knob maps to LOSSY quality on its whole range. 1.0 is q=100 lossy, never a mode
//      switch to lossless (Chrome flips to lossless at exactly 1.0; a floor search whose top candidate
//      silently changed codec mode would be measuring two encoders). Lossless is a separate call.
//   2. libwebp wants STRAIGHT alpha; CoreGraphics only draws premultiplied. An image that already holds
//      8-bit straight RGBA in sRGB is handed over untouched; anything else is rendered into an sRGB
//      context and, if it carries alpha, un-premultiplied by vImage before import. Pixels are always
//      delivered in sRGB because the bitstream carries no ICC profile (metadata carriage is a later
//      concern) — a Display P3 source rendered through the sRGB context is colour-managed on the way.
//

import Accelerate
import CoreGraphics
import CWebP
import Foundation
import MediaImport

public enum WebPError: Error, Sendable, Equatable {
    /// libwebp rejected the configuration (should not happen for the settings this type exposes).
    case configuration
    /// The `CGImage` could not be rendered to 8-bit pixels.
    case pixels
    /// `WebPPictureImport*` failed (out of memory, or dimensions libwebp refuses — the format caps
    /// each side at 16383 pixels).
    case importFailed
    /// `WebPEncode` failed; `code` is libwebp's `WebPEncodingError`.
    case encodeFailed(code: Int32)
}

/// WebP encoding through libwebp, at Chrome's settings by default.
public struct WebPStillEncoder: ExternalStillEncoder {

    public struct Settings: Sendable, Equatable {
        /// libwebp's speed/size trade-off, 0 (fastest) … 6 (slowest, smallest). Chrome/Skia use 3.
        /// Measured at a fixed floor-clearing q: method 6 buys 4–6% fewer bytes at ~2× the encode.
        public var method: Int32
        /// libwebp's "sharp" RGB→YUV conversion. Lifts the SSIMULACRA2 score ~2 points for ~5% more
        /// bytes at a fixed q; whether that nets out under a floor search is unmeasured (gate W4).
        /// Chrome does not use it.
        public var useSharpYUV: Bool
        /// Effort for LOSSLESS encodes — libwebp's `quality` under `lossless = 1`, 0…100. Chrome uses 75.
        public var losslessEffort: Float

        /// What Chrome's canvas encoder does: preset default, method 3, plain YUV conversion.
        public static let chrome = Settings(method: 3, useSharpYUV: false, losslessEffort: 75)

        public init(method: Int32 = 3, useSharpYUV: Bool = false, losslessEffort: Float = 75) {
            self.method = min(max(method, 0), 6)
            self.useSharpYUV = useSharpYUV
            self.losslessEffort = min(max(losslessEffort, 0), 100)
        }
    }

    public let settings: Settings

    public init(settings: Settings = .chrome) { self.settings = settings }

    // MARK: ExternalStillEncoder

    public var format: ExternalStillFormat { .webp }
    public var supportsAlpha: Bool { true }
    public var supportsLossless: Bool { true }

    /// Lossy encode. `quality` in [0, 1] → libwebp quality 0…100, clamped, **always lossy** (rule 1).
    public func encode(_ image: CGImage, quality: Double) throws -> Data {
        let q = Float(min(max(quality, 0), 1)) * 100
        return try run(image, lossless: false, quality: q)
    }

    /// Lossless encode (VP8L, or VP8X+VP8L with alpha). `exact` is on: the RGB under fully
    /// transparent pixels survives too, because "lossless" should mean the whole buffer.
    public func encodeLossless(_ image: CGImage) throws -> Data {
        try run(image, lossless: true, quality: settings.losslessEffort)
    }

    /// The vendored libwebp's version, for receipts (`"1.6.0"`).
    public static var libwebpVersion: String {
        let v = WebPGetEncoderVersion()
        return "\((v >> 16) & 0xff).\((v >> 8) & 0xff).\(v & 0xff)"
    }

    // MARK: - libwebp

    private func run(_ image: CGImage, lossless: Bool, quality: Float) throws -> Data {
        let pixels = try Pixels(image)

        var config = WebPConfig()
        // `WebPConfigInit` / `WebPPictureInit` are function-like C macros, invisible to Swift; the
        // `*Internal` functions they expand to take the ABI version, which is a plain constant.
        guard WebPConfigInitInternal(&config, WEBP_PRESET_DEFAULT, quality,
                                     Int32(WEBP_ENCODER_ABI_VERSION)) != 0 else {
            throw WebPError.configuration
        }
        config.method = settings.method
        config.lossless = lossless ? 1 : 0
        config.use_sharp_yuv = settings.useSharpYUV ? 1 : 0
        if lossless { config.exact = 1 }
        guard WebPValidateConfig(&config) != 0 else { throw WebPError.configuration }

        var picture = WebPPicture()
        guard WebPPictureInitInternal(&picture, Int32(WEBP_ENCODER_ABI_VERSION)) != 0 else {
            throw WebPError.configuration
        }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(pixels.width)
        picture.height = Int32(pixels.height)
        // Lossless and sharp-YUV work on ARGB; the plain lossy path imports straight to YUV(+A),
        // which is what Chrome does and is the faster of the two.
        picture.use_argb = (lossless || settings.useSharpYUV) ? 1 : 0

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }

        let encoded: Bool = try withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            let imported: Int32 = pixels.bytes.withUnsafeBufferPointer { buffer in
                pixels.hasAlpha
                    ? WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(pixels.stride))
                    : WebPPictureImportRGBX(&picture, buffer.baseAddress, Int32(pixels.stride))
            }
            guard imported != 0 else { throw WebPError.importFailed }
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded else { throw WebPError.encodeFailed(code: Int32(picture.error_code.rawValue)) }
        return Data(bytes: writer.mem, count: writer.size)
    }

    // MARK: - Pixels

    /// 8-bit sRGB pixels for libwebp: RGBX for opaque images, straight RGBA otherwise (rule 2).
    struct Pixels {
        let width: Int
        let height: Int
        let stride: Int
        let bytes: [UInt8]
        let hasAlpha: Bool

        init(_ image: CGImage) throws {
            let w = image.width, h = image.height
            guard w > 0, h > 0 else { throw WebPError.pixels }
            let carriesAlpha: Bool
            switch image.alphaInfo {
            case .none, .noneSkipLast, .noneSkipFirst: carriesAlpha = false
            default: carriesAlpha = true
            }
            width = w; height = h; hasAlpha = carriesAlpha

            // Fast path: 8-bit straight RGBA, R-G-B-A in memory, sRGB — hand the bytes over as they are.
            // Skipping CoreGraphics here also skips the premultiply→un-premultiply round trip, which
            // costs precision under low alpha.
            if carriesAlpha, image.bitsPerComponent == 8, image.bitsPerPixel == 32,
               image.alphaInfo == .last, Pixels.isBigEndianOrDefault(image.bitmapInfo),
               Pixels.isSRGB(image.colorSpace),
               let data = image.dataProvider?.data as Data?, data.count >= image.bytesPerRow * h {
                stride = image.bytesPerRow
                bytes = [UInt8](data)
                return
            }

            // Everything else renders through CoreGraphics into sRGB. Opaque → RGBX. Alpha →
            // premultiplied RGBA (the only alpha layout CoreGraphics draws), then un-premultiplied in
            // place by vImage, because libwebp — like Skia's encoder — wants straight alpha.
            let rowBytes = w * 4
            var buffer = [UInt8](repeating: 0, count: rowBytes * h)
            let info = carriesAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                    : CGImageAlphaInfo.noneSkipLast.rawValue
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw WebPError.pixels }
            let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                                              space: space, bitmapInfo: info) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if carriesAlpha {
                    var vb = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h),
                                           width: vImagePixelCount(w), rowBytes: rowBytes)
                    _ = vImageUnpremultiplyData_RGBA8888(&vb, &vb, vImage_Flags(kvImageNoFlags))
                }
                return true
            }
            guard drawn else { throw WebPError.pixels }
            stride = rowBytes
            bytes = buffer
        }

        private static func isBigEndianOrDefault(_ info: CGBitmapInfo) -> Bool {
            let order = info.intersection(.byteOrderMask)
            return order == .byteOrder32Big || order.rawValue == 0
        }

        private static func isSRGB(_ space: CGColorSpace?) -> Bool {
            guard let name = space?.name as String? else { return false }
            return name == (CGColorSpace.sRGB as String)
        }
    }
}
