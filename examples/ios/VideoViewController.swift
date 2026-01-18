import UIKit
import Combine

/**
 * Sample ViewController demonstrating Muybridge video playback.
 *
 * Features:
 * - TTFF measurement with logging
 * - State observation
 * - Error handling patterns
 * - Playback controls
 */
class VideoViewController: UIViewController {
    
    // MARK: - Properties
    
    private var player: MuybridgePlayer!
    private var videoView: MetalVideoView!
    private var playPauseButton: UIButton!
    private var stateLabel: UILabel!
    private var activityIndicator: UIActivityIndicatorView!
    
    // TTFF measurement
    private var loadStartTime: UInt64 = 0
    private var firstFrameTime: UInt64 = 0
    private var hasLoggedTTFF = false
    
    // State observation
    private var cancellables = Set<AnyCancellable>()
    
    private let testVideoURL = "file:///var/mobile/Movies/test.mp4"
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupPlayer()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player.pause()
    }
    
    deinit {
        videoView.releaseResources()
        player.release()
    }
    
    // MARK: - Setup
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // Video view
        videoView = MetalVideoView(frame: view.bounds, device: nil)
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        
        // State label
        stateLabel = UILabel()
        stateLabel.textColor = .white
        stateLabel.font = .systemFont(ofSize: 14)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateLabel)
        
        // Activity indicator
        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator.color = .white
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        
        // Play/Pause button
        playPauseButton = UIButton(type: .system)
        playPauseButton.setTitle("Play", for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        playPauseButton.layer.cornerRadius = 8
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        view.addSubview(playPauseButton)
        
        // Layout
        NSLayoutConstraint.activate([
            stateLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stateLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            playPauseButton.widthAnchor.constraint(equalToConstant: 120),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    private func setupPlayer() {
        player = MuybridgePlayer()
        videoView.setPlayer(player)
        
        // Observe state changes
        observeState()
        
        // Load video
        loadVideo(url: testVideoURL)
    }
    
    private func observeState() {
        // Using withObservationTracking for @Observable (iOS 17+)
        // For older iOS, use NotificationCenter or delegate pattern
        
        // Poll state for this example (production would use proper observation)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.handleStateChange()
        }
    }
    
    // MARK: - Playback
    
    private func loadVideo(url: String) {
        loadStartTime = mach_absolute_time()
        log("[TTFF] Load started")
        
        let success = player.load(url: url)
        if !success {
            showError("Failed to load video")
            return
        }
        
        log("[TTFF] Media opened @ \(elapsedMs())ms")
        log("Video: \(player.videoWidth)x\(player.videoHeight)")
        log("Duration: \(player.duration / 1_000_000_000)s")
        
        // Start playback
        player.play()
    }
    
    private func handleStateChange() {
        let state = player.state
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.stateLabel.text = "State: \(state)"
            
            switch state {
            case .idle:
                self.activityIndicator.stopAnimating()
                self.playPauseButton.isEnabled = false
                
            case .loading, .buffering:
                self.activityIndicator.startAnimating()
                self.playPauseButton.isEnabled = false
                
            case .playing:
                // Log TTFF on first frame
                if !self.hasLoggedTTFF {
                    self.hasLoggedTTFF = true
                    self.firstFrameTime = mach_absolute_time()
                    let ttffMs = self.elapsedMs()
                    self.log("[TTFF] First frame @ \(ttffMs)ms ✓")
                    
                    if ttffMs < 200 {
                        self.log("[TTFF] TARGET MET: <200ms ✓")
                    } else {
                        self.log("[TTFF] TARGET MISSED: \(ttffMs)ms > 200ms")
                    }
                }
                
                self.activityIndicator.stopAnimating()
                self.playPauseButton.setTitle("Pause", for: .normal)
                self.playPauseButton.isEnabled = true
                
            case .paused:
                self.activityIndicator.stopAnimating()
                self.playPauseButton.setTitle("Play", for: .normal)
                self.playPauseButton.isEnabled = true
                
            case .seeking:
                self.activityIndicator.startAnimating()
                
            case .error:
                self.activityIndicator.stopAnimating()
                self.showError("Playback error")
            }
        }
    }
    
    @objc private func togglePlayback() {
        switch player.state {
        case .playing:
            player.pause()
        case .paused, .buffering:
            player.play()
        default:
            break
        }
    }
    
    // MARK: - Helpers
    
    private func elapsedMs() -> Int {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let elapsed = mach_absolute_time() - loadStartTime
        let nanos = elapsed * UInt64(info.numer) / UInt64(info.denom)
        return Int(nanos / 1_000_000)
    }
    
    private func log(_ message: String) {
        print("[MuybridgeExample] \(message)")
    }
    
    private func showError(_ message: String) {
        log("Error: \(message)")
        stateLabel.text = "Error: \(message)"
        playPauseButton.isEnabled = false
    }
}
