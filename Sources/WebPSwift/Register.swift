//
// Register.swift — WebPSwift
//
// The one-line startup call. media-bridge's still-encoder seam is a process-wide registry
// (`MediaBridge.register(externalStillEncoder:)`), and consumers that already link `MediaBridge` may
// call it directly; this helper exists for the ones that reach media-bridge only transitively
// (the ML[X] Media Optimizer links ForgeOptimizerKit, not media-bridge) and should not have to add a
// second package reference to say "WebP, please".
//

import MediaBridge

public extension WebPStillEncoder {
    /// Register a WebP encoder with media-bridge. After this, every consumer in the process that
    /// consults `MediaBridge.externalStillEncoder(for: .webp)` — ForgeOptimizerKit's web race, for
    /// one — finds it. Most-recently-registered wins, so calling this again with other settings
    /// replaces the effective encoder.
    @discardableResult
    static func register(settings: Settings = .chrome) -> WebPStillEncoder {
        let encoder = WebPStillEncoder(settings: settings)
        MediaBridge.register(externalStillEncoder: encoder)
        return encoder
    }
}
