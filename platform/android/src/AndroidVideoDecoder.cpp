#include "AndroidVideoDecoder.h"

#include <chrono>
#include <cstring>
#include <vector>

namespace muybridge {
namespace android {

int64_t AndroidVideoDecoder::steadyClockNanos() noexcept {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

AndroidVideoDecoder::AndroidVideoDecoder() {
  MUY_LOGI("AndroidVideoDecoder created");
}

AndroidVideoDecoder::~AndroidVideoDecoder() { release(); }

void AndroidVideoDecoder::setSurface(ANativeWindow *window) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (surface_) ANativeWindow_release(surface_);
  surface_ = window;
  if (surface_) ANativeWindow_acquire(surface_);
  MUY_LOGI("Surface set: %p", surface_);
}

//------------------------------------------------------------------------------
// Open / track detection
//------------------------------------------------------------------------------

bool AndroidVideoDecoder::open(const std::string &url) {
  MUY_TTFF_MILESTONE("open_start");
  std::lock_guard<std::mutex> lock(mutex_);

  // Video extractor — selects only the video track
  extractor_ = AMediaExtractor_new();
  if (!extractor_) {
    MUY_LOGE("Failed to create video AMediaExtractor");
    return false;
  }

  media_status_t status = AMediaExtractor_setDataSource(extractor_, url.c_str());
  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to set data source: %s (error %d)", url.c_str(), status);
    return false;
  }
  MUY_TTFF_MILESTONE("extractor_configured");

  videoTrackIndex_ = findVideoTrack();
  if (videoTrackIndex_ < 0) {
    MUY_LOGE("No video track found");
    return false;
  }
  AMediaExtractor_selectTrack(extractor_, static_cast<size_t>(videoTrackIndex_));

  AMediaFormat *videoFmt = AMediaExtractor_getTrackFormat(
      extractor_, static_cast<size_t>(videoTrackIndex_));
  if (!configureCodec(videoFmt)) {
    AMediaFormat_delete(videoFmt);
    return false;
  }
  AMediaFormat_delete(videoFmt);
  MUY_TTFF_MILESTONE("video_codec_configured");

  // Discover audio track info via the video extractor (format read; not selected)
  audioTrackIndex_ = findAudioTrack();

  if (audioTrackIndex_ >= 0) {
    // Create a SEPARATE audio extractor so the audio render thread is fully
    // self-contained and cannot block the video decode thread.
    audioExtractor_ = AMediaExtractor_new();
    if (audioExtractor_) {
      status = AMediaExtractor_setDataSource(audioExtractor_, url.c_str());
      if (status == AMEDIA_OK) {
        AMediaExtractor_selectTrack(audioExtractor_,
                                    static_cast<size_t>(audioTrackIndex_));
        AMediaFormat *audioFmt = AMediaExtractor_getTrackFormat(
            audioExtractor_, static_cast<size_t>(audioTrackIndex_));
        if (!configureAudioCodec(audioFmt)) {
          MUY_LOGW("Failed to configure audio codec - continuing without audio");
          audioTrackIndex_ = -1;
        }
        AMediaFormat_delete(audioFmt);
      } else {
        MUY_LOGW("Failed to open audio extractor - continuing without audio");
        AMediaExtractor_delete(audioExtractor_);
        audioExtractor_ = nullptr;
        audioTrackIndex_ = -1;
      }
    }
  } else {
    MUY_LOGI("No audio track found");
  }

