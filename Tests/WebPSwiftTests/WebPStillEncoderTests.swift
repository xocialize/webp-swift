//
// WebPStillEncoderTests.swift — WebPSwiftTests
//
// A written file is not evidence. Every assertion here decodes the bytes back through ImageIO —
// Apple's own WebP decoder, which shares no code with libwebp's encoder — and looks at pixels.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MediaBridge
import MediaImport
@testable import WebPSwift

final class WebPStillEncoderTests: XCTestCase {

    override func setUp() { super.setUp(); MediaBridge.unregisterAllExternalStillEncoders() }
    override func tearDown() { MediaBridge.unregisterAllExternalStillEncoders(); super.tearDown() }

    // MARK: - Fixtures

    /// Photo-like: smooth low-frequency structure + mild grain (the shape the Kit's race tests use).
    /// With `alpha`, a horizontal alpha ramp 0→255 rides over colour that varies independently, so a
    /// dropped or flattened channel is measurable rather than suspected.
    private func makeImage(_ n: Int, alpha: Bool) -> (image: CGImage, rgba: [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 0x9E3779B9
        func grain() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(Int32(truncatingIfNeeded: seed >> 8) % 13) - 6
        }
        for y in 0..<n { for x in 0..<n {
            let fx = Double(x) / Double(n), fy = Double(y) / Double(n)
            let l1 = 110 + 70 * sin(fx * 4.1 + 0.6) * cos(fy * 2.9 + 1.1)
            let l2 = 40 * sin((fx + fy) * 6.3)
            let i = (y * n + x) * 4
            bytes[i]     = UInt8(clamping: Int(l1 + l2 * 0.7 + grain()))
            bytes[i + 1] = UInt8(clamping: Int(l1 * 0.9 + l2 + grain()))
            bytes[i + 2] = UInt8(clamping: Int(l1 * 1.1 + l2 * 0.4 + grain()))
            bytes[i + 3] = alpha ? UInt8(clamping: x * 255 / (n - 1)) : 255
        } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: CGImageAlphaInfo = alpha ? .last : .noneSkipLast     // .last = STRAIGHT alpha
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: n * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return (image, bytes)
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.webP.identifier,
                       "ImageIO must recognise the bytes as WebP")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Straight RGBA bytes of a decoded image, read back through an sRGB context. The premultiply
    /// round trip is exact at alpha 255 and 0, and within rounding elsewhere.
    private func straightRGBA(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Un-premultiply by hand so the comparison is against straight values.
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Int(out[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { out[i + c] = UInt8(clamping: (Int(out[i + c]) * 255 + a / 2) / a) }
        }
        return out
    }

    private func chunk(_ data: Data) -> String {
        String(bytes: data[12..<16], encoding: .ascii) ?? "?"
    }

    // MARK: - Tests

    func testLossyRoundTripsThroughImageIO() throws {
        let (image, _) = makeImage(256, alpha: false)
        let data = try WebPStillEncoder().encode(image, quality: 0.75)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(chunk(data), "VP8 ", "opaque lossy is a simple-format VP8 file")
        let back = try decode(data)
        XCTAssertEqual(back.width, 256)
        XCTAssertEqual(back.height, 256)
        XCTAssertLessThan(data.count, 256 * 256 * 3 / 4, "lossy q0.75 must compress a photo-like still")
    }

    func testTheKnobIsLossyOnItsWholeRange() throws {
        let (image, _) = makeImage(256, alpha: false)
        let encoder = WebPStillEncoder()
        let low = try encoder.encode(image, quality: 0.3)
        let high = try encoder.encode(image, quality: 0.9)
        let top = try encoder.encode(image, quality: 1.0)
        let lossless = try encoder.encodeLossless(image)
        XCTAssertLessThan(low.count, high.count, "more quality, more bytes")
        XCTAssertEqual(chunk(top), "VP8 ", "knob 1.0 is q=100 LOSSY — never a mode switch")
        XCTAssertEqual(chunk(lossless), "VP8L", "lossless is the separate call")
        XCTAssertNotEqual(top, lossless)
    }

    func testLosslessIsBitExact() throws {
        let (image, rgba) = makeImage(128, alpha: false)
        let data = try WebPStillEncoder().encodeLossless(image)
        let back = straightRGBA(try decode(data))
        for i in stride(from: 0, to: rgba.count, by: 4) {
            XCTAssertEqual(back[i], rgba[i]); XCTAssertEqual(back[i + 1], rgba[i + 1])
            XCTAssertEqual(back[i + 2], rgba[i + 2])
            if back[i] != rgba[i] { break }
        }
    }

    /// The alpha plane is lossless by libwebp's default even under a lossy colour encode, and it must
    /// come back STRAIGHT: a premultiplied leak would show as darkened colour under mid alpha.
    func testAlphaSurvivesStraightUnderLossy() throws {
        let (image, rgba) = makeImage(256, alpha: true)
        XCTAssertEqual(image.alphaInfo, .last, "fixture is straight alpha")
        let data = try WebPStillEncoder().encode(image, quality: 0.8)
        XCTAssertEqual(chunk(data), "VP8X", "alpha needs the extended container")
        let decoded = try decode(data)
        XCTAssertTrue([.last, .first, .premultipliedLast, .premultipliedFirst].contains(decoded.alphaInfo),
                      "ImageIO must report an alpha channel")
        let back = straightRGBA(decoded)
        // Alpha: bit-exact, every pixel.
        for i in stride(from: 0, to: rgba.count, by: 4) where back[i + 3] != rgba[i + 3] {
            return XCTFail("alpha differs at byte \(i): \(back[i + 3]) vs \(rgba[i + 3])")
        }
        // Colour at full alpha: lossy, so a tolerance — but a *premultiplied* leak at alpha 128 would
        // halve the values, which the mid-alpha check catches with room to spare.
        var maxErrOpaque = 0, maxErrMid = 0
        let n = 256
        for y in 0..<n {
            let opaque = (y * n + (n - 1)) * 4, mid = (y * n + n / 2) * 4
            for c in 0..<3 {
                maxErrOpaque = max(maxErrOpaque, abs(Int(back[opaque + c]) - Int(rgba[opaque + c])))
                maxErrMid = max(maxErrMid, abs(Int(back[mid + c]) - Int(rgba[mid + c])))
            }
        }
        XCTAssertLessThan(maxErrOpaque, 40, "lossy colour error at full alpha")
        XCTAssertLessThan(maxErrMid, 48, "colour under alpha 128 must not be premultiplied-dark")
    }

    /// A premultiplied CGImage (what CoreGraphics produces) goes through the render + un-premultiply
    /// path and must land on the same straight values as the fast path, within rounding.
    func testPremultipliedSourcesAreUnpremultiplied() throws {
        let (straight, rgba) = makeImage(64, alpha: true)
        let premultiplied: CGImage = {
            let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(straight, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return ctx.makeImage()!
        }()
        XCTAssertEqual(premultiplied.alphaInfo, .premultipliedLast)
        let data = try WebPStillEncoder().encodeLossless(premultiplied)
        let back = straightRGBA(try decode(data))
        var maxErr = 0
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] >= 64 {   // rounding blows up under low alpha
            XCTAssertEqual(back[i + 3], rgba[i + 3])
            for c in 0..<3 { maxErr = max(maxErr, abs(Int(back[i + c]) - Int(rgba[i + c]))) }
        }
        XCTAssertLessThanOrEqual(maxErr, 4, "un-premultiply rounding, not a premultiplied leak")
    }

    func testRegistersWithMediaBridge() throws {
        XCTAssertFalse(MediaBridge.canEncodeStill(.webp), "nothing registered yet")
        XCTAssertNil(MediaBridge.externalStillEncoder(for: .webp))
        let registered = WebPStillEncoder.register()
        XCTAssertTrue(MediaBridge.canEncodeStill(.webp))
        let found = try XCTUnwrap(MediaBridge.externalStillEncoder(for: .webp) as? WebPStillEncoder)
        XCTAssertEqual(found.settings, registered.settings)
        XCTAssertEqual(found.format.utType, .webP)
        XCTAssertTrue(found.supportsAlpha)
        XCTAssertTrue(found.supportsLossless)
    }

    func testVersionIsTheVendoredOne() {
        XCTAssertEqual(WebPStillEncoder.libwebpVersion, "1.6.0")
    }

    /// Parity receipt against WEBP-NATIVE.md §3: the study encoded two corpus stills at q=75, method 3
    /// and recorded 100,094 and 78,622 bytes. Same encoder, same settings, same input → the same
    /// bytes, within a tolerance that only a different libwebp or a changed setting would breach.
    func testCorpusParityWithTheStudy() throws {
        guard let corpus = ProcessInfo.processInfo.environment["FORGE_CORPUS"] else {
            throw XCTSkip("set FORGE_CORPUS to run the corpus parity check")
        }
        let expected: [(String, Int)] = [("Bayer_photo.png", 100_094), ("KEYNOTE_graphic.png", 78_622)]
        for (name, bytes) in expected {
            let url = URL(fileURLWithPath: corpus).appendingPathComponent("derived/1080/stills/\(name)")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let data = try WebPStillEncoder().encode(image, quality: 0.75)
            XCTAssertEqual(Double(data.count), Double(bytes), accuracy: Double(bytes) * 0.02,
                           "\(name) at q=75/m3 should reproduce the study's \(bytes) B (got \(data.count))")
        }
    }
}
