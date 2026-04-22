import AppKit
import MetalKit
import MuybridgePlayer

// MARK: - Render delegate

final class VideoRenderDelegate: NSObject, MTKViewDelegate {
    private let player: MuybridgePlayer
    private let commandQueue: MTLCommandQueue

    init(player: MuybridgePlayer, commandQueue: MTLCommandQueue) {
        self.player = player
        self.commandQueue = commandQueue
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        player.setViewport(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        player.render(drawable: drawable, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var player: MuybridgePlayer?
    private var renderDelegate: VideoRenderDelegate?
    private let url: String

    init(url: String) {
        self.url = url
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            print("error: Metal is not available on this machine")
            NSApp.terminate(nil)
            return
        }

        // 9:16 vertical — TikTok native aspect ratio
        let viewWidth = 405
        let viewHeight = 720

        let mtkView = MTKView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight), device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let player = MuybridgePlayer()
        self.player = player
        player.initRenderer()

        let rd = VideoRenderDelegate(player: player, commandQueue: commandQueue)
        self.renderDelegate = rd
        mtkView.delegate = rd

        let window = NSWindow(
            contentRect: mtkView.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Muybridge — loading…"
        window.contentView = mtkView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Query drawable size AFTER the view is in the window hierarchy so
        // the Retina backing scale factor is applied (logical 405×720 → physical 810×1440 on 2x)
        let drawable = mtkView.drawableSize
        player.setViewport(width: Int(drawable.width), height: Int(drawable.height))

        print("loading: \(url)")
        let ok = player.load(url: url)
        if ok {
            let w = player.videoWidth, h = player.videoHeight
            let durationMs = player.duration / 1_000_000
            print("loaded: \(w)x\(h)  duration: \(durationMs)ms")
            window.title = "Muybridge — \(w)×\(h)  \(durationMs / 1000)s"
            player.play()
        } else {
            print("error: failed to load — check the URL and network access")
            window.title = "Muybridge — load failed"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Entry point

guard CommandLine.arguments.count > 1 else {
    print("usage: swift run MuybridgeDemo <video-url>")
    print("example: swift run MuybridgeDemo https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")
    exit(1)
}

let url = CommandLine.arguments[1]
let app = NSApplication.shared
let delegate = AppDelegate(url: url)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
