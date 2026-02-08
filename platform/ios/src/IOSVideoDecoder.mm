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

// Network URL handling using AVPlayer + AVPlayerItemVideoOutput
bool IOSVideoDecoder::openWithAVPlayer(NSURL *url) {
  MUY_LOGI("Using AVPlayer for network URL");
  useAVPlayer_ = true;
  
  __block BOOL setupSuccess = NO;
  __block NSString *errorMessage = nil;
  __block MediaInfo capturedMediaInfo = {};
  
  // Create player item with asset for better control
  AVURLAsset *asset = [AVURLAsset assetWithURL:url];
  AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:asset];
  AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
  
  // Important: Set automaticallyWaitsToMinimizeStalling for network playback
  if (@available(iOS 10.0, *)) {
    player.automaticallyWaitsToMinimizeStalling = YES;
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
  MUY_LOGI("Started player to trigger buffering");
  
  // Poll for ready status directly on background queue (no nested dispatch)
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      int attempts = 0;
      const int maxAttempts = 300; // 30 seconds total
      
      while (playerItem.status == AVPlayerItemStatusUnknown && attempts < maxAttempts) {
        // Check for errors during loading
        if (playerItem.error) {
          errorMessage = playerItem.error.localizedDescription;
          MUY_LOGE("Player item error during load: %s", [errorMessage UTF8String]);
          dispatch_semaphore_signal(semaphore);
          return;
        }
        
        [NSThread sleepForTimeInterval:0.1];
        attempts++;
        
        // Log progress every 5 seconds
        if (attempts % 50 == 0) {
          MUY_LOGI("Waiting for player... attempt %d/300, status: %ld", attempts, (long)playerItem.status);
        }
      }
      
      if (playerItem.status == AVPlayerItemStatusFailed) {
        errorMessage = playerItem.error.localizedDescription;
        if (!errorMessage) errorMessage = @"Player item failed";
        MUY_LOGE("Player item failed: %s", [errorMessage UTF8String]);
        dispatch_semaphore_signal(semaphore);
        return;
      }
      
      if (playerItem.status != AVPlayerItemStatusReadyToPlay) {
        errorMessage = @"Player item not ready after timeout";
        MUY_LOGE("Player item timeout, status: %ld, error: %s", 
                 (long)playerItem.status,
                 playerItem.error ? [playerItem.error.localizedDescription UTF8String] : "none");
        dispatch_semaphore_signal(semaphore);
        return;
      }
      
      MUY_LOGI("Player item ready to play!");
      
      // Pause now that we're ready (will resume when start() is called)
      dispatch_async(dispatch_get_main_queue(), ^{
        [player pause];
      });
      
      // Load track properties asynchronously before accessing them
      [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^{
        NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        
        if (videoTracks.count == 0) {
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