  if (mediaInfoCallback_) mediaInfoCallback_(mediaInfo_);
  return true;
}

int AndroidVideoDecoder::findVideoTrack() {
  size_t trackCount = AMediaExtractor_getTrackCount(extractor_);
  for (size_t i = 0; i < trackCount; ++i) {
    AMediaFormat *fmt = AMediaExtractor_getTrackFormat(extractor_, i);
    const char *mime = nullptr;
    if (AMediaFormat_getString(fmt, AMEDIAFORMAT_KEY_MIME, &mime) &&
        std::strncmp(mime, "video/", 6) == 0) {
      int32_t w = 0, h = 0;
      int64_t dur = 0;
      float fps = 0.f;
      AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_WIDTH, &w);
      AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_HEIGHT, &h);
      AMediaFormat_getInt64(fmt, AMEDIAFORMAT_KEY_DURATION, &dur);
      AMediaFormat_getFloat(fmt, AMEDIAFORMAT_KEY_FRAME_RATE, &fps);
      mediaInfo_.videoWidth = w;
      mediaInfo_.videoHeight = h;
      mediaInfo_.durationNanos = dur * 1000;
      mediaInfo_.frameRate = fps;
      mediaInfo_.hasVideo = true;
      mediaInfo_.videoCodec = mime;
      MUY_LOGI("Video: %dx%d @ %.1f fps, duration: %lld ms", w, h, fps, dur / 1000);
      AMediaFormat_delete(fmt);
      return static_cast<int>(i);
    }
    AMediaFormat_delete(fmt);
  }
  return -1;
}

int AndroidVideoDecoder::findAudioTrack() {
  size_t trackCount = AMediaExtractor_getTrackCount(extractor_);
  for (size_t i = 0; i < trackCount; ++i) {
    AMediaFormat *fmt = AMediaExtractor_getTrackFormat(extractor_, i);
    const char *mime = nullptr;
    if (AMediaFormat_getString(fmt, AMEDIAFORMAT_KEY_MIME, &mime) &&
        std::strncmp(mime, "audio/", 6) == 0) {
      int32_t sampleRate = 0, channels = 0;
      AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_SAMPLE_RATE, &sampleRate);
      AMediaFormat_getInt32(fmt, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &channels);
      audioSampleRate_ = sampleRate > 0 ? sampleRate : 44100;
      audioChannelCount_ = channels > 0 ? channels : 2;
      mediaInfo_.hasAudio = true;
      mediaInfo_.audioCodec = mime;
      MUY_LOGI("Audio: %s %dHz %dch", mime, audioSampleRate_, audioChannelCount_);
      AMediaFormat_delete(fmt);
      return static_cast<int>(i);
    }
    AMediaFormat_delete(fmt);
  }
  return -1;
}

bool AndroidVideoDecoder::configureCodec(AMediaFormat *format) {
  const char *mime = nullptr;
  if (!AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime)) {
    MUY_LOGE("Failed to get video MIME type");
    return false;
  }
  codec_ = AMediaCodec_createDecoderByType(mime);
  if (!codec_) {
    MUY_LOGE("Failed to create video codec for %s", mime);
    return false;
  }
  media_status_t status = AMediaCodec_configure(codec_, format, surface_, nullptr, 0);
  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to configure video codec: %d", status);
    return false;
  }
  MUY_LOGI("Video codec configured: %s", mime);
  return true;
}

bool AndroidVideoDecoder::configureAudioCodec(AMediaFormat *format) {
  const char *mime = nullptr;
  if (!AMediaFormat_getString(format, AMEDIAFORMAT_KEY_MIME, &mime)) {
    MUY_LOGE("Failed to get audio MIME type");
    return false;
  }
  audioCodec_ = AMediaCodec_createDecoderByType(mime);
  if (!audioCodec_) {
    MUY_LOGE("Failed to create audio codec for %s", mime);
    return false;
  }
  // Hint the decoder to output PCM_I16 (encoding=2). Hardware decoders on many
  // devices default to PCM_FLOAT (encoding=4); without this hint, numFrames
  // is calculated with the wrong bytes-per-sample and audio plays at half speed.
  AMediaFormat_setInt32(format, "pcm-encoding", 2);

  media_status_t status =
      AMediaCodec_configure(audioCodec_, format, nullptr, nullptr, 0);
  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to configure audio codec: %d", status);
    AMediaCodec_delete(audioCodec_);
    audioCodec_ = nullptr;
    return false;
  }
  MUY_LOGI("Audio codec configured: %s", mime);
  return true;
}

