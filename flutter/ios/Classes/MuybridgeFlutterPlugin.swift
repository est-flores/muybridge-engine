import AVFoundation
import CoreVideo
import Flutter
import Foundation

// MARK: - Flutter texture wrapper

/// Vends CVPixelBuffers to Flutter's texture compositor.
final class MuybridgeFlutterTexture: NSObject, FlutterTexture {
    private let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let buf = MuybridgeCopyCurrentFrame(handle) else { return nil }
        return Unmanaged.passRetained(buf)
    }
}

// MARK: - Per-player state

private final class PlayerEntry {
    let handle: UnsafeMutableRawPointer
    let textureId: Int64
    let texture: MuybridgeFlutterTexture
    var eventSink: FlutterEventSink?
    var kvoObservations: [NSKeyValueObservation] = []
    var eosObserver: NSObjectProtocol?

    init(handle: UnsafeMutableRawPointer, textureId: Int64,
         texture: MuybridgeFlutterTexture) {
        self.handle = handle
        self.textureId = textureId
        self.texture = texture
    }
}

// MARK: - Event stream handler

private final class PlayerEventStreamHandler: NSObject, FlutterStreamHandler {
    var onListen: ((FlutterEventSink?) -> Void)?

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        onListen?(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onListen?(nil)
        return nil
    }
}

// MARK: - Plugin

public final class MuybridgeFlutterPlugin: NSObject, FlutterPlugin {

    private var registrar: FlutterPluginRegistrar!
    private var players: [Int: PlayerEntry] = [:]
    private let loadQueue = DispatchQueue(label: "muybridge.flutter.load",
                                         qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "muybridge_flutter/player",
                                           binaryMessenger: registrar.messenger())
        let instance = MuybridgeFlutterPlugin()
        instance.registrar = registrar
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let playerId = args["id"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing 'id'", details: nil))
            return
        }

        switch call.method {
        case "initialize":
            initialize(playerId: playerId, result: result)
        case "load":
            guard let url = args["url"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'url'", details: nil))
                return
            }
            load(playerId: playerId, url: url, result: result)
        case "play":
            play(playerId: playerId)
            result(nil)
        case "pause":
            pause(playerId: playerId)
            result(nil)
        case "seek":
            let positionNanos = args["positionNanos"] as? Int64 ?? 0
            seek(playerId: playerId, positionNanos: positionNanos)
            result(nil)
        case "dispose":
            dispose(playerId: playerId)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - initialize

    private func initialize(playerId: Int, result: @escaping FlutterResult) {
        guard let handle = MuybridgeCreatePlayer() else {
            result(FlutterError(code: "CREATE_FAILED", message: "Failed to create player", details: nil))
            return
        }

        let texture = MuybridgeFlutterTexture(handle: handle)
        let textureId = registrar.textures().register(texture)

        let entry = PlayerEntry(handle: handle, textureId: textureId, texture: texture)
        players[playerId] = entry

        // Frame callback: decoder thread → main thread → textureFrameAvailable
        MuybridgeSetFrameAvailableCallback(handle, { userData in
            guard let userData = userData else { return }
            let ctx = Unmanaged<FrameCallbackContext>.fromOpaque(userData)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                ctx.registry.textureFrameAvailable(ctx.textureId)
            }
        }, FrameCallbackContext.retain(registry: registrar.textures(), textureId: textureId))

        // Per-player event channel
        let streamHandler = PlayerEventStreamHandler()
        streamHandler.onListen = { [weak entry] sink in
            entry?.eventSink = sink
        }
        let eventChannel = FlutterEventChannel(
            name: "muybridge_flutter/player/\(playerId)/events",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(streamHandler)

        result(["textureId": textureId, "playerId": playerId])
    }

    // MARK: - load

    private func load(playerId: Int, url: String, result: @escaping FlutterResult) {
        guard let entry = players[playerId] else {
            result(FlutterError(code: "NO_PLAYER", message: "Player not found", details: nil))
            return
        }

        emit(entry: entry, state: "loading")

        loadQueue.async { [weak self] in
            guard let self = self else { return }
            let ok = MuybridgeOpenMedia(entry.handle, url)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Guard against dispose() being called while load was in flight.
                // If the entry is gone, entry.handle is freed — don't touch it.
                guard self.players[playerId] != nil else {
                    result(false)
                    return
                }
                if ok {
                    self.installKVO(entry: entry)
                    self.emit(entry: entry, state: "ready")
                } else {
                    self.emit(entry: entry, state: "error")
                }
                result(ok)
            }
        }
    }

