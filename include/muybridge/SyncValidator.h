#ifndef MUYBRIDGE_SYNC_VALIDATOR_H
#define MUYBRIDGE_SYNC_VALIDATOR_H

/**
 * @file SyncValidator.h
 * @brief A/V synchronization validation and reporting.
 */

#include "muybridge/Clock.h"
#include "muybridge/Log.h"

#include <atomic>
#include <cmath>
#include <mutex>

namespace muybridge {

/**
 * @struct SyncStats
 * @brief A/V sync statistics.
 */
struct SyncStats {
  int64_t sampleCount = 0;
  double meanDriftMs = 0;
  double maxDriftMs = 0;
  double minDriftMs = 0;
  int64_t outOfSyncCount = 0; // Samples exceeding tolerance
};

/**
 * @class SyncValidator
 * @brief Validates A/V synchronization is within tolerance.
 *
 * Usage:
 * @code
 * SyncValidator validator;
 *
 * // In render loop:
 * validator.recordSample(videoPts, audioClock.now());
 *
 * // After playback:
 * validator.logReport();
 * @endcode
 */
class SyncValidator {
public:
  /**
   * @brief Create validator with tolerance.
   * @param toleranceMs A/V sync tolerance in milliseconds
   */
  explicit SyncValidator(double toleranceMs = 16.0)
      : toleranceMs_(toleranceMs) {}

  /**
   * @brief Reset all statistics.
   */
  void reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    sampleCount_ = 0;
    sumDrift_ = 0;
    maxDrift_ = 0;
    minDrift_ = 0;
    outOfSyncCount_ = 0;
  }

  /**
   * @brief Record an A/V sync sample.
   * @param videoPtsNanos Video frame PTS
   * @param audioClockNanos Current audio clock time
   */
  void recordSample(Timestamp videoPtsNanos, Timestamp audioClockNanos) {
    double driftMs =
        static_cast<double>(videoPtsNanos - audioClockNanos) / 1'000'000.0;

    std::lock_guard<std::mutex> lock(mutex_);

    sampleCount_++;
    sumDrift_ += driftMs;

    if (sampleCount_ == 1) {
      maxDrift_ = driftMs;
      minDrift_ = driftMs;
    } else {
      maxDrift_ = std::max(maxDrift_, driftMs);
      minDrift_ = std::min(minDrift_, driftMs);
    }

    if (std::abs(driftMs) > toleranceMs_) {
      outOfSyncCount_++;
      MUY_LOGW("[SYNC] Out of sync: %.1fms (tolerance: ±%.1fms)", driftMs,
               toleranceMs_);
    }
  }

  /**
   * @brief Get current statistics.
   */
  SyncStats getStats() const {
    std::lock_guard<std::mutex> lock(mutex_);

    SyncStats stats;
    stats.sampleCount = sampleCount_;
    stats.meanDriftMs = sampleCount_ > 0 ? sumDrift_ / sampleCount_ : 0;
    stats.maxDriftMs = maxDrift_;
    stats.minDriftMs = minDrift_;
    stats.outOfSyncCount = outOfSyncCount_;
    return stats;
  }

  /**
   * @brief Check if sync is within tolerance.
   */
  bool isInSync() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sampleCount_ == 0)
      return true;
    return outOfSyncCount_ == 0;
  }

  /**
   * @brief Get percentage of samples in sync.
   */
  double getSyncPercentage() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (sampleCount_ == 0)
      return 100.0;
    return 100.0 * (1.0 - static_cast<double>(outOfSyncCount_) / sampleCount_);
  }

  /**
   * @brief Log sync validation report.
   */
  void logReport() const {
    auto stats = getStats();
    double syncPct = getSyncPercentage();

    MUY_LOGI("=== A/V Sync Validation Report ===");
    MUY_LOGI("  Samples:       %lld", stats.sampleCount);
    MUY_LOGI("  Mean Drift:    %.2fms", stats.meanDriftMs);
    MUY_LOGI("  Max Drift:     %.2fms", stats.maxDriftMs);
    MUY_LOGI("  Min Drift:     %.2fms", stats.minDriftMs);
    MUY_LOGI("  Tolerance:     ±%.1fms", toleranceMs_);
    MUY_LOGI("  Out of Sync:   %lld (%.1f%%)", stats.outOfSyncCount,
             100.0 - syncPct);
    MUY_LOGI("  Sync Quality:  %.1f%% %s", syncPct,
             syncPct >= 99.0 ? "✓" : "✗");
    MUY_LOGI("==================================");
  }

private:
  mutable std::mutex mutex_;
  double toleranceMs_;
  int64_t sampleCount_ = 0;
  double sumDrift_ = 0;
  double maxDrift_ = 0;
  double minDrift_ = 0;
  int64_t outOfSyncCount_ = 0;
};

} // namespace muybridge

#endif // MUYBRIDGE_SYNC_VALIDATOR_H
