#if canImport(UIKit)
import UIKit
import MetalKit

/// Metal-backed video view for displaying Muybridge player output.
public class MetalVideoView: MTKView {
    
    // MARK: - Properties
    
    private var player: MuybridgePlayer?
    private var commandQueue: MTLCommandQueue?
    
    // MARK: - Initialization
    
    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }
    
    public required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        // Configure for video rendering
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        // Enable display link for V-Sync
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        
        delegate = self
    }
    
    // MARK: - Public API
    
    /// Set the player to render.
    public func setPlayer(_ player: MuybridgePlayer) {
        self.player = player
        
        // Use player's device
        if let playerDevice = player.device {
            self.device = playerDevice
            commandQueue = playerDevice.makeCommandQueue()
        }
        
        // Initialize renderer
        player.initRenderer()
    }
    
    /// Release resources.
    public func releaseResources() {
        player?.releaseRenderer()
        commandQueue = nil
    }
}

// MARK: - MTKViewDelegate

extension MetalVideoView: MTKViewDelegate {
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        player?.setViewport(width: Int(size.width), height: Int(size.height))
    }
    
    public func draw(in view: MTKView) {
        guard let player = player,
              let drawable = currentDrawable,
              let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        player.render(drawable: drawable, commandBuffer: commandBuffer)
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI Support

#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI wrapper for MetalVideoView.
@available(iOS 13.0, *)
public struct VideoPlayerView: UIViewRepresentable {
    
    private let player: MuybridgePlayer
    
    public init(player: MuybridgePlayer) {
        self.player = player
    }
    
    public func makeUIView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(frame: .zero, device: player.device)
        view.setPlayer(player)
        return view
    }
    
    public func updateUIView(_ uiView: MetalVideoView, context: Context) {
        // State updates handled by player
    }
    
    public static func dismantleUIView(_ uiView: MetalVideoView, coordinator: ()) {
        uiView.releaseResources()
    }
}
#endif

#endif // canImport(UIKit)
