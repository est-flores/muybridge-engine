#import "IOSVideoDecoder.h"

namespace muybridge {
namespace ios {

IOSVideoDecoder::IOSVideoDecoder()
    : asset_(nil), assetReader_(nil), videoOutput_(nil),
      player_(nil), playerItem_(nil), playerVideoOutput_(nil), playerReadyObserver_(nil),
      decompressionSession_(nullptr), formatDescription_(nullptr),
      decodeQueue_(nil), useAVPlayer_(false) {

  decodeQueue_ =
      dispatch_queue_create("com.muybridge.decode", DISPATCH_QUEUE_SERIAL);
  MUY_LOGI("IOSVideoDecoder created");
}

IOSVideoDecoder::~IOSVideoDecoder() { release(); }

bool IOSVideoDecoder::open(const std::string &url) {
  MUY_TTFF_MILESTONE("open_start");
  @autoreleasepool {
    NSString *urlString = [NSString stringWithUTF8String:url.c_str()];
    MUY_LOGI("Opening URL: %s", url.c_str());
    
    // Detect if this is a network URL
    BOOL isNetworkURL = [urlString hasPrefix:@"http://"] || [urlString hasPrefix:@"https://"];
    NSURL *mediaURL = isNetworkURL ? [NSURL URLWithString:urlString] : [NSURL fileURLWithPath:urlString];
    
    if (isNetworkURL) {
      // Use AVPlayer for network URLs (supports streaming)
      return openWithAVPlayer(mediaURL);
    } else {
      // Use AVAssetReader for local files (faster, more efficient)
      return openWithAssetReader(mediaURL);
    }
  }
}

// Terminal-visible timing log for the loading pipeline.
// MUY_LOGI goes to os_log (Console.app only); these prints go to stderr so
// they appear in the terminal during `swift run`.
#define LOAD_PHASE(fmt, ...) \
  fprintf(stderr, "[load] %8.1fms  " fmt "\n", muybridge::log::elapsedMillis(), ##__VA_ARGS__)

// Network URL handling using AVPlayer + AVPlayerItemVideoOutput
bool IOSVideoDecoder::openWithAVPlayer(NSURL *url) {
  MUY_LOGI("Using AVPlayer for network URL");
  useAVPlayer_ = true;

  LOAD_PHASE("network URL detected — creating AVPlayer");

  __block BOOL setupSuccess = NO;
  __block NSString *errorMessage = nil;
  __block MediaInfo capturedMediaInfo = {};

  // Create player item with asset for better control
  AVURLAsset *asset = [AVURLAsset assetWithURL:url];
  AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
  AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];

  // YES = AVPlayer waits until it has enough buffer to play without stalling.
  // This is required for smooth playback. Setting it to NO causes freezes when
  // the network can't keep up with playback, which is worse than a slow start.
  // The TTFF delay seen here is network latency, not renderer overhead.
  if (@available(iOS 10.0, *)) {
    player.automaticallyWaitsToMinimizeStalling = YES;
    // Hint: target 2s of forward buffer. On fast networks this is lower than
    // AVPlayer's default heuristic, so it starts sooner. On slow networks it
    // falls back to whatever the network can provide.
    playerItem.preferredForwardBufferDuration = 2.0;
  }
  
  // Create video output with pixel format for Metal - MUST include Metal compatibility key
  NSDictionary *outputSettings = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  AVPlayerItemVideoOutput *videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:outputSettings];
  [playerItem addOutput:videoOutput];
  
  // Use dispatch group and notification for better observation
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  
  // Register for notifications
  __block id failureObserver = nil;
  __block id readyObserver = nil;
  
  // Observe for failed to play to end  
  failureObserver = [[NSNotificationCenter defaultCenter] 
    addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
    object:playerItem
    queue:[NSOperationQueue mainQueue]
    usingBlock:^(NSNotification *note) {
      NSError *error = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
      errorMessage = error.localizedDescription;
      MUY_LOGE("Player failed notification: %s", [errorMessage UTF8String]);
    }];
  
  // Log player item error if any
  if (playerItem.error) {
    MUY_LOGE("Initial player item error: %s", [playerItem.error.localizedDescription UTF8String]);
  }
  
