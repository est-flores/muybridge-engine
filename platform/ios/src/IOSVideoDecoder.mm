#import "IOSVideoDecoder.h"

namespace muybridge {
namespace ios {

IOSVideoDecoder::IOSVideoDecoder()
    : asset_(nil), assetReader_(nil), videoOutput_(nil),
      decompressionSession_(nullptr), formatDescription_(nullptr),
      decodeQueue_(nil) {

  decodeQueue_ =
      dispatch_queue_create("com.muybridge.decode", DISPATCH_QUEUE_SERIAL);
  MUY_LOGI("IOSVideoDecoder created");
}

IOSVideoDecoder::~IOSVideoDecoder() { release(); }

bool IOSVideoDecoder::open(const std::string &url) {
  MUY_TTFF_MILESTONE("open_start");
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);

    // Create URL
    NSURL *mediaURL = nil;
    NSString *urlString = [NSString stringWithUTF8String:url.c_str()];

    if ([urlString hasPrefix:@"http://"] || [urlString hasPrefix:@"https://"]) {
      mediaURL = [NSURL URLWithString:urlString];
    } else {
      mediaURL = [NSURL fileURLWithPath:urlString];
    }

    // Create asset
    AVAsset *asset = [AVAsset assetWithURL:mediaURL];
    asset_ = (__bridge_retained void *)asset;

    // Load tracks synchronously
    NSError *error = nil;
    NSArray<AVAssetTrack *> *videoTracks =
        [asset tracksWithMediaType:AVMediaTypeVideo];

    if (videoTracks.count == 0) {
      MUY_LOGE("No video tracks found");
      return false;
    }

    AVAssetTrack *videoTrack = videoTracks.firstObject;

    // Extract media info
    mediaInfo_.videoWidth = static_cast<int32_t>(videoTrack.naturalSize.width);
    mediaInfo_.videoHeight =
        static_cast<int32_t>(videoTrack.naturalSize.height);
    mediaInfo_.frameRate = videoTrack.nominalFrameRate;
    mediaInfo_.durationNanos = static_cast<int64_t>(
        CMTimeGetSeconds(asset.duration) * kNanosPerSecond);
    mediaInfo_.hasVideo = true;

    MUY_LOGI("Video: %dx%d @ %.1f fps", mediaInfo_.videoWidth,
             mediaInfo_.videoHeight, mediaInfo_.frameRate);

    // Create asset reader
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                           error:&error];
    if (error) {
      MUY_LOGE("Failed to create asset reader: %s",
               [error.localizedDescription UTF8String]);
      return false;
    }
    assetReader_ = (__bridge_retained void *)reader;

    // Configure output for hardware decode
    NSDictionary *outputSettings = @{
      (NSString *)kCVPixelBufferPixelFormatTypeKey :
          @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                         outputSettings:outputSettings];
    output.alwaysCopiesSampleData = NO;
    videoOutput_ = (__bridge_retained void *)output;

    if ([reader canAddOutput:output]) {
      [reader addOutput:output];
    } else {
      MUY_LOGE("Cannot add output to reader");
      return false;
    }

    MUY_TTFF_MILESTONE("asset_configured");

    // Notify media info
    if (mediaInfoCallback_) {
      mediaInfoCallback_(mediaInfo_);
    }

    return true;
  }
}

void IOSVideoDecoder::start() {
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);

    if (running_.load()) {
      return;
    }

    AVAssetReader *reader = (__bridge AVAssetReader *)assetReader_;
    if (![reader startReading]) {
      MUY_LOGE("Failed to start reading: %s",
               [reader.error.localizedDescription UTF8String]);
      return;
    }

    running_.store(true);
    endOfStream_.store(false);

    MUY_TTFF_MILESTONE("decode_started");

    // Start decode loop on background queue
    dispatch_async(decodeQueue_, ^{
      decodeLoop();
    });
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

        // Get pixel buffer
        CVPixelBufferRef pixelBuffer =
            CMSampleBufferGetImageBuffer(sampleBuffer);
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        Timestamp ptsNanos =
            static_cast<Timestamp>(CMTimeGetSeconds(pts) * kNanosPerSecond);

        // Notify frame available
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
    AVAssetReader *reader = (__bridge AVAssetReader *)assetReader_;
    [reader cancelReading];
  }
}

void IOSVideoDecoder::seek(Timestamp positionNanos) {
  @autoreleasepool {
    std::lock_guard<std::mutex> lock(mutex_);

    // AVAssetReader doesn't support seeking directly
    // Need to recreate with time range
    // For now, just log
    MUY_LOGW("Seek not fully implemented yet");
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
