# Changelog

All notable changes to Muybridge Player will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2024-XX-XX

### Added

- Initial release
- Hardware-accelerated video decoding
  - Android: AMediaCodec (H.264, HEVC)
  - iOS: VideoToolbox (H.264, HEVC)
- Zero-copy GPU rendering
  - Android: OpenGL ES 3.0 with SurfaceTexture
  - iOS: Metal with CVMetalTextureCache
- Reactive player API
  - Android: Kotlin StateFlow
  - iOS: Swift @Observable
- TTFF instrumentation (<200ms target)
- A/V sync within ±16ms
- SwiftUI VideoPlayerView
- Android VideoSurfaceView (GLSurfaceView)

### Performance

- Sub-200ms time-to-first-frame
- 60fps smooth playback
- Zero runtime allocations in decode path

---

## Version Numbering

| Change                            | Version Bump | Example       |
| --------------------------------- | ------------ | ------------- |
| Bug fix                           | Patch        | 1.0.0 → 1.0.1 |
| New feature (backward compatible) | Minor        | 1.0.0 → 1.1.0 |
| Breaking API change               | Major        | 1.0.0 → 2.0.0 |

## Upgrading

### From 0.x to 1.0

- First stable release, no migration needed

---

_For more details, see the
[release notes](https://github.com/yourorg/muybridge-engine/releases)._
