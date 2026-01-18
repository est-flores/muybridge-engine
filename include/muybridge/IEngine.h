#ifndef MUYBRIDGE_IENGINE_H
#define MUYBRIDGE_IENGINE_H

/**
 * @file IEngine.h
 * @brief Pure virtual interface for the Muybridge video engine.
 */

#include "State.h"
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

namespace muybridge {

/**
 * @struct EngineConfig
 * @brief Configuration for engine initialization.
 */
struct EngineConfig {
  size_t decodeBufferCount = 4;
  bool enableLogging = true;
  int32_t targetTTFFMs = 200;
};

/**
 * @struct MediaInfo
 * @brief Information about loaded media.
 */
struct MediaInfo {
  int64_t durationNanos = 0;
  int32_t videoWidth = 0;
  int32_t videoHeight = 0;
  float frameRate = 0.0f;
  bool hasAudio = false;
  bool hasVideo = false;
  std::string containerFormat;
  std::string videoCodec;
  std::string audioCodec;
};

/**
 * @brief Callback for state changes.
 */
using StateCallback = std::function<void(State oldState, State newState)>;

/**
 * @brief Callback for errors.
 */
using ErrorCallback = std::function<void(int32_t code, std::string_view msg)>;

/**
 * @brief Callback for playback position updates.
 */
using PositionCallback = std::function<void(int64_t positionNanos)>;

/**
 * @class IEngine
 * @brief Pure virtual interface for video playback engine.
 */
class IEngine {
public:
  virtual ~IEngine() = default;

  /**
   * @brief Initialize the engine with configuration.
   * @return true on success
   */
  virtual bool initialize(const EngineConfig &config) = 0;

  /**
   * @brief Load media from URL.
   * @return true if load started successfully
   */
  virtual bool load(std::string_view url) = 0;

  /**
   * @brief Start playback.
   */
  virtual void play() = 0;

  /**
   * @brief Pause playback.
   */
  virtual void pause() = 0;

  /**
   * @brief Seek to position.
   * @param positionNanos Target position in nanoseconds
   */
  virtual void seek(int64_t positionNanos) = 0;

  /**
   * @brief Release all resources.
   */
  virtual void release() = 0;

  // --- State ---
  virtual State getState() const noexcept = 0;
  virtual int64_t getPosition() const noexcept = 0;
  virtual int64_t getDuration() const noexcept = 0;
  virtual const MediaInfo &getMediaInfo() const noexcept = 0;

  // --- Callbacks ---
  virtual void setStateCallback(StateCallback callback) = 0;
  virtual void setErrorCallback(ErrorCallback callback) = 0;
  virtual void setPositionCallback(PositionCallback callback) = 0;

  // --- Playback Control ---
  virtual void setSpeed(float speed) = 0;
  virtual float getSpeed() const noexcept = 0;
  virtual void setVolume(float volume) = 0;
  virtual float getVolume() const noexcept = 0;
};

/**
 * @brief Create engine instance (platform-specific).
 */
std::unique_ptr<IEngine> createEngine();

} // namespace muybridge

#endif // MUYBRIDGE_IENGINE_H