bool AndroidVideoDecoder::openAudioStream() {
  AAudioStreamBuilder *builder = nullptr;
  aaudio_result_t result = AAudio_createStreamBuilder(&builder);
  if (result != AAUDIO_OK) {
    MUY_LOGE("AAudio_createStreamBuilder failed: %s",
             AAudio_convertResultToText(result));
    return false;
  }

  AAudioStreamBuilder_setSampleRate(builder, audioSampleRate_);
  AAudioStreamBuilder_setChannelCount(builder, audioChannelCount_);
  AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
  AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
#if __ANDROID_API__ >= 28
  AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
  AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_MOVIE);
#endif
  AAudioStreamBuilder_setPerformanceMode(builder,
                                         AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);

  result = AAudioStreamBuilder_openStream(builder, &audioStream_);
  if (result != AAUDIO_OK) {
    MUY_LOGW("Low-latency AAudio stream failed (%s), retrying with NONE mode",
             AAudio_convertResultToText(result));
    AAudioStreamBuilder_setPerformanceMode(builder,
                                           AAUDIO_PERFORMANCE_MODE_NONE);
    result = AAudioStreamBuilder_openStream(builder, &audioStream_);
  }
  AAudioStreamBuilder_delete(builder);

  if (result != AAUDIO_OK) {
    MUY_LOGE("Failed to open AAudio stream: %s",
             AAudio_convertResultToText(result));
    audioStream_ = nullptr;
    return false;
  }

  int32_t actualRate = AAudioStream_getSampleRate(audioStream_);
  int32_t actualCh = AAudioStream_getChannelCount(audioStream_);
  aaudio_format_t actualFmt = AAudioStream_getFormat(audioStream_);
  MUY_LOGI("AAudio stream opened: requested=%dHz/%dch actual=%dHz/%dch fmt=%d",
           audioSampleRate_, audioChannelCount_, actualRate, actualCh,
           static_cast<int>(actualFmt));
  return true;
}

//------------------------------------------------------------------------------
// Start / Stop / Seek / Release
//------------------------------------------------------------------------------

void AndroidVideoDecoder::start() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_.load()) return;
  if (!codec_) {
    MUY_LOGE("Cannot start: video codec not configured");
    return;
  }

  media_status_t status = AMediaCodec_start(codec_);
  if (status != AMEDIA_OK) {
    MUY_LOGE("Failed to start video codec: %d", status);
    return;
  }

  if (audioCodec_) {
    status = AMediaCodec_start(audioCodec_);
    if (status != AMEDIA_OK) {
      MUY_LOGW("Failed to start audio codec: %d - continuing without audio",
               status);
      AMediaCodec_delete(audioCodec_);
      audioCodec_ = nullptr;
    } else {
      // AAudio stream is opened inside audioRenderLoop after the first real
      // output buffer is available and the actual PCM format is known.
      audioRunning_.store(true);
      audioRenderThread_ =
          std::thread(&AndroidVideoDecoder::audioRenderLoop, this);
      MUY_LOGI("Audio thread launched");
    }
  }

  running_.store(true);
  endOfStream_.store(false);
  startPts_.store(-1);

  MUY_LOGI("Decoder starting");
  decodeThread_ = std::thread(&AndroidVideoDecoder::decodeLoop, this);
  MUY_TTFF_MILESTONE("decode_started");
}

void AndroidVideoDecoder::stop() {
  running_.store(false);
  audioRunning_.store(false);

  if (decodeThread_.joinable()) decodeThread_.join();
  if (audioRenderThread_.joinable()) audioRenderThread_.join();

  std::lock_guard<std::mutex> lock(mutex_);

  if (audioStream_) {
    AAudioStream_requestStop(audioStream_);
  }
  if (codec_) AMediaCodec_stop(codec_);
  if (audioCodec_) AMediaCodec_stop(audioCodec_);
}

