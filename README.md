# webp-swift

**WebP encoding for Apple platforms**, as an `ExternalStillEncoder` for
[media-bridge](https://github.com/xocialize/media-bridge)'s still-encoder seam — or driven directly.
It carries [libwebp](https://github.com/webmproject/libwebp) **as source** (no binary, no configure
step) so that media-bridge itself stays pure-Swift; the package boundary *is* the quarantine.

## Why this exists

Apple decodes WebP natively — ImageIO has since macOS 11 — but ships **no encoder**. Measured on
macOS 27.2: `CGImageDestinationCopyTypeIdentifiers()` lists 22 writable types (JPEG, PNG, HEIC, AVIF,
EXR, …) and `org.webmproject.webp` is not among them; `CGImageDestinationCreateWithData` with the WebP
UTI returns nil. WebKit's canvas encoder is ImageIO-backed, which is why Safari never had it either.

The only encoder is libwebp, and it is also *the* encoder: Chrome's canvas WebP is libwebp (Blink →
Skia → `WebPEncode`). This package drives it at Chrome's exact settings — `WEBP_PRESET_DEFAULT`,
`method = 3`, quality × 100 — so a native deliverable is the same encoder as the web's, not an
approximation. On the Forge signage corpus at a SSIMULACRA2 floor of 80 it lands a mean **−29.8%**
under the native JPEG deliverable, smaller on 10/10 stills (the web build measured −30.2%), and it
carries alpha, which JPEG never could.

## Use

```swift
import WebPSwift

WebPStillEncoder.register()          // once at startup: WebP is now a lane media-bridge consumers can race
```

After that, anything that consults `MediaBridge.externalStillEncoder(for: .webp)` — ForgeOptimizerKit's
web profile, for one — runs WebP through the same floor search as HEIC/JPEG/PNG. Or encode directly:

```swift
let encoder = WebPStillEncoder()                       // Chrome's settings
let lossy = try encoder.encode(cgImage, quality: 0.8)  // [0, 1] → libwebp 0…100, ALWAYS lossy
let lossless = try encoder.encodeLossless(cgImage)     // VP8L (VP8X + VP8L with alpha)

WebPStillEncoder(settings: .init(method: 6, useSharpYUV: true))   // slower, a few % smaller
```

Two rules the type enforces rather than documents:

- **The knob is lossy on its whole range.** 1.0 is q=100 lossy, never a mode switch — Chrome flips to
  lossless at exactly 1.0, and a floor search whose top candidate silently changed codec mode would
  be comparing two encoders. Lossless is the separate call.
- **Alpha goes in straight.** libwebp wants un-premultiplied alpha; CoreGraphics only draws
  premultiplied. An image that already holds 8-bit straight RGBA in sRGB is handed over untouched;
  anything else is rendered into sRGB and, if it carries alpha, un-premultiplied by vImage before
  import. Pixels are always delivered in sRGB because the bitstream carries no ICC profile (yet).

## What's in the box

| Target | Role |
|---|---|
| `CWebP` | libwebp v1.6.0 vendored **as source** — `src/` + `sharpyuv/`, 125 C files, zero assembly (SIMD is intrinsics-only), compiled by SwiftPM's own clang. ~656 KB static, arm64, encoder + decoder. |
| `WebPSwift` | `WebPStillEncoder: ExternalStillEncoder` (+ `register()`), `WebPError`, `Settings`. |

Nothing is muxed here: metadata chunks (EXIF/XMP/ICC via `WebPMux`) are a later concern, and a
deliverable from this package is metadata-clean by construction. Animated WebP is out of scope.

## Re-vendoring

```sh
Scripts/update-libwebp.sh v1.6.0     # clones the tag, replaces Sources/CWebP, rewrites the notices
```

Then run the tests. `testCorpusParityWithTheStudy` (needs `FORGE_CORPUS`) reproduces two byte counts
from the study that chose these settings; a different libwebp or a changed default moves them.

## Requirements

macOS 14+ (media-bridge's floor). Swift 6.2 tools.

## License

BSD-3-Clause, matching libwebp. libwebp's `COPYING` and the WebM `PATENTS` grant are reproduced in
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) and must ship with any binary that links this
package; the grant covers encoding as well as decoding. media-bridge stays MIT; only a consumer that
links webp-swift accepts BSD-3 + the patent grant.
