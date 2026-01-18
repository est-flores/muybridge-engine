#include "AndroidVideoDecoder.h"

#include <chrono>
#include <cstring>

namespace muybridge {
namespace android {

AndroidVideoDecoder::AndroidVideoDecoder() {
  MUY_LOGI("AndroidVideoDecoder created");
}

AndroidVideoDecoder::~AndroidVideoDecoder() { release(); }

void AndroidVideoDecoder::setSurface(ANativeWindow *window) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (surface_) {
    ANativeWindow_release(surface_);
  }

  surface_ = window;
  if (surface_) {
    ANativeWindow_acquire(surface_);
  }

  MUY_LOGI("Surface set: %p", surface_);
}

bool AndroidVideoDecoder::open(const std::string &url) {
  MUY_TTFF_MILESTONE("open_start");
  std::lock_guard<std::mutex> lock(mutex_);

  // Create extractor
  extractor_ = AMediaExtractor_new();
  if (!extractor_) {
    MUY_LOGE("Failed to create AMediaExtractor");
    return false;
  }

  // Set data source
  media_status_t status =
      AMediaExtractor_setDataSource(extractor_, url.c_str());
  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to set data source: %s (error %d)", url.c_str(), status);
    return false;
  }
  MUY_TTFF_MILESTONE("extractor_configured");

  // Find video track
  videoTrackIndex_ = findVideoTrack();
  if (videoTrackIndex_ < 0) {
    MUY_LOGE("No video track found");
    return false;
  }

  // Select video track
  AMediaExtractor_selectTrack(extractor_,
                              static_cast<size_t>(videoTrackIndex_));

  // Get format and configure codec
  AMediaFormat *format = AMediaExtractor_getTrackFormat(
      extractor_, static_cast<size_t>(videoTrackIndex_));

  if (!configureCodec(format)) {
    AMediaFormat_delete(format);
    return false;
  }

  AMediaFormat_delete(format);
  MUY_TTFF_MILESTONE("codec_configured");

  // Notify media info
  if (mediaInfoCallback_) {
    mediaInfoCallback_(mediaInfo_);
  }

  return true;
}

int AndroidVideoDecoder::findVideoTrack() {
  size_t trackCount = AMediaExtractor_getTrackCount(extractor_);

  for (size_t i = 0; i < trackCount; ++i) {
    AMediaFormat *format = AMediaExtractor_getTrackFormat(extractor_, i);

    const char *mime = nullptr;
    if (AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime)) {
      if (std::strncmp(mime, "video/", 6) == 0) {
        // Extract media info
        int32_t width = 0, height = 0;
        int64_t duration = 0;
        float frameRate = 0.0f;

        AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_WIDTH, &width);
        AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_HEIGHT, &height);
        AMediaFormat_getInt64(format, AMEDIAFORMAT_KEY_DURATION, &duration);
        AMediaFormat_getFloat(format, AMEDIAFORMAT_KEY_FRAME_RATE, &frameRate);

        mediaInfo_.videoWidth = width;
        mediaInfo_.videoHeight = height;
        mediaInfo_.durationNanos = duration * 1000; // us to ns
        mediaInfo_.frameRate = frameRate;
        mediaInfo_.hasVideo = true;
        mediaInfo_.videoCodec = mime;

        MUY_LOGI("Video: %dx%d @ %.1f fps, duration: %lld ms", width, height,
                 frameRate, duration / 1000);

        AMediaFormat_delete(format);
        return static_cast<int>(i);
      }
    }
    AMediaFormat_delete(format);
  }
  return -1;
}

bool AndroidVideoDecoder::configureCodec(AMediaFormat *format) {
  const char *mime = nullptr;
  if (!AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime)) {
    MUY_LOGE("Failed to get MIME type");
    return false;
  }

  // Create codec by type
  codec_ = AMediaCodec_createDecoderByType(mime);
  if (!codec_) {
    MUY_LOGE("Failed to create codec for %s", mime);
    return false;
  }

  // Configure with surface for zero-copy output
  media_status_t status =
      AMediaCodec_configure(codec_, format, surface_, nullptr, 0);

  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to configure codec: %d", status);
    return false;
  }

  MUY_LOGI("Codec configured: %s", mime);
  return true;
}

