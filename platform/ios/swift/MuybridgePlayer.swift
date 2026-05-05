import AVFoundation
import Combine
import Foundation
import Metal
import MetalKit
import MuybridgeNative
import QuartzCore

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

    // MARK: - Public Properties (Flutter plugin hooks)

    /// Called on the decoder thread each time a new frame is stored.
    /// Callers (e.g. Flutter plugin) must hop to main thread before accessing UIKit/Metal.
    public var onFrameAvailable: (() -> Void)?

    // MARK: - Public Properties (loop)

    public var loopEnabled: Bool = false {
        didSet { configureLoopObserver() }
    }

    // MARK: - Private Properties

    private var handle: UnsafeMutableRawPointer?
    private var eosObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    public init() {
        handle = MuybridgeCreatePlayer()
        guard let h = handle else { return }
        // Wire the C-level frame callback to onFrameAvailable.
        // The C callback fires on the decoder's serial dispatch queue.
        MuybridgeSetFrameAvailableCallback(h, { userData in
            guard let userData = userData else { return }
            Unmanaged<MuybridgePlayer>.fromOpaque(userData)
                .takeUnretainedValue().onFrameAvailable?()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        release()
    }

    /// Release all resources.
    public func release() {
        if let obs = eosObserver {
            NotificationCenter.default.removeObserver(obs)
            eosObserver = nil
        }
        if let handle = handle {
            MuybridgeReleasePlayer(handle)
            self.handle = nil
            state = .idle
        }
    }

    private func configureLoopObserver() {
        if let obs = eosObserver {
            NotificationCenter.default.removeObserver(obs)
            eosObserver = nil
        }
        guard loopEnabled, let handle = handle,
              let itemPtr = MuybridgeGetAVPlayerItem(handle) else { return }
        let item = Unmanaged<AnyObject>.fromOpaque(itemPtr).takeUnretainedValue()
        eosObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.seek(to: 0)
            self?.play()
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

    /// Returns a +1 retained CVPixelBuffer for the current frame.
    /// Caller is responsible for releasing via CVPixelBufferRelease.
    /// Returns nil if no frame is available or handle has been released.
    public func copyCurrentFrame() -> CVPixelBuffer? {
        guard let handle = handle else { return nil }
        return MuybridgeCopyCurrentFrame(handle)?.takeRetainedValue()
    }

    /// Get Metal device.
    public var device: MTLDevice? {
        guard let handle = handle else { return nil }
        guard let devicePtr = MuybridgeGetDevice(handle) else { return nil }
        return Unmanaged<MTLDevice>.fromOpaque(devicePtr).takeUnretainedValue()
    }
}
