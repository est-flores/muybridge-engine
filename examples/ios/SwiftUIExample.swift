import SwiftUI

/**
 * SwiftUI example for Muybridge video playback.
 *
 * Features:
 * - VideoPlayerView integration
 * - State observation via @Observable
 * - Simple controls overlay
 */
@available(iOS 17.0, *)
struct VideoPlayerScreen: View {
    
    @State private var player = MuybridgePlayer()
    @State private var isPlaying = false
    @State private var showControls = true
    
    let videoURL: String
    
    var body: some View {
        ZStack {
            // Video view
            VideoPlayerView(player: player)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                }
            
            // Controls overlay
            if showControls {
                VStack {
                    // State indicator
                    HStack {
                        Text(stateText)
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                        Spacer()
                    }
                    .padding()
                    
                    Spacer()
                    
                    // Play/Pause button
                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                            .padding(24)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                }
            }
            
            // Loading indicator
            if player.state == .loading || player.state == .buffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)
            }
        }
        .onAppear {
            loadVideo()
        }
        .onDisappear {
            player.release()
        }
        .onChange(of: player.state) { _, newState in
            isPlaying = (newState == .playing)
        }
    }
    
    private var stateText: String {
        switch player.state {
        case .idle: return "Idle"
        case .loading: return "Loading..."
        case .buffering: return "Buffering..."
        case .playing: return "▶ Playing"
        case .paused: return "⏸ Paused"
        case .seeking: return "Seeking..."
        case .error: return "⚠ Error"
        }
    }
    
    private func loadVideo() {
        guard player.load(url: videoURL) else {
            print("Failed to load video")
            return
        }
        player.play()
    }
    
    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }
}

// MARK: - Preview

@available(iOS 17.0, *)
#Preview {
    VideoPlayerScreen(videoURL: "file:///path/to/video.mp4")
}
