#ifndef MUYBRIDGE_CLOCK_H
#define MUYBRIDGE_CLOCK_H

/**
 * @file Clock.h
 * @brief Master clock interface for A/V synchronization.
 *
 * Provides the timing foundation for video playback:
 * - IClock: Abstract interface for different clock sources
 * - AudioClock: Master clock driven by audio playback timestamps
 * - SystemClock: Fallback using monotonic system time
 *
 * Design Rationale:
 * Audio is the master clock because:
 * 1. Human perception is more sensitive to audio discontinuities
 * 2. Audio hardware provides regular, accurate timestamps
 * 3. Video can drop/repeat frames; audio cannot skip samples
 *
 * @note All timestamps are in nanoseconds for 120fps+ precision.
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>

namespace muybridge {

/**
 * @brief Nanosecond timestamp type.
 *
 * All media timestamps use nanoseconds for maximum precision.
 * This supports up to ~292 years of playback (int64_t range).
 */
using Timestamp = int64_t;

/// Invalid/unset timestamp sentinel value
constexpr Timestamp kInvalidTimestamp = INT64_MIN;

/// One second in nanoseconds
constexpr Timestamp kNanosPerSecond = 1'000'000'000LL;

/// One millisecond in nanoseconds
constexpr Timestamp kNanosPerMillis = 1'000'000LL;

/// One microsecond in nanoseconds
constexpr Timestamp kNanosPerMicro = 1'000LL;

/**
 * @class IClock
 * @brief Abstract clock interface for media synchronization.
 *
 * Implementations provide the "media time" - the current position
 * in the media stream that should be rendered. The render thread
 * queries this to decide which frame to display.
 *
 * Thread Safety: All methods must be thread-safe.
 */
class IClock {
public:
  virtual ~IClock() = default;

  /**
   * @brief Get the current media time.
   *
   * @return Current playback position in nanoseconds, or
   *         kInvalidTimestamp if the clock is not running.
   *
   * @note This must be fast (called every frame) and thread-safe.
   */
  virtual Timestamp now() const noexcept = 0;

  /**
   * @brief Check if the clock is currently running.
   * @return true if clock is active and now() returns valid timestamps
   */
  virtual bool isRunning() const noexcept = 0;

  /**
   * @brief Start/resume the clock.
   *
   * @param mediaTimeNanos Current media position to start from
   */
  virtual void start(Timestamp mediaTimeNanos) = 0;

  /**
   * @brief Pause the clock.
   *
   * After pause(), now() returns the last valid media time.
   */
  virtual void pause() = 0;

  /**
   * @brief Set playback speed.
   *
   * @param speed Playback rate (1.0 = normal, 2.0 = 2x speed, etc.)
   *
   * @note Negative speeds (reverse playback) are not supported.
   */
  virtual void setSpeed(float speed) = 0;

  /**
   * @brief Get current playback speed.
   * @return Current speed multiplier
   */
  virtual float getSpeed() const noexcept = 0;
};

/**
 * @class SystemClock
 * @brief Fallback clock using system monotonic time.
 *
 * Used when:
 * - No audio track is present
 * - Audio clock is unavailable
 * - During seeking (before audio resumes)
 *
 * Thread Safety: Fully thread-safe via atomic operations.
 */
class SystemClock final : public IClock {
public:
  SystemClock();
  ~SystemClock() override = default;

  // Non-copyable, non-movable (contains atomics)
  SystemClock(const SystemClock &) = delete;
  SystemClock &operator=(const SystemClock &) = delete;
  SystemClock(SystemClock &&) = delete;
  SystemClock &operator=(SystemClock &&) = delete;

  Timestamp now() const noexcept override;
  bool isRunning() const noexcept override;
  void start(Timestamp mediaTimeNanos) override;
  void pause() override;
  void setSpeed(float speed) override;
  float getSpeed() const noexcept override;

private:
  using SteadyClock = std::chrono::steady_clock;
  using TimePoint = SteadyClock::time_point;

  /// Is clock currently running?
  std::atomic<bool> running_{false};

  /// Playback speed multiplier
  std::atomic<float> speed_{1.0f};

  /// Media time at last start/pause
  std::atomic<Timestamp> baseMediaTime_{0};

  /// System time at last start
  std::atomic<int64_t> baseSystemTime_{0};

  /// Get current system time in nanoseconds
  static int64_t systemTimeNanos() noexcept;
};

/**
 * @class AudioClock
 * @brief Master clock driven by audio playback timestamps.
 *
 * The preferred clock source for A/V synchronization. Audio timestamps
 * are pushed from the audio decoder/renderer thread via update().
 *
 * How it works:
 * 1. Audio thread calls update() with current audio PTS
 * 2. Between updates, now() extrapolates using system time
 * 3. Provides smooth, audio-locked media time
 *
 * Thread Safety:
 * - update() called from audio thread
 * - now() called from render thread
 * - Both are thread-safe via mutex
 */
class AudioClock final : public IClock {
public:
  AudioClock();
  ~AudioClock() override = default;

  // Non-copyable, non-movable
  AudioClock(const AudioClock &) = delete;
  AudioClock &operator=(const AudioClock &) = delete;
  AudioClock(AudioClock &&) = delete;
  AudioClock &operator=(AudioClock &&) = delete;

  Timestamp now() const noexcept override;
  bool isRunning() const noexcept override;
  void start(Timestamp mediaTimeNanos) override;
  void pause() override;
  void setSpeed(float speed) override;
  float getSpeed() const noexcept override;

  /**
   * @brief Update the audio clock with latest audio timestamp.
   *
   * Called by the audio renderer when a new audio frame is played.
   *
   * @param audioPtsNanos Presentation timestamp of audio in nanoseconds
   * @param systemTimeNanos System time when audio was played
   *
   * @note Call this every ~20-50ms for smooth interpolation.
   */
  void update(Timestamp audioPtsNanos, Timestamp systemTimeNanos);

  /**
   * @brief Get time since last audio update.
   *
   * If this is too large (>100ms), the clock may need to switch
   * to system clock fallback.
   *
   * @return Nanoseconds since last update() call
   */
  Timestamp timeSinceLastUpdate() const noexcept;

private:
  /// Protects all mutable state
  mutable std::mutex mutex_;

  /// Is clock currently running?
  bool running_ = false;

  /// Playback speed multiplier
  float speed_ = 1.0f;

  /// Last audio PTS received
  Timestamp lastAudioPts_ = 0;

  /// System time when last audio PTS was received
  Timestamp lastUpdateSystemTime_ = 0;

  /// Media time when paused
  Timestamp pausedMediaTime_ = 0;

  /// Get current system time in nanoseconds
  static Timestamp systemTimeNanos() noexcept;
};

/**
 * @brief Factory function to create the appropriate clock.
 *
 * @param hasAudio Whether the media has an audio track
 * @return Unique pointer to clock implementation
 */
std::unique_ptr<IClock> createClock(bool hasAudio);

} // namespace muybridge

#endif // MUYBRIDGE_CLOCK_H
