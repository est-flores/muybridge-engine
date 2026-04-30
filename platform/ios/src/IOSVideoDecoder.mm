#import "IOSVideoDecoder.h"

namespace muybridge {
namespace ios {

IOSVideoDecoder::IOSVideoDecoder()
    : asset_(nil), assetReader_(nil), videoOutput_(nil),
      player_(nil), playerItem_(nil), playerVideoOutput_(nil), playerReadyObserver_(nil),
      decompressionSession_(nullptr), formatDescription_(nullptr),
      decodeQueue_(nil), useAVPlayer_(false), decodeQueueMarker_(0) {

  decodeQueue_ =
      dispatch_queue_create("com.muybridge.decode", DISPATCH_QUEUE_SERIAL);
  // Tag this queue so dispatch_sync calls can detect if they're already on it.
  dispatch_queue_set_specific(decodeQueue_, &decodeQueueMarker_, &decodeQueueMarker_, nullptr);
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

  // AVPlayer objects MUST be created on the main thread. Creating them on a
  // background thread and then running [[NSRunLoop mainRunLoop] runUntilDate:]
  // from that thread is undefined behaviour — it corrupts ARC retain counts
  // and causes EXC_BAD_ACCESS. Use dispatch_sync to create on main, then wait
  // on a semaphore (which does NOT block the main runloop) from the caller.
  __block AVURLAsset *createdAsset = nil;
  __block AVPlayer *createdPlayer = nil;
  __block AVPlayerItem *createdPlayerItem = nil;
  __block AVPlayerItemVideoOutput *createdVideoOutput = nil;

  dispatch_sync(dispatch_get_main_queue(), ^{
    @autoreleasepool {
      createdAsset = [AVURLAsset assetWithURL:url];
      createdPlayerItem = [AVPlayerItem playerItemWithAsset:createdAsset];
      createdPlayer = [AVPlayer playerWithPlayerItem:createdPlayerItem];

      if (@available(iOS 10.0, *)) {
        createdPlayer.automaticallyWaitsToMinimizeStalling = YES;
        createdPlayerItem.preferredForwardBufferDuration = 2.0;
      }

      NSDictionary *outputSettings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{}
      };
      createdVideoOutput = [[AVPlayerItemVideoOutput alloc]
          initWithPixelBufferAttributes:outputSettings];
      [createdPlayerItem addOutput:createdVideoOutput];

      [createdPlayer play];
    }
  });

  LOAD_PHASE("AVPlayer.play() called — waiting for player ready (network)...");

  // Poll playerItem.status from a separate background thread. The calling
  // thread (loadQueue) waits on the semaphore below; the main thread remains
  // free to run its runloop and deliver AVPlayer KVO / network callbacks.
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      int attempts = 0;
      const int maxAttempts = 1875; // 30 s at 16 ms intervals

      while (createdPlayerItem.status == AVPlayerItemStatusUnknown && attempts < maxAttempts) {
        if (createdPlayerItem.error) {
          errorMessage = createdPlayerItem.error.localizedDescription;
          MUY_LOGE("Player item error during load: %s", [errorMessage UTF8String]);
          dispatch_semaphore_signal(semaphore);
          return;
        }

        [NSThread sleepForTimeInterval:0.016];
        attempts++;

        if (attempts % 125 == 0) {
          LOAD_PHASE("still waiting — %.1fs (network). MOV with end-moov? Try MP4+faststart.",
                     attempts * 0.016);
        }
      }

      if (createdPlayerItem.status == AVPlayerItemStatusFailed) {
        errorMessage = createdPlayerItem.error.localizedDescription;
        if (!errorMessage) errorMessage = @"Player item failed";
        LOAD_PHASE("ERROR: player item failed — %s", [errorMessage UTF8String]);
        dispatch_semaphore_signal(semaphore);
        return;
      }

      if (createdPlayerItem.status != AVPlayerItemStatusReadyToPlay) {
        LOAD_PHASE("ERROR: timeout waiting for player ready (30s)");
        errorMessage = @"Player item not ready after timeout";
        dispatch_semaphore_signal(semaphore);
        return;
      }

      LOAD_PHASE("player ready — loading track metadata (renderer)...");

      dispatch_async(dispatch_get_main_queue(), ^{ [createdPlayer pause]; });

