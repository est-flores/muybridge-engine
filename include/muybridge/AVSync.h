#ifndef MUYBRIDGE_AVSYNC_H
#define MUYBRIDGE_AVSYNC_H

/**
 * @file AVSync.h
 * @brief Audio-Video synchronization calculator.
 *
 * Determines what action to take when presenting video frames:
 * - Present: Show frame now
 * - Wait: Frame is early, wait before presenting
 * - Drop: Frame is late, skip it
 * - Repeat: Next frame not ready, show current again
 *
 * Synchronization follows the "audio is master" principle with
 * a ±16ms tolerance window (1 frame at 60fps).
 *
 * @note All time values are in nanoseconds for precision.
 */

#include "Clock.h"
#include <atomic>
#include <cstdint>

namespace muybridge {

/**
 * @brief A/V sync tolerance in nanoseconds.
 *
 * Frames within this window are considered "in sync".
 * 16ms = 1 frame at 60fps, which is imperceptible.
 */
constexpr Timestamp kSyncToleranceNanos = 16 * kNanosPerMillis;

/**
 * @brief Maximum wait time before giving up on early frame.
 *
 * If we'd need to wait longer than this, something is wrong.
 */
constexpr Timestamp kMaxWaitNanos = 100 * kNanosPerMillis;

/**
 * @brief Maximum lateness before dropping a frame.
 *
 * Frames older than this are definitely dropped.
 */
constexpr Timestamp kMaxLatenessNanos = 100 * kNanosPerMillis;

/**
 * @enum SyncAction
 * @brief Recommended action for a video frame.
 */
enum class SyncAction : uint8_t {
  /**
   * @brief Present the frame immediately.
   *
   * Frame PTS is within tolerance of current media time.
   */
  Present,

  /**
   * @brief Wait before presenting.
   *
   * Frame PTS is ahead of current media time.
   * Use getWaitTimeNanos() to get wait duration.
   */
  Wait,

  /**
   * @brief Drop this frame.
   *
   * Frame PTS is too far behind current media time.
   * Request the next frame from decoder.
   */
  Drop,

  /**
   * @brief Repeat the previous frame.
   *
   * No frame available yet for current time.
   * This prevents showing stale or blank content.
   */
  Repeat
};

/**
 * @brief Convert SyncAction to string for logging.
 */
constexpr const char *syncActionToString(SyncAction action) noexcept {
  switch (action) {
  case SyncAction::Present:
    return "Present";
  case SyncAction::Wait:
    return "Wait";
  case SyncAction::Drop:
    return "Drop";
  case SyncAction::Repeat:
    return "Repeat";
  default:
    return "Unknown";
  }
}

/**
 * @struct SyncResult
 * @brief Result of A/V sync calculation.
 */
struct SyncResult {
  /// Recommended action
  SyncAction action = SyncAction::Present;

  /// Wait time in nanoseconds (valid when action == Wait)
  Timestamp waitNanos = 0;

  /// Difference between frame PTS and clock (positive = early, negative = late)
  Timestamp driftNanos = 0;
};

/**
 * @class AVSync
 * @brief Manages audio-video synchronization decisions.
 *
 * Usage:
 * @code
 * AVSync sync;
 *
 * // In render loop:
 * Timestamp framePts = decoder.getNextFramePts();
 * Timestamp now = clock.now();
 * SyncResult result = sync.calculate(framePts, now);
 *
 * switch (result.action) {
 *     case SyncAction::Present:
 *         renderer.present(frame);
 *         break;
 *     case SyncAction::Wait:
 *         std::this_thread::sleep_for(
 *             std::chrono::nanoseconds(result.waitNanos));
 *         renderer.present(frame);
 *         break;
 *     case SyncAction::Drop:
 *         // Skip this frame, get next
 *         break;
 *     case SyncAction::Repeat:
 *         // Show previous frame again
 *         break;
 * }
 * @endcode
 *
 * Thread Safety: Fully thread-safe.
 */
class AVSync {
public:
  /**
   * @brief Create AVSync with default tolerances.
   */
  AVSync();

  /**
   * @brief Create AVSync with custom tolerances.
   *
   * @param toleranceNanos A/V sync tolerance window
   * @param maxWaitNanos Maximum time to wait for early frame
   * @param maxLatenessNanos Maximum lateness before dropping
   */
  AVSync(Timestamp toleranceNanos, Timestamp maxWaitNanos,
         Timestamp maxLatenessNanos);

  ~AVSync() = default;

  /**
   * @brief Calculate sync action for a video frame.
   *
   * @param framePtsNanos Frame presentation timestamp
   * @param clockNowNanos Current media clock time
   * @return SyncResult with action and timing info
   */
  SyncResult calculate(Timestamp framePtsNanos,
                       Timestamp clockNowNanos) const noexcept;

  /**
   * @brief Calculate action when no frame is available.
   *
   * Called when decoder queue is empty.
   *
   * @return SyncResult with Repeat action
   */
  SyncResult noFrameAvailable() const noexcept;

  // --- Statistics ---

  /**
   * @brief Record that a frame was presented.
   */
  void recordPresent() noexcept;

  /**
   * @brief Record that a frame was dropped.
   */
  void recordDrop() noexcept;

  /**
   * @brief Record that a frame was repeated.
   */
  void recordRepeat() noexcept;

  /**
   * @brief Get number of presented frames.
   */
  uint64_t getPresentCount() const noexcept;

  /**
   * @brief Get number of dropped frames.
   */
  uint64_t getDropCount() const noexcept;

  /**
   * @brief Get number of repeated frames.
   */
  uint64_t getRepeatCount() const noexcept;

  /**
   * @brief Reset all statistics.
   */
  void resetStats() noexcept;

  // --- Configuration ---

  /**
   * @brief Set A/V sync tolerance.
   * @param toleranceNanos New tolerance in nanoseconds
   */
  void setTolerance(Timestamp toleranceNanos) noexcept;

  /**
   * @brief Get current A/V sync tolerance.
   */
  Timestamp getTolerance() const noexcept;

private:
  /// Sync tolerance (frames within this window are "in sync")
  std::atomic<Timestamp> tolerance_{kSyncToleranceNanos};

  /// Maximum time to wait for early frame
  std::atomic<Timestamp> maxWait_{kMaxWaitNanos};

  /// Maximum lateness before dropping
  std::atomic<Timestamp> maxLateness_{kMaxLatenessNanos};

  // Statistics (atomic for thread safety)
  std::atomic<uint64_t> presentCount_{0};
  std::atomic<uint64_t> dropCount_{0};
  std::atomic<uint64_t> repeatCount_{0};
};

} // namespace muybridge

#endif // MUYBRIDGE_AVSYNC_H