void AndroidVideoDecoder::seek(Timestamp positionNanos) {
  seeking_.store(true);

  std::lock_guard<std::mutex> lock(mutex_);
  int64_t posUs = positionNanos / 1000;
  if (extractor_)
    AMediaExtractor_seekTo(extractor_, posUs, AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC);
  if (audioExtractor_)
    AMediaExtractor_seekTo(audioExtractor_, posUs,
                           AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC);
  if (codec_) AMediaCodec_flush(codec_);
  if (audioCodec_) AMediaCodec_flush(audioCodec_);

  endOfStream_.store(false);
  startPts_.store(-1);
  seeking_.store(false);
  MUY_LOGI("Seek complete - timing anchor reset");
}

void AndroidVideoDecoder::release() {
  stop();

  std::lock_guard<std::mutex> lock(mutex_);

  if (audioStream_) {
    AAudioStream_close(audioStream_);
    audioStream_ = nullptr;
  }
  if (audioCodec_) {
    AMediaCodec_delete(audioCodec_);
    audioCodec_ = nullptr;
  }
  if (codec_) {
    AMediaCodec_delete(codec_);
    codec_ = nullptr;
  }
  if (audioExtractor_) {
    AMediaExtractor_delete(audioExtractor_);
    audioExtractor_ = nullptr;
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

//------------------------------------------------------------------------------
// Decode loop — video only (audio has its own thread + extractor)
//------------------------------------------------------------------------------

void AndroidVideoDecoder::decodeLoop() {
  MUY_LOGI("Decode thread started");

  while (running_.load()) {
    if (seeking_.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }

    bool inputFed = false;
    if (!endOfStream_.load()) {
      inputFed = extractSample();
    }

    bool outputProcessed = processOutput();

    if (!inputFed && !outputProcessed) {
      std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
  }

  MUY_LOGI("Decode thread exited");
}

// Feeds only video samples from the video-only extractor.
bool AndroidVideoDecoder::extractSample() {
  int trackIndex = AMediaExtractor_getSampleTrackIndex(extractor_);

  if (trackIndex < 0) {
    // Video extractor exhausted — signal EOS to video codec
    if (!endOfStream_.load()) {
      ssize_t bufIdx = AMediaCodec_dequeueInputBuffer(codec_, 0);
      if (bufIdx >= 0) {
        AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(bufIdx),
                                     0, 0, 0,
                                     AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
        endOfStream_.store(true);
        MUY_LOGI("Video end of stream signaled");
      }
    }
    return false;
  }

  ssize_t bufIdx = AMediaCodec_dequeueInputBuffer(codec_, 0);
  if (bufIdx < 0) return false;

  size_t bufSize = 0;
  uint8_t *buf =
      AMediaCodec_getInputBuffer(codec_, static_cast<size_t>(bufIdx), &bufSize);
  if (!buf) return false;

  ssize_t sampleSize =
      AMediaExtractor_readSampleData(extractor_, buf, bufSize);
  if (sampleSize < 0) {
    AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(bufIdx),
                                 0, 0, 0, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
    endOfStream_.store(true);
    MUY_LOGI("Video EOS (readSampleData)");
    return false;
  }

  int64_t pts = AMediaExtractor_getSampleTime(extractor_);
  AMediaCodec_queueInputBuffer(codec_, static_cast<size_t>(bufIdx), 0,
                               static_cast<size_t>(sampleSize),
                               static_cast<uint64_t>(pts), 0);
  AMediaExtractor_advance(extractor_);
  return true;
}

bool AndroidVideoDecoder::processOutput() {
  AMediaCodecBufferInfo info;
  ssize_t outIdx = AMediaCodec_dequeueOutputBuffer(codec_, &info, 0);

  if (outIdx >= 0) {
    Timestamp pts = static_cast<Timestamp>(info.presentationTimeUs) * 1000;

    // Anchor wall-clock to the first decoded frame, not to start() call time.
    Timestamp anchor = startPts_.load();
    if (anchor == -1) {
      int64_t nowNs = steadyClockNanos();
      startSystemTimeNs_.store(nowNs);
      startPts_.store(pts);
      anchor = pts;
      MUY_LOGI("Timing anchor: first_pts=%.3fms wall=%.3fms",
               pts / 1.0e6, nowNs / 1.0e6);
      MUY_TTFF_MILESTONE("first_frame_decoded");
    }

    int64_t renderTimeNs = startSystemTimeNs_.load() + (pts - anchor);
    int64_t nowNs = steadyClockNanos();
    int64_t aheadNs = renderTimeNs - nowNs;

    MUY_LOGD("Frame: pts=%.3fms render_in=%.2fms", pts / 1.0e6,
             aheadNs / 1.0e6);

    // Throttle: keep at most ~1 frame ahead to avoid SurfaceTexture overflow.
    constexpr int64_t kMaxAheadNs = 33'000'000LL;
    if (aheadNs > kMaxAheadNs) {
      std::this_thread::sleep_for(
          std::chrono::nanoseconds(aheadNs - kMaxAheadNs));
    }

    if (frameCallback_) frameCallback_(pts);

    AMediaCodec_releaseOutputBufferAtTime(codec_, static_cast<size_t>(outIdx),
                                         renderTimeNs);
    return true;
  }

  if (outIdx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
    AMediaFormat *fmt = AMediaCodec_getOutputFormat(codec_);
    MUY_LOGI("Video output format changed");
    AMediaFormat_delete(fmt);
  }

  return false;
}

//------------------------------------------------------------------------------
// Audio render loop — self-contained: extracts, decodes, and plays audio.
// Having its own AMediaExtractor means it never blocks the video decode thread.
//------------------------------------------------------------------------------

void AndroidVideoDecoder::audioRenderLoop() {
  MUY_LOGI("Audio render thread started (%dHz %dch)", audioSampleRate_,
           audioChannelCount_);

  // All audio format state is determined from the first real output buffer.
  // The AAudio stream is opened there too, so it always uses the actual format.
  int32_t bytesPerSample = 2;
  bool outputFormatProbed = false;
  bool audioEosSent = false;
  // Scratch buffer for float→int16 conversion (grows once, never reallocates).
  std::vector<int16_t> convBuf;
  // Original container sample rate — kept to detect HE-AAC SBR upsampling.
  const int32_t containerSampleRate = audioSampleRate_;

  while (audioRunning_.load()) {
    if (seeking_.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
      continue;
    }

    bool didWork = false;

    // 1. Feed encoded audio from audioExtractor_ into audioCodec_ (non-blocking).
    //    Stop feeding once EOS has been signaled — sending a second EOS corrupts
    //    the codec state.
    if (audioExtractor_ && !audioEosSent) {
      ssize_t inIdx = AMediaCodec_dequeueInputBuffer(audioCodec_, 0);
      if (inIdx >= 0) {
        size_t inBufCap = 0;
        uint8_t *inBuf = AMediaCodec_getInputBuffer(
            audioCodec_, static_cast<size_t>(inIdx), &inBufCap);
        if (inBuf) {
          ssize_t sampleSize =
              AMediaExtractor_readSampleData(audioExtractor_, inBuf, inBufCap);
          if (sampleSize < 0) {
            AMediaCodec_queueInputBuffer(audioCodec_,
                                         static_cast<size_t>(inIdx), 0, 0, 0,
                                         AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
            audioEosSent = true;
            MUY_LOGI("Audio EOS signaled to codec");
          } else {
            int64_t pts = AMediaExtractor_getSampleTime(audioExtractor_);
            AMediaCodec_queueInputBuffer(
                audioCodec_, static_cast<size_t>(inIdx), 0,
                static_cast<size_t>(sampleSize),
                static_cast<uint64_t>(pts), 0);
            AMediaExtractor_advance(audioExtractor_);
            didWork = true;
          }
        }
      }
    }

    // 2. Dequeue decoded PCM from audioCodec_ (2ms timeout to avoid busy-spin).
    AMediaCodecBufferInfo info;
    ssize_t outIdx = AMediaCodec_dequeueOutputBuffer(audioCodec_, &info, 2000);

    if (outIdx >= 0) {
      // Codec config frames carry no PCM data — release immediately.
      if (info.flags & AMEDIACODEC_BUFFER_FLAG_CODEC_CONFIG) {
        AMediaCodec_releaseOutputBuffer(audioCodec_,
                                        static_cast<size_t>(outIdx), false);
      } else {
        // info.size is the actual decoded bytes; info.offset is the start within
        // the buffer. Use these — NOT the buffer capacity from getOutputBuffer.
        size_t outBufCap = 0;
        uint8_t *buf = AMediaCodec_getOutputBuffer(
            audioCodec_, static_cast<size_t>(outIdx), &outBufCap);

        if (buf && info.size > 0) {
          // ── Format probe (runs exactly once) ─────────────────────────────
          // The "pcm-encoding" key is absent on many devices even when the
          // codec outputs PCM_FLOAT, so we also infer encoding from info.size
          // relative to known AAC frame sizes (960 / 1024 / 2048 samples).
          // We also open the AAudio stream here so it always uses the correct
          // sample rate — critical for HE-AAC files where the codec upsamples.
          if (!outputFormatProbed) {
            outputFormatProbed = true;

            AMediaFormat *outFmt = AMediaCodec_getOutputFormat(audioCodec_);
            int32_t actualSr = audioSampleRate_;
            int32_t actualCh = audioChannelCount_;
            int32_t pcmEnc = 2;
            AMediaFormat_getInt32(outFmt, AMEDIAFORMAT_KEY_SAMPLE_RATE, &actualSr);
            AMediaFormat_getInt32(outFmt, AMEDIAFORMAT_KEY_CHANNEL_COUNT, &actualCh);
            AMediaFormat_getInt32(outFmt, "pcm-encoding", &pcmEnc);
            AMediaFormat_delete(outFmt);

            if (actualSr > 0) audioSampleRate_ = actualSr;
            if (actualCh > 0) audioChannelCount_ = actualCh;

            // Determine bytesPerSample. Prefer the explicit "pcm-encoding" key
            // (2=PCM_I16, 4=PCM_FLOAT). When absent, infer from info.size:
            //   expected bytes = samplesPerFrame * channels * bps
            // where samplesPerFrame is 960, 1024, or 2048 for AAC variants.
            if (pcmEnc == 4) {
              bytesPerSample = 4;
            } else if (pcmEnc == 2) {
              bytesPerSample = 2;
            } else {
              // Key absent — infer from buffer size.
              // Check which (samplesPerFrame, bps) pair cleanly divides info.size.
              bytesPerSample = 2; // default
              for (int spf : {1024, 960, 2048}) {
                if (audioChannelCount_ > 0 &&
                    static_cast<int32_t>(info.size) ==
                        spf * audioChannelCount_ * 4) {
                  // Only float matches this frame size — int16 would need half
                  // the bytes (i.e., spf/2 * ch * 2, which is a different spf).
                  // Guard: also check that int16 with same spf does NOT match.
                  if (static_cast<int32_t>(info.size) !=
                      spf * audioChannelCount_ * 2) {
                    bytesPerSample = 4;
                    break;
                  }
                }
              }
              // Ambiguous case (info.size consistent with both int16 at 2×spf
              // AND float at spf): use sample-rate doubling to decide.
              // HE-AAC SBR doubles the sample rate → int16 at 2×spf frames.
              // Same rate as container → more likely float at 1×spf frames.
              if (bytesPerSample == 2 && audioChannelCount_ > 0) {
                int32_t framesIfInt16 = static_cast<int32_t>(info.size) /
                                        (2 * audioChannelCount_);
                bool sbr = (audioSampleRate_ >= 2 * containerSampleRate &&
                            containerSampleRate > 0);
                // If no SBR upsampling and int16 gives a non-standard frame
                // count, assume float.
                if (!sbr && framesIfInt16 != 960 && framesIfInt16 != 1024) {
                  int32_t framesIfFloat = static_cast<int32_t>(info.size) /
                                          (4 * audioChannelCount_);
                  if (framesIfFloat == 960 || framesIfFloat == 1024 ||
                      framesIfFloat == 2048) {
                    bytesPerSample = 4;
                  }
                }
              }
            }

            MUY_LOGI("Audio output probed: %dHz %dch pcm-encoding=%d "
                     "bytes/sample=%d info.size=%zu",
                     audioSampleRate_, audioChannelCount_, pcmEnc,
                     bytesPerSample, static_cast<size_t>(info.size));

            // Open AAudio now that the actual format is known.
            if (!openAudioStream()) {
              MUY_LOGE("Failed to open AAudio stream — no audio");
              AMediaCodec_releaseOutputBuffer(
                  audioCodec_, static_cast<size_t>(outIdx), false);
              break;
            }
            if (AAudioStream_requestStart(audioStream_) != AAUDIO_OK) {
              MUY_LOGE("Failed to start AAudio stream — no audio");
              AAudioStream_close(audioStream_);
              audioStream_ = nullptr;
              AMediaCodec_releaseOutputBuffer(
                  audioCodec_, static_cast<size_t>(outIdx), false);
              break;
            }
          }

          if (audioStream_) {
            // ── A/V throttle ───────────────────────────────────────────────
            Timestamp audioPts =
                static_cast<Timestamp>(info.presentationTimeUs) * 1000;
            Timestamp anchor = startPts_.load();
            if (anchor >= 0) {
              int64_t renderTimeNs =
                  startSystemTimeNs_.load() + (audioPts - anchor);
              int64_t aheadNs = renderTimeNs - steadyClockNanos();
              constexpr int64_t kMaxAudioAheadNs = 200'000'000LL;
              if (aheadNs > kMaxAudioAheadNs) {
                MUY_LOGD("Audio throttle: sleeping %.2fms",
                         (aheadNs - kMaxAudioAheadNs) / 1.0e6);
                std::this_thread::sleep_for(
                    std::chrono::nanoseconds(aheadNs - kMaxAudioAheadNs));
              }
            }

            // ── Write PCM ──────────────────────────────────────────────────
            // numFrames derived from actual data size and probed format.
            int32_t numFrames = static_cast<int32_t>(info.size) /
                                (bytesPerSample * audioChannelCount_);
            if (numFrames > 0) {
              const void *writePtr = buf + info.offset;
              if (bytesPerSample == 4) {
                // Codec outputs float — convert to int16 for the PCM_I16
                // AAudio stream.
                const int numSamples = static_cast<int>(info.size) / 4;
                convBuf.resize(numSamples);
                const float *f =
                    reinterpret_cast<const float *>(buf + info.offset);
                for (int j = 0; j < numSamples; ++j) {
                  float s = f[j] < -1.f ? -1.f : (f[j] > 1.f ? 1.f : f[j]);
                  convBuf[j] = static_cast<int16_t>(s * 32767.f);
                }
                writePtr = convBuf.data();
              }
              aaudio_result_t r = AAudioStream_write(
                  audioStream_, writePtr, numFrames, 50'000'000LL);
              if (r < 0) {
                MUY_LOGW("AAudioStream_write: %s",
                         AAudio_convertResultToText(r));
              } else {
                MUY_LOGV("Audio: wrote %d/%d frames pts=%.3fms", r, numFrames,
                         audioPts / 1.0e6);
              }
            }
          }
          didWork = true;
        }

        AMediaCodec_releaseOutputBuffer(audioCodec_,
                                        static_cast<size_t>(outIdx), false);
      }

      // Stop the audio thread once the codec signals end-of-stream.
      if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
        MUY_LOGI("Audio codec EOS — render thread exiting");
        break;
      }

    } else if (outIdx == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
      MUY_LOGI("Audio output format changed (will probe on next buffer)");
    }

    if (!didWork) {
      std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
  }

  MUY_LOGI("Audio render thread exited");
}

} // namespace android
} // namespace muybridge
