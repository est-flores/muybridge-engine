import Foundation
import Metal
import MetalKit
import QuartzCore
import Combine

/// Muybridge video player for iOS.
///
/// Hardware-accelerated video playback with:
/// - Sub-200ms TTFF
/// - Zero-copy decode to Metal
/// - A/V sync within ±16ms
public final class MuybridgePlayer: ObservableObject {
    
    /// Player state
    public enum State: Sendable {
        case idle
        case loading
        case buffering
        case playing
        case paused
        case seeking
        case error
    }
    
    // MARK: - Public Properties
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var duration: Int64 = 0
    @Published public private(set) var position: Int64 = 0
    @Published public private(set) var videoWidth: Int32 = 0
    @Published public private(set) var videoHeight: Int32 = 0
    
    // MARK: - Private Properties
    
    private var handle: UnsafeMutableRawPointer?
    
    // MARK: - Lifecycle
    
    public init() {
        handle = MuybridgeCreatePlayer()
    }
    
    deinit {
        release()
    }
    
    /// Release all resources.
    public func release() {
        if let handle = handle {
            MuybridgeReleasePlayer(handle)
            self.handle = nil
            state = .idle
        }
    }
    
    // MARK: - Playback Control
    
    /// Load media from URL.
    @discardableResult
    public func load(url: String) -> Bool {
        guard let handle = handle else { return false }
        
        state = .loading
        
        let result = url.withCString { cString in
            MuybridgeOpenMedia(handle, cString)
        }
        
        if result {
            duration = MuybridgeGetDuration(handle)
            videoWidth = MuybridgeGetVideoWidth(handle)
            videoHeight = MuybridgeGetVideoHeight(handle)
            state = .buffering
        } else {
            state = .error
        }
        
        return result
    }
    
    /// Start playback.
    public func play() {
        guard let handle = handle else { return }
        MuybridgePlay(handle)
        state = .playing
    }
    
    /// Pause playback.
    public func pause() {
        guard let handle = handle else { return }
        MuybridgePause(handle)
        state = .paused
    }
    
    /// Seek to position.
    public func seek(to positionNanos: Int64) {
        guard let handle = handle else { return }
        state = .seeking
        MuybridgeSeek(handle, positionNanos)
    }
    
    // MARK: - Rendering
    
    /// Initialize Metal renderer.
    @discardableResult
    public func initRenderer() -> Bool {
        guard let handle = handle else { return false }
        return MuybridgeInitRenderer(handle)
    }
    
    /// Set viewport dimensions.
    public func setViewport(width: Int, height: Int) {
        guard let handle = handle else { return }
        MuybridgeSetViewport(handle, Int32(width), Int32(height))
    }
    
    /// Render current frame.
    public func render(drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        guard let handle = handle else { return }
        MuybridgeRender(
            handle,
            Unmanaged.passUnretained(drawable).toOpaque(),
            Unmanaged.passUnretained(commandBuffer).toOpaque()
        )
    }
    
    /// Release renderer resources.
    public func releaseRenderer() {
        guard let handle = handle else { return }
        MuybridgeReleaseRenderer(handle)
    }
    
    /// Get Metal device.
    public var device: MTLDevice? {
        guard let handle = handle else { return nil }
        guard let devicePtr = MuybridgeGetDevice(handle) else { return nil }
        return Unmanaged<MTLDevice>.fromOpaque(devicePtr).takeUnretainedValue()
    }
}

// MARK: - C Bridge Declarations

@_silgen_name("MuybridgeCreatePlayer")
private func MuybridgeCreatePlayer() -> UnsafeMutableRawPointer?

@_silgen_name("MuybridgeReleasePlayer")
private func MuybridgeReleasePlayer(_ handle: UnsafeMutableRawPointer)

@_silgen_name("MuybridgeOpenMedia")
private func MuybridgeOpenMedia(_ handle: UnsafeMutableRawPointer, _ url: UnsafePointer<CChar>) -> Bool

@_silgen_name("MuybridgePlay")
private func MuybridgePlay(_ handle: UnsafeMutableRawPointer)

@_silgen_name("MuybridgePause")
private func MuybridgePause(_ handle: UnsafeMutableRawPointer)

@_silgen_name("MuybridgeSeek")
private func MuybridgeSeek(_ handle: UnsafeMutableRawPointer, _ positionNanos: Int64)

@_silgen_name("MuybridgeGetDuration")
private func MuybridgeGetDuration(_ handle: UnsafeMutableRawPointer) -> Int64

@_silgen_name("MuybridgeGetVideoWidth")
private func MuybridgeGetVideoWidth(_ handle: UnsafeMutableRawPointer) -> Int32

@_silgen_name("MuybridgeGetVideoHeight")
private func MuybridgeGetVideoHeight(_ handle: UnsafeMutableRawPointer) -> Int32

@_silgen_name("MuybridgeInitRenderer")
private func MuybridgeInitRenderer(_ handle: UnsafeMutableRawPointer) -> Bool

@_silgen_name("MuybridgeSetViewport")
private func MuybridgeSetViewport(_ handle: UnsafeMutableRawPointer, _ width: Int32, _ height: Int32)

@_silgen_name("MuybridgeRender")
private func MuybridgeRender(_ handle: UnsafeMutableRawPointer, _ drawable: UnsafeMutableRawPointer, _ commandBuffer: UnsafeMutableRawPointer)

@_silgen_name("MuybridgeReleaseRenderer")
private func MuybridgeReleaseRenderer(_ handle: UnsafeMutableRawPointer)

@_silgen_name("MuybridgeGetDevice")
private func MuybridgeGetDevice(_ handle: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