  // Start playback to trigger buffering (will pause after ready)
  [player play];
  LOAD_PHASE("AVPlayer.play() called — waiting for player ready (network)...");

  // Poll for ready status directly on background queue (no nested dispatch).
  // 16ms interval (~1 frame at 60fps) keeps setup overhead under 16ms once
  // the player is ready, vs. the previous 100ms which added up to 100ms wait.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      int attempts = 0;
      const int maxAttempts = 1875; // 30 seconds at 16ms intervals
      bool loggedFirstStatusChange = false;

      while (playerItem.status == AVPlayerItemStatusUnknown && attempts < maxAttempts) {
        if (playerItem.error) {
          errorMessage = playerItem.error.localizedDescription;
          MUY_LOGE("Player item error during load: %s", [errorMessage UTF8String]);
          dispatch_semaphore_signal(semaphore);
          return;
        }

        [NSThread sleepForTimeInterval:0.016]; // 16ms — 1 frame at 60fps
        attempts++;

        if (!loggedFirstStatusChange && playerItem.status != AVPlayerItemStatusUnknown) {
          LOAD_PHASE("player status changed from Unknown → %ld", (long)playerItem.status);
          loggedFirstStatusChange = true;
        }

        // Warn every 2 seconds if still waiting — this is always network time.
        // Common causes: CDN latency, or MOV/MP4 with moov atom at end of file
        // (requires a second HTTP range request before playback can start).
        // Fix: re-encode with `ffmpeg -movflags +faststart` to move moov to front.
        if (attempts % 125 == 0) {
          LOAD_PHASE("still waiting — %.1fs (network). MOV with end-moov? Try MP4+faststart.",
                     attempts * 0.016);
        }
      }

      if (playerItem.status == AVPlayerItemStatusFailed) {
        errorMessage = playerItem.error.localizedDescription;
        if (!errorMessage) errorMessage = @"Player item failed";
        LOAD_PHASE("ERROR: player item failed — %s", [errorMessage UTF8String]);
        MUY_LOGE("Player item failed: %s", [errorMessage UTF8String]);
        dispatch_semaphore_signal(semaphore);
        return;
      }

      if (playerItem.status != AVPlayerItemStatusReadyToPlay) {
        LOAD_PHASE("ERROR: timeout waiting for player ready (30s)");
        errorMessage = @"Player item not ready after timeout";
        dispatch_semaphore_signal(semaphore);
        return;
      }

      LOAD_PHASE("player ready — loading track metadata (renderer)...");

      // Pause now that we're ready (will resume when start() is called)
      dispatch_async(dispatch_get_main_queue(), ^{
        [player pause];
      });

      // Load track properties asynchronously before accessing them
      [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        LOAD_PHASE("tracks key loaded — reading video track properties (renderer)...");
        NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];

        if (videoTracks.count == 0) {
          LOAD_PHASE("ERROR: no video tracks found");
          errorMessage = @"No video tracks found";
          dispatch_semaphore_signal(semaphore);
          return;
        }

        AVAssetTrack *videoTrack = videoTracks.firstObject;

