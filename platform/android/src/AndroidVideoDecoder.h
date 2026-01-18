#ifndef MUYBRIDGE_ANDROID_VIDEO_DECODER_H
#define MUYBRIDGE_ANDROID_VIDEO_DECODER_H

/**
 * @file AndroidVideoDecoder.h
 * @brief Hardware video decoder using Android MediaCodec NDK.
 */

#include "muybridge/Clock.h"
#include "muybridge/IEngine.h"
#include "muybridge/Log.h"

#include <android/native_window.h>
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

/**
 * @brief Callback when a frame is available for rendering.
 * @param pts Presentation timestamp in nanoseconds
 */
using FrameCallback = std::function<void(Timestamp pts)>;

/**
 * @brief Callback when media info is available.
 */
using MediaInfoCallback = std::function<void(const MediaInfo &)>;

/**
 * @class AndroidVideoDecoder
 * @brief Hardware decoder wrapper for AMediaCodec.
 *
 * Features:
 * - Zero-copy output to ANativeWindow (SurfaceTexture)
 * - Async decode with callback-based frame notification
 * - Automatic codec selection for hardware acceleration
 */
class AndroidVideoDecoder {
public:
  AndroidVideoDecoder();
  ~AndroidVideoDecoder();

  // Non-copyable
  AndroidVideoDecoder(const AndroidVideoDecoder &) = delete;
  AndroidVideoDecoder &operator=(const AndroidVideoDecoder &) = delete;

  /**
   * @brief Set the output surface for decoded frames.
   * @param window ANativeWindow from SurfaceTexture
   */
  void setSurface(ANativeWindow *window);

  /**
   * @brief Open media file and configure decoder.
   * @param url File path or URL
   * @return true on success
   */
  bool open(const std::string &url);

  /**
   * @brief Start decoding.
   */
  void start();

  /**
   * @brief Stop decoding and flush.
   */
  void stop();

  /**
   * @brief Seek to position.
   * @param positionNanos Target position in nanoseconds
   */
  void seek(Timestamp positionNanos);

  /**
   * @brief Release all resources.
   */
  void release();

  /**
   * @brief Get media information.
   */
  const MediaInfo &getMediaInfo() const { return mediaInfo_; }

  /**
   * @brief Set callback for frame available.
   */
  void setFrameCallback(FrameCallback callback);

  /**
   * @brief Set callback for media info ready.
   */
  void setMediaInfoCallback(MediaInfoCallback callback);

  /**
   * @brief Check if end of stream reached.
   */
  bool isEndOfStream() const { return endOfStream_.load(); }

private:
  // Decode thread function
  void decodeLoop();

  // Extract next sample from container
  bool extractSample();

  // Process decoder output
  bool processOutput();

  // Find video track in container
  int findVideoTrack();

  // Configure codec from format
  bool configureCodec(AMediaFormat *format);

  // State
  std::atomic<bool> running_{false};
  std::atomic<bool> endOfStream_{false};
  std::atomic<bool> seeking_{false};

  // Media components
  AMediaExtractor *extractor_ = nullptr;
  AMediaCodec *codec_ = nullptr;
  ANativeWindow *surface_ = nullptr;

  // Media info
  MediaInfo mediaInfo_;
  int videoTrackIndex_ = -1;

  // Threading
  std::thread decodeThread_;
  std::mutex mutex_;

  // Callbacks
  FrameCallback frameCallback_;
  MediaInfoCallback mediaInfoCallback_;
};

} // namespace android
} // namespace muybridge

#endif // MUYBRIDGE_ANDROID_VIDEO_DECODER_H
