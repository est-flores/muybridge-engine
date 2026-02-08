#ifndef MUYBRIDGE_IOS_VIDEO_DECODER_H
#define MUYBRIDGE_IOS_VIDEO_DECODER_H

/**
 * @file IOSVideoDecoder.h
 * @brief Hardware video decoder using iOS VideoToolbox.
 */

#include "muybridge/Clock.h"
#include "muybridge/IEngine.h"
#include "muybridge/Log.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <queue>
#include <string>

namespace muybridge {
namespace ios {

/**
 * @brief Callback when a frame is available.
 * @param pixelBuffer CVPixelBuffer containing decoded frame
 * @param pts Presentation timestamp in nanoseconds
 */
using FrameCallback =
    std::function<void(CVPixelBufferRef pixelBuffer, Timestamp pts)>;

/**
 * @brief Callback when media info is available.
 */
using MediaInfoCallback = std::function<void(const MediaInfo &)>;

/**
 * @class IOSVideoDecoder
 * @brief Hardware decoder using VideoToolbox.
 */
class IOSVideoDecoder {
public:
  IOSVideoDecoder();
  ~IOSVideoDecoder();

  // Non-copyable
  IOSVideoDecoder(const IOSVideoDecoder &) = delete;
  IOSVideoDecoder &operator=(const IOSVideoDecoder &) = delete;

  /**
   * @brief Open media file.
   */
  bool open(const std::string &url);

  /**
   * @brief Start decoding.
   */
  void start();

  /**
   * @brief Stop decoding.
   */
  void stop();

  /**
   * @brief Seek to position.
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
  bool openWithAVPlayer(NSURL *url);      // For network URLs
  bool openWithAssetReader(NSURL *url);   // For local files
  void decodeLoop();
  void playerDecodeLoop();  // For AVPlayer-based decoding
  bool configureDecode();

  // VideoToolbox callback
  static void decompressionCallback(void *decompressionOutputRefCon,
                                    void *sourceFrameRefCon, OSStatus status,
                                    VTDecodeInfoFlags infoFlags,
                                    CVImageBufferRef imageBuffer,
                                    CMTime presentationTimeStamp,
                                    CMTime presentationDuration);

  // State
  std::atomic<bool> running_{false};
  std::atomic<bool> endOfStream_{false};
  bool useAVPlayer_{false};  // True for network URLs

  // AVFoundation objects (bridged)
  void *asset_;       // AVAsset* or AVURLAsset*
  void *assetReader_; // AVAssetReader* (for local files)
  void *videoOutput_; // AVAssetReaderTrackOutput* (for local files)
  
  // AVPlayer-based (for network URLs)
  void *player_;           // AVPlayer*
  void *playerItem_;       // AVPlayerItem*
  void *playerVideoOutput_; // AVPlayerItemVideoOutput*
  void *playerReadyObserver_; // KVO observer token

  // VideoToolbox
  VTDecompressionSessionRef decompressionSession_;
  CMVideoFormatDescriptionRef formatDescription_;

  // Media info
  MediaInfo mediaInfo_;

  // Threading
  std::mutex mutex_;
  dispatch_queue_t decodeQueue_;

  // Callbacks
  FrameCallback frameCallback_;
  MediaInfoCallback mediaInfoCallback_;
};

} // namespace ios
} // namespace muybridge

#endif // MUYBRIDGE_IOS_VIDEO_DECODER_H