        // Load track-specific properties
        [videoTrack loadValuesAsynchronouslyForKeys:@[@"naturalSize", @"nominalFrameRate"] completionHandler:^{
          CGSize size = videoTrack.naturalSize;

          capturedMediaInfo.videoWidth = static_cast<int32_t>(size.width);
          capturedMediaInfo.videoHeight = static_cast<int32_t>(size.height);
          capturedMediaInfo.frameRate = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30.0f;
          capturedMediaInfo.durationNanos = static_cast<int64_t>(CMTimeGetSeconds(asset.duration) * kNanosPerSecond);
          capturedMediaInfo.hasVideo = true;

          LOAD_PHASE("video info: %dx%d @ %.1ffps, duration: %.1fs — setup complete",
                     capturedMediaInfo.videoWidth,
                     capturedMediaInfo.videoHeight,
                     capturedMediaInfo.frameRate,
                     (double)capturedMediaInfo.durationNanos / kNanosPerSecond);

          MUY_LOGI("Video: %dx%d @ %.1f fps, duration: %.2fs",
                   capturedMediaInfo.videoWidth,
                   capturedMediaInfo.videoHeight,
                   capturedMediaInfo.frameRate,
                   (double)capturedMediaInfo.durationNanos / kNanosPerSecond);

          setupSuccess = YES;
          dispatch_semaphore_signal(semaphore);
        }];
      }];
    }
  });
  
  // Wait for setup while keeping main runloop alive (AVPlayer needs it!)
  // We cannot use dispatch_semaphore_wait on main thread as it blocks AVPlayer
  NSDate *timeoutDate = [NSDate dateWithTimeIntervalSinceNow:60.0];
  
  while (!setupSuccess && !errorMessage && [[NSDate date] compare:timeoutDate] == NSOrderedAscending) {
    // Run the runloop for a short interval to let AVPlayer process network events
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  
  // Cleanup observer
  [[NSNotificationCenter defaultCenter] removeObserver:failureObserver];
  
  if (!setupSuccess) {
    if (!errorMessage) {
      MUY_LOGE("Timeout waiting for player to be ready (60s)");
    } else {
      MUY_LOGE("AVPlayer setup failed: %s", [errorMessage UTF8String]);
    }
    return false;
  }
  
  // Store objects
  {
    std::lock_guard<std::mutex> lock(mutex_);
    asset_ = (__bridge_retained void *)asset;
    player_ = (__bridge_retained void *)player;
    playerItem_ = (__bridge_retained void *)playerItem;
    playerVideoOutput_ = (__bridge_retained void *)videoOutput;
    mediaInfo_ = capturedMediaInfo;
  }
  
  MUY_LOGI("AVPlayer ready for playback");
  MUY_TTFF_MILESTONE("asset_configured");
  
  if (mediaInfoCallback_) {
    mediaInfoCallback_(mediaInfo_);
  }
  
  return true;
}

// Local file handling using AVAssetReader (original approach)
bool IOSVideoDecoder::openWithAssetReader(NSURL *url) {
  MUY_LOGI("Using AVAssetReader for local file");
  useAVPlayer_ = false;
  
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block BOOL setupSuccess = NO;
  __block NSString *errorMessage = nil;
  __block AVURLAsset *createdAsset = nil;
  __block AVAssetReader *createdReader = nil;
  __block AVAssetReaderTrackOutput *createdOutput = nil;
  __block MediaInfo capturedMediaInfo = {};
  
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSDictionary *options = @{AVURLAssetPreferPreciseDurationAndTimingKey : @YES};
      createdAsset = [[AVURLAsset alloc] initWithURL:url options:options];
      
      dispatch_semaphore_t loadSemaphore = dispatch_semaphore_create(0);
      __block BOOL keysLoaded = NO;
      __block AVAssetTrack *videoTrack = nil;
      
      [createdAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration", @"playable"] completionHandler:^{
        @autoreleasepool {
          if (!createdAsset.playable) {
            errorMessage = @"Asset is not playable";
            dispatch_semaphore_signal(loadSemaphore);
            return;
          }
          
          NSArray<AVAssetTrack *> *videoTracks = [createdAsset tracksWithMediaType:AVMediaTypeVideo];
          if (videoTracks.count == 0) {
            errorMessage = @"No video tracks found";
            dispatch_semaphore_signal(loadSemaphore);
            return;
          }
          
          videoTrack = videoTracks.firstObject;
          keysLoaded = YES;
          dispatch_semaphore_signal(loadSemaphore);
        }
      }];
      
      dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC);
      if (dispatch_semaphore_wait(loadSemaphore, timeout) != 0 || !keysLoaded) {
        if (!errorMessage) errorMessage = @"Timeout loading asset";
        dispatch_semaphore_signal(semaphore);
        return;
      }
      
      CGSize size = videoTrack.naturalSize;
      capturedMediaInfo.videoWidth = static_cast<int32_t>(size.width);
      capturedMediaInfo.videoHeight = static_cast<int32_t>(size.height);
      capturedMediaInfo.frameRate = videoTrack.nominalFrameRate;
      capturedMediaInfo.durationNanos = static_cast<int64_t>(CMTimeGetSeconds(createdAsset.duration) * kNanosPerSecond);
      capturedMediaInfo.hasVideo = true;
      
      NSError *error = nil;
      createdReader = [[AVAssetReader alloc] initWithAsset:createdAsset error:&error];
      if (error) {
        errorMessage = [NSString stringWithFormat:@"Failed to create reader: %@", error.localizedDescription];
        dispatch_semaphore_signal(semaphore);
        return;
      }
      
      NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      };
      createdOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
      createdOutput.alwaysCopiesSampleData = NO;
      
      if ([createdReader canAddOutput:createdOutput]) {
        [createdReader addOutput:createdOutput];
        setupSuccess = YES;
      } else {
        errorMessage = @"Cannot add output to reader";
      }
      
      dispatch_semaphore_signal(semaphore);
    }
  });
  
  dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC);
  if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
    MUY_LOGE("Timeout setting up asset reader");
    return false;
  }
  
  if (!setupSuccess) {
    MUY_LOGE("AssetReader setup failed: %s", errorMessage ? [errorMessage UTF8String] : "Unknown");
    return false;
  }
  
  {
    std::lock_guard<std::mutex> lock(mutex_);
    asset_ = (__bridge_retained void *)createdAsset;
    assetReader_ = (__bridge_retained void *)createdReader;
    videoOutput_ = (__bridge_retained void *)createdOutput;
    mediaInfo_ = capturedMediaInfo;
  }
  
  MUY_LOGI("Asset reader configured successfully");
  MUY_TTFF_MILESTONE("asset_configured");
  
  if (mediaInfoCallback_) {
    mediaInfoCallback_(mediaInfo_);
  }
  
  return true;
}