void AndroidVideoDecoder::start() {
  std::lock_guard<std::mutex> lock(mutex_);

  if (running_.load()) {
    return;
  }

  if (!codec_) {
    MUY_LOGE("Cannot start: codec not configured");
    return;
  }

  media_status_t status = AMediaCodec_start(codec_);
  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to start codec: %d", status);
    return;
  }

  running_.store(true);
  endOfStream_.store(false);

  decodeThread_ = std::thread(&AndroidVideoDecoder::decodeLoop, this);
  MUY_TTFF_MILESTONE("decode_started");
}

void AndroidVideoDecoder::stop() {
  running_.store(false);

  if (decodeThread_.joinable()) {
    decodeThread_.join();
  }

  std::lock_guard<std::mutex> lock(mutex_);
  if (codec_) {
    AMediaCodec_stop(codec_);
  }
}

void AndroidVideoDecoder::seek(Timestamp positionNanos) {
  seeking_.store(true);

  std::lock_guard<std::mutex> lock(mutex_);
  if (extractor_) {
    int64_t positionUs = positionNanos / 1000;
    AMediaExtractor_seekTo(extractor_, positionUs,
                           AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC);
  }

  if (codec_) {
    AMediaCodec_flush(codec_);
  }

  endOfStream_.store(false);
  seeking_.store(false);
}

void AndroidVideoDecoder::release() {
  stop();

  std::lock_guard<std::mutex> lock(mutex_);

  if (codec_) {
    AMediaCodec_delete(codec_);
    codec_ = nullptr;
  }

  if (extractor_) {
    AMediaExtractor_delete(extractor_);
    extractor_ = nullptr;
  }

  if (surface_) {
    ANativeWindow_release(surface_);
    surface_ = nullptr;
  }

  MUY_LOGI("Decoder released");
}

void AndroidVideoDecoder::setFrameCallback(FrameCallback callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  frameCallback_ = std::move(callback);
}

void AndroidVideoDecoder::setMediaInfoCallback(MediaInfoCallback callback) {
  std::lock_guard<std::mutex> lock(mutex_);
  mediaInfoCallback_ = std::move(callback);
}

void AndroidVideoDecoder::decodeLoop() {
  MUY_LOGI("Decode thread started");

  while (running_.load()) {
    if (seeking_.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }

    // Feed input
    if (!endOfStream_.load()) {
      extractSample();
    }

    // Process output
    processOutput();
  }

  MUY_LOGI("Decode thread exited");
}

bool AndroidVideoDecoder::extractSample() {
  ssize_t bufIdx = AMediaCodec_dequeueInputBuffer(codec_, 0);
  if (bufIdx < 0) {
    return false;
  }

  size_t bufSize = 0;
  uint8_t *buf =
      AMediaCodec_getInputBuffer(codec_, static_cast<size_t>(bufIdx), &bufSize);

  if (!buf) {
    return false;
  }

  ssize_t sampleSize = AMediaExtractor_readSampleData(extractor_, buf, bufSize);

  if (sampleSize < 0) {
    // End of stream
    AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(bufIdx), 0, 0, 0,
                                 AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
    endOfStream_.store(true);
    MUY_LOGI("End of stream signaled");
    return false;
  }

  int64_t pts = AMediaExtractor_getSampleTime(extractor_);
  uint32_t flags = 0;

  if (AMediaExtractor_getSampleFlags(extractor_) &
      AMEDIAEXTRACTOR_SAMPLE_FLAG_SYNC) {
    flags |= AMEDIACODEC_BUFFER_FLAG_KEY_FRAME;
  }

  AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(bufIdx), 0,
                               static_cast<size_t>(sampleSize),
                               static_cast<uint64_t>(pts), flags);

  AMediaExtractor_advance(extractor_);
  return true;
}

bool AndroidVideoDecoder::processOutput() {
  AMediaCodecBufferInfo info;
  ssize_t outIdx = AMediaCodec_dequeueOutputBuffer(codec_, &info, 0);

  if (outIdx >= 0) {
    Timestamp pts = static_cast<Timestamp>(info.presentationTimeUs) * 1000;

    // Notify frame available
    if (frameCallback_) {
      frameCallback_(pts);
    }

    // Release to surface for rendering
    AMediaCodec_releaseOutputBuffer(codec_, static_cast<size_t>(outIdx), true);
    return true;
  }

  if (outIdx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
    AMediaFormat *newFormat = AMediaCodec_getOutputFormat(codec_);
    MUY_LOGI("Output format changed");
    AMediaFormat_delete(newFormat);
  }

  return false;
}

} // namespace android
} // namespace muybridge