      [createdAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"]
                                 completionHandler:^{
        LOAD_PHASE("tracks key loaded — reading video track properties (renderer)...");
        NSArray<AVAssetTrack *> *videoTracks =
            [createdAsset tracksWithMediaType:AVMediaTypeVideo];

        if (videoTracks.count == 0) {
          LOAD_PHASE("ERROR: no video tracks found");
          errorMessage = @"No video tracks found";
          dispatch_semaphore_signal(semaphore);
          return;
        }

        AVAssetTrack *videoTrack = videoTracks.firstObject;

        [videoTrack loadValuesAsynchronouslyForKeys:@[@"naturalSize", @"nominalFrameRate"]
                                 completionHandler:^{
          CGSize size = videoTrack.naturalSize;
          capturedMediaInfo.videoWidth  = static_cast<int32_t>(size.width);
          capturedMediaInfo.videoHeight = static_cast<int32_t>(size.height);
          capturedMediaInfo.frameRate   = videoTrack.nominalFrameRate > 0
                                          ? videoTrack.nominalFrameRate : 30.0f;
          capturedMediaInfo.durationNanos =
              static_cast<int64_t>(CMTimeGetSeconds(createdAsset.duration) * kNanosPerSecond);
          capturedMediaInfo.hasVideo = true;

          LOAD_PHASE("video info: %dx%d @ %.1ffps, duration: %.1fs — setup complete",
                     capturedMediaInfo.videoWidth,
                     capturedMediaInfo.videoHeight,
                     capturedMediaInfo.frameRate,
                     (double)capturedMediaInfo.durationNanos / kNanosPerSecond);

          MUY_LOGI("Video: %dx%d @ %.1f fps, duration: %.2fs",
                   capturedMediaInfo.videoWidth, capturedMediaInfo.videoHeight,
                   capturedMediaInfo.frameRate,
                   (double)capturedMediaInfo.durationNanos / kNanosPerSecond);

          setupSuccess = YES;
          dispatch_semaphore_signal(semaphore);
        }];
      }];
    }
  });

  // Wait on the background (loadQueue) thread. The main thread is NOT blocked,
  // so AVPlayer's runloop sources continue firing normally.
  dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC);
  if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
    MUY_LOGE("Timeout waiting for AVPlayer setup (30s)");
    dispatch_async(dispatch_get_main_queue(), ^{ [createdPlayer pause]; });
    return false;
  }

  if (!setupSuccess) {
    MUY_LOGE("AVPlayer setup failed: %s", errorMessage ? [errorMessage UTF8String] : "unknown");
    dispatch_async(dispatch_get_main_queue(), ^{ [createdPlayer pause]; });
    return false;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    asset_             = (__bridge_retained void *)createdAsset;
    player_            = (__bridge_retained void *)createdPlayer;
    playerItem_        = (__bridge_retained void *)createdPlayerItem;
    playerVideoOutput_ = (__bridge_retained void *)createdVideoOutput;
    mediaInfo_         = capturedMediaInfo;
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
    bool logged = false;

    while (running_.load()) {
      @autoreleasepool {
        CMTime currentTime = player.currentTime;

        if ([videoOutput hasNewPixelBufferForItemTime:currentTime]) {
          CMTime actualTime;
          CVPixelBufferRef pixelBuffer = [videoOutput copyPixelBufferForItemTime:currentTime itemTimeForDisplay:&actualTime];

          if (pixelBuffer) {
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

        // Check if playback ended — skip for indefinite/invalid durations (live streams).
        // EOS for finite content is also signalled via AVPlayerItemDidPlayToEndTime
        // notification, but checking here lets the loop exit cleanly without busy-spinning.
        AVPlayerItem *item = (__bridge AVPlayerItem *)playerItem_;
        CMTime duration = item.duration;
        if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration) &&
            CMTimeCompare(currentTime, duration) >= 0) {
          endOfStream_.store(true);
          running_.store(false);
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
            running_.store(false);
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
          CVPixelBufferRelease(pixelBuffer);
        }

        CFRelease(sampleBuffer);
      }
    }

    MUY_LOGI("Decode loop exited");
  }
}

void IOSVideoDecoder::stop() {
  if (!running_.load()) {
    return;
  }

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

  // Block until the decode loop actually exits. The queue is serial so this
  // no-op block cannot run until the loop function returns. Without this,
  // release() would CFRelease ObjC objects while the loop is still using them.
  // Skip if already on decodeQueue_ to avoid deadlock (e.g. dealloc triggered
  // from inside a callback closure that held the last strong reference).
  if (!dispatch_get_specific(&decodeQueueMarker_)) {
    dispatch_sync(decodeQueue_, ^{});
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

  // Unconditional drain: if the decode loop exited on its own (EOS set
  // running_=false), stop() returned early but the loop block may not have
  // fully returned yet. Ensure the queue is idle before freeing ObjC objects.
  // Skip if already on decodeQueue_ to avoid deadlock.
  if (!dispatch_get_specific(&decodeQueueMarker_)) {
    dispatch_sync(decodeQueue_, ^{});
  }

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
