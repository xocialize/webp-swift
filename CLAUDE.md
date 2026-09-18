# webp-swift — agent notes

**What:** WebP *encoding* for media-bridge consumers. Apple ships no WebP encoder (ImageIO decodes
only — measured on macOS 27.2, receipts in the Forge workspace's `Docs/WEBP-NATIVE.md`). This
package quarantines libwebp so media-bridge stays pure-Swift. Ships OPEN (`xocialize/webp-swift`).

**Not a binary.** Unlike vpx-swift, libwebp is plain C99 with intrinsics-only SIMD and no configure
step, so it is vendored AS SOURCE (`Sources/CWebP`, v1.6.0 verbatim + `sharpyuv/`) and compiled by
SwiftPM. `Scripts/update-libwebp.sh <tag>` re-vendors; it must keep reporting **0 assembly files**.

**Architecture:**
- `CWebP` — the C target. Public headers copied to `include/webp/`; `headerSearchPath(".")` because
  libwebp includes its own headers as `src/webp/…` / `sharpyuv/…` relative to its root.
- `WebPSwift` — `WebPStillEncoder: ExternalStillEncoder` (media-bridge `MediaImport`), `register()`
  (links `MediaBridge` so a consumer that has media-bridge only transitively — the ML[X] Media
  Optimizer — needs no second package reference), `Settings` (`.chrome` = preset default, method 3).

**Traps, already paid for:**
- `WebPConfigInit` / `WebPPictureInit` are function-like macros invisible to Swift — call the
  `*Internal` functions with `WEBP_ENCODER_ABI_VERSION` (a plain constant, which does import).
- The [0, 1] knob maps to lossy q on its WHOLE range; 1.0 is q=100 lossy. Chrome switches to
  lossless at exactly 1.0 — a floor search must never see that switch. `encodeLossless` is separate.
- CoreGraphics draws premultiplied; libwebp wants straight alpha. Fast path hands over 8-bit
  straight sRGB RGBA bytes untouched; everything else renders into sRGB + vImage un-premultiply.
- `exact` is on for lossless only. Under lossy, libwebp may alter RGB under fully transparent
  pixels (Chrome's behaviour); a scorer that ignores alpha will see that as error.
- SSIMULACRA2 is not monotone in libwebp's q (q=91 scored below q=90 on one corpus still); a
  bisection tolerates it, a "lower until it fails" loop would not.

**Tests:** every assertion decodes through ImageIO (Apple's decoder, no shared code with the
encoder). `testCorpusParityWithTheStudy` needs `FORGE_CORPUS`.