void IOSVideoDecoder::start() {
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);

    if (running_.load()) {
      return;
    }

    if (useAVPlayer_) {
      // Start AVPlayer
      AVPlayer *player = (__bridge AVPlayer *)player_;
      [player play];
      running_.store(true);
      endOfStream_.store(false);
      MUY_LOGI("AVPlayer started");
      
      // Start decode loop for AVPlayer
      dispatch_async(decodeQueue_, ^{
        playerDecodeLoop();
      });
    } else {
      // Start AVAssetReader
      AVAssetReader *reader = (__bridge AVAssetReader *)assetReader_;
      if (![reader startReading]) {
        MUY_LOGE("Failed to start reading: %s",
                 [reader.error.localizedDescription UTF8String]);
        return;
      }
      
      running_.store(true);
      endOfStream_.store(false);
      MUY_TTFF_MILESTONE("decode_started");
      
      dispatch_async(decodeQueue_, ^{
        decodeLoop();
      });
    }
  }
}

void IOSVideoDecoder::playerDecodeLoop() {
  @autoreleasepool {
    MUY_LOGI("Player decode loop started");
    
    AVPlayer *player = (__bridge AVPlayer *)player_;
    AVPlayerItemVideoOutput *videoOutput = (__bridge AVPlayerItemVideoOutput *)playerVideoOutput_;
    
    CMTime frameInterval = CMTimeMake(1, static_cast<int32_t>(mediaInfo_.frameRate > 0 ? mediaInfo_.frameRate : 30));
    
    while (running_.load()) {
      @autoreleasepool {
        CMTime currentTime = player.currentTime;
        
        if ([videoOutput hasNewPixelBufferForItemTime:currentTime]) {
          CMTime actualTime;
          CVPixelBufferRef pixelBuffer = [videoOutput copyPixelBufferForItemTime:currentTime itemTimeForDisplay:&actualTime];
          
          if (pixelBuffer) {
            // Debug: Log pixel buffer info on first frame
            static bool logged = false;
            if (!logged) {
              OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
              size_t width = CVPixelBufferGetWidth(pixelBuffer);
              size_t height = CVPixelBufferGetHeight(pixelBuffer);
              size_t planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
              Boolean hasIOSurface = (CVPixelBufferGetIOSurface(pixelBuffer) != nullptr);
              
              char formatStr[5] = {0};
              formatStr[0] = (pixelFormat >> 24) & 0xFF;
              formatStr[1] = (pixelFormat >> 16) & 0xFF;
              formatStr[2] = (pixelFormat >> 8) & 0xFF;
              formatStr[3] = pixelFormat & 0xFF;
              
              MUY_LOGI("First frame pixel buffer: %zux%zu, format: '%s' (0x%08X), planes: %zu, IOSurface: %s",
                       width, height, formatStr, pixelFormat, planeCount,
                       hasIOSurface ? "YES" : "NO");
              logged = true;
            }
            
            Timestamp ptsNanos = static_cast<Timestamp>(CMTimeGetSeconds(actualTime) * kNanosPerSecond);
            
            if (frameCallback_) {
              frameCallback_(pixelBuffer, ptsNanos);
            }
            
            CVPixelBufferRelease(pixelBuffer);
          }
        }
        
        // Check if playback ended
        AVPlayerItem *item = (__bridge AVPlayerItem *)playerItem_;
        if (CMTimeCompare(currentTime, item.duration) >= 0) {
          endOfStream_.store(true);
          MUY_LOGI("End of stream");
          break;
        }
        
        // Sleep for approximately one frame duration
        [NSThread sleepForTimeInterval:CMTimeGetSeconds(frameInterval) * 0.5];
      }
    }
    
    MUY_LOGI("Player decode loop exited");
  }
}