    // MARK: - playback controls

    private func play(playerId: Int) {
        guard let entry = players[playerId] else { return }
        MuybridgePlay(entry.handle)
        emit(entry: entry, state: "playing")
    }

    private func pause(playerId: Int) {
        guard let entry = players[playerId] else { return }
        MuybridgePause(entry.handle)
        emit(entry: entry, state: "paused")
    }

    private func seek(playerId: Int, positionNanos: Int64) {
        guard let entry = players[playerId] else { return }
        MuybridgeSeek(entry.handle, positionNanos)
    }

    // MARK: - dispose

    private func dispose(playerId: Int) {
        guard let entry = players.removeValue(forKey: playerId) else { return }
        teardown(entry: entry)
    }

    private func teardown(entry: PlayerEntry) {
        entry.kvoObservations.forEach { $0.invalidate() }
        entry.kvoObservations.removeAll()
        if let obs = entry.eosObserver {
            NotificationCenter.default.removeObserver(obs)
            entry.eosObserver = nil
        }
        registrar.textures().unregisterTexture(entry.textureId)
        // Stop the decode loop synchronously before releasing. This ensures
        // the loop has fully exited (via dispatch_sync inside stop()) before
        // ARC deallocs the player, preventing a use-after-free race.
        MuybridgePause(entry.handle)
        MuybridgeReleasePlayer(entry.handle)
    }

    // MARK: - KVO / notifications

    private func installKVO(entry: PlayerEntry) {
        guard let itemPtr = MuybridgeGetAVPlayerItem(entry.handle) else { return }
        let playerItem = Unmanaged<AVPlayerItem>.fromOpaque(itemPtr).takeUnretainedValue()

        let statusObs = playerItem.observe(\.status, options: [.new]) { [weak self, weak entry] (item: AVPlayerItem, _: NSKeyValueObservedChange<AVPlayerItem.Status>) in
            guard let self = self, let entry = entry else { return }
            switch item.status {
            case .readyToPlay:
                self.emit(entry: entry, state: "ready")
            case .failed:
                self.emit(entry: entry, state: "error")
            default:
                break
            }
        }

        let bufferObs = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self, weak entry] (item: AVPlayerItem, _: NSKeyValueObservedChange<Bool>) in
            guard let self = self, let entry = entry else { return }
            if item.isPlaybackLikelyToKeepUp {
                self.emit(entry: entry, state: "playing")
            } else {
                self.emit(entry: entry, state: "buffering")
            }
        }

        entry.kvoObservations = [statusObs, bufferObs]

        entry.eosObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self, weak entry] _ in
            guard let self = self, let entry = entry else { return }
            self.emit(entry: entry, state: "ended")
        }
    }

    // MARK: - helpers

    private func emit(entry: PlayerEntry, state: String) {
        DispatchQueue.main.async {
            entry.eventSink?(["state": state])
        }
    }
}

// MARK: - Frame callback context

/// Holds registry + textureId so the C callback closure can reach them.
private final class FrameCallbackContext {
    let registry: FlutterTextureRegistry
    let textureId: Int64

    private init(registry: FlutterTextureRegistry, textureId: Int64) {
        self.registry = registry
        self.textureId = textureId
    }

    /// Returns an opaque pointer carrying a +1 unmanaged retain.
    /// The callback closure owns this retain for the player's lifetime.
    static func retain(registry: FlutterTextureRegistry,
                       textureId: Int64) -> UnsafeMutableRawPointer {
        let ctx = FrameCallbackContext(registry: registry, textureId: textureId)
        return Unmanaged.passRetained(ctx).toOpaque()
    }
}
