#ifndef MUYBRIDGE_ANDROID_VIDEO_DECODER_H
#define MUYBRIDGE_ANDROID_VIDEO_DECODER_H

#include "muybridge/Clock.h"
#include "muybridge/IEngine.h"
#include "muybridge/Log.h"

#include <android/native_window.h>
#include <aaudio/AAudio.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace muybridge {
namespace android {

using FrameCallback = std::function<void(Timestamp pts)>;
using MediaInfoCallback = std::function<void(const MediaInfo &)>;

class AndroidVideoDecoder {
public:
  AndroidVideoDecoder();
  ~AndroidVideoDecoder();

  AndroidVideoDecoder(const AndroidVideoDecoder &) = delete;
  AndroidVideoDecoder &operator=(const AndroidVideoDecoder &) = delete;

  void setSurface(ANativeWindow *window);
  bool open(const std::string &url);
  void start();
  void stop();
  void seek(Timestamp positionNanos);
  void release();

  const MediaInfo &getMediaInfo() const { return mediaInfo_; }
  void setFrameCallback(FrameCallback callback);
  void setMediaInfoCallback(MediaInfoCallback callback);
  bool isEndOfStream() const { return endOfStream_.load(); }

private:
  // Video decode thread
  void decodeLoop();
  bool extractSample();
  bool processOutput();
  int findVideoTrack();
  bool configureCodec(AMediaFormat *format);

  // Audio render thread
  void audioRenderLoop();
  int findAudioTrack();
  bool configureAudioCodec(AMediaFormat *format);
  bool openAudioStream();

  static int64_t steadyClockNanos() noexcept;

  // Shared state
  std::atomic<bool> running_{false};
  std::atomic<bool> endOfStream_{false};
  std::atomic<bool> seeking_{false};

  // Frame-pacing timing anchor (captured on first decoded frame)
  std::atomic<int64_t> startSystemTimeNs_{0};
  std::atomic<Timestamp> startPts_{-1};

  // Media components
  AMediaExtractor *extractor_ = nullptr;       // video-only extractor
  AMediaExtractor *audioExtractor_ = nullptr;  // audio-only extractor
  AMediaCodec *codec_ = nullptr;       // video codec
  AMediaCodec *audioCodec_ = nullptr;  // audio codec
  ANativeWindow *surface_ = nullptr;

  // Audio output
  AAudioStream *audioStream_ = nullptr;
  std::atomic<bool> audioRunning_{false};
  int32_t audioSampleRate_ = 44100;
  int32_t audioChannelCount_ = 2;

  // Media info
  MediaInfo mediaInfo_;
  int videoTrackIndex_ = -1;
  int audioTrackIndex_ = -1;

  // Threading
  std::thread decodeThread_;
  std::thread audioRenderThread_;
  std::mutex mutex_;

  // Callbacks
  FrameCallback frameCallback_;
  MediaInfoCallback mediaInfoCallback_;
};

} // namespace android
} // namespace muybridge

#endif // MUYBRIDGE_ANDROID_VIDEO_DECODER_H