void IOSVideoDecoder::decodeLoop() {
  @autoreleasepool {
    MUY_LOGI("Decode loop started");

    AVAssetReaderTrackOutput *output =
        (__bridge AVAssetReaderTrackOutput *)videoOutput_;

    while (running_.load()) {
      @autoreleasepool {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];

        if (!sampleBuffer) {
          AVAssetReader *reader = (__bridge AVAssetReader *)assetReader_;
          if (reader.status == AVAssetReaderStatusCompleted) {
            endOfStream_.store(true);
            MUY_LOGI("End of stream");
          }
          break;
        }

        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        Timestamp ptsNanos = static_cast<Timestamp>(CMTimeGetSeconds(pts) * kNanosPerSecond);

        if (frameCallback_ && pixelBuffer) {
          CVPixelBufferRetain(pixelBuffer);
          frameCallback_(pixelBuffer, ptsNanos);
        }

        CFRelease(sampleBuffer);
      }
    }

    MUY_LOGI("Decode loop exited");
  }
}

void IOSVideoDecoder::stop() {
  running_.store(false);

  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);
    
    if (useAVPlayer_) {
      AVPlayer *player = (__bridge AVPlayer *)player_;
      [player pause];
    } else {
      AVAssetReader *reader = (__bridge AVAssetReader *)assetReader_;
      [reader cancelReading];
    }
  }
}

void IOSVideoDecoder::seek(Timestamp positionNanos) {
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);

    if (useAVPlayer_) {
      AVPlayer *player = (__bridge AVPlayer *)player_;
      CMTime seekTime = CMTimeMakeWithSeconds((double)positionNanos / kNanosPerSecond, NSEC_PER_SEC);
      [player seekToTime:seekTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
      MUY_LOGI("Seeked to %.2fs", (double)positionNanos / kNanosPerSecond);
    } else {
      MUY_LOGW("Seek not fully implemented for AVAssetReader");
    }
  }
}

void IOSVideoDecoder::release() {
  stop();

  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);

    if (decompressionSession_) {
      VTDecompressionSessionInvalidate(decompressionSession_);
      CFRelease(decompressionSession_);
      decompressionSession_ = nullptr;
    }

    if (formatDescription_) {
      CFRelease(formatDescription_);
      formatDescription_ = nullptr;
    }

    if (videoOutput_) {
      CFRelease(videoOutput_);
      videoOutput_ = nil;
    }

    if (assetReader_) {
      CFRelease(assetReader_);
      assetReader_ = nil;
    }

    if (asset_) {
      CFRelease(asset_);
      asset_ = nil;
    }
    
    // AVPlayer cleanup
    if (playerVideoOutput_) {
      CFRelease(playerVideoOutput_);
      playerVideoOutput_ = nil;
    }
    
    if (player_) {
      CFRelease(player_);
      player_ = nil;
    }
    
    if (playerItem_) {
      CFRelease(playerItem_);
      playerItem_ = nil;
    }

    useAVPlayer_ = false;
    MUY_LOGI("Decoder released");
  }
}

void IOSVideoDecoder::setFrameCallback(FrameCallback callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  frameCallback_ = std::move(callback);
}

void IOSVideoDecoder::setMediaInfoCallback(MediaInfoCallback callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  mediaInfoCallback_ = std::move(callback);
}

} // namespace ios
} // namespace muybridge
