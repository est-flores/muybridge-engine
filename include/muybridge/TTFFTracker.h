#ifndef MUYBRIDGE_TTFF_TRACKER_H
#define MUYBRIDGE_TTFF_TRACKER_H

/**
 * @file TTFFTracker.h
 * @brief Time-to-First-Frame measurement and reporting.
 */

#include "muybridge/Clock.h"
#include "muybridge/Log.h"

#include <mutex>
#include <string>
#include <vector>

namespace muybridge {

/**
 * @struct TTFFMilestone
 * @brief A single milestone in the TTFF breakdown.
 */
struct TTFFMilestone {
  std::string name;
  Timestamp timestamp;
  Timestamp delta; // Time since previous milestone
};

/**
 * @class TTFFTracker
 * @brief Tracks and reports TTFF milestones.
 *
 * Usage:
 * @code
 * TTFFTracker tracker;
 * tracker.start();
 * tracker.mark("demuxer_init");
 * tracker.mark("decoder_config");
 * tracker.mark("first_frame_decoded");
 * tracker.mark("first_frame_rendered");
 * tracker.stop();
 * tracker.logReport();
 * @endcode
 */
class TTFFTracker {
public:
  TTFFTracker() = default;

  /**
   * @brief Start tracking (resets all milestones).
   */
  void start() {
    std::lock_guard<std::mutex> lock(mutex_);
    milestones_.clear();
    startTime_ = log::Clock::now();

    TTFFMilestone milestone;
    milestone.name = "start";
    milestone.timestamp = 0;
    milestone.delta = 0;
    milestones_.push_back(milestone);
  }

  /**
   * @brief Mark a milestone.
   * @param name Milestone name
   */
  void mark(const std::string &name) {
    std::lock_guard<std::mutex> lock(mutex_);

    auto now = log::Clock::now();
    Timestamp ts =
        std::chrono::duration_cast<std::chrono::nanoseconds>(now - startTime_)
            .count();

    TTFFMilestone milestone;
    milestone.name = name;
    milestone.timestamp = ts;
    milestone.delta =
        milestones_.empty() ? 0 : ts - milestones_.back().timestamp;

    milestones_.push_back(milestone);

    MUY_TTFF_MILESTONE(name.c_str());
  }

  /**
   * @brief Stop tracking and mark final milestone.
   */
  void stop() { mark("complete"); }

  /**
   * @brief Get total TTFF in milliseconds.
   */
  double getTTFFMs() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (milestones_.size() < 2)
      return 0;
    return static_cast<double>(milestones_.back().timestamp) / 1'000'000.0;
  }

  /**
   * @brief Check if TTFF target was met.
   * @param targetMs Target TTFF in milliseconds
   */
  bool targetMet(double targetMs = 200.0) const {
    return getTTFFMs() < targetMs;
  }

  /**
   * @brief Log a detailed breakdown report.
   */
  void logReport() const {
    std::lock_guard<std::mutex> lock(mutex_);

    MUY_LOGI("=== TTFF Breakdown Report ===");

    for (size_t i = 0; i < milestones_.size(); ++i) {
      const auto &m = milestones_[i];
      double tsMs = static_cast<double>(m.timestamp) / 1'000'000.0;
      double deltaMs = static_cast<double>(m.delta) / 1'000'000.0;

      if (i == 0) {
        MUY_LOGI("  [%6.1fms] %s", tsMs, m.name.c_str());
      } else {
        MUY_LOGI("  [%6.1fms] %s (+%.1fms)", tsMs, m.name.c_str(), deltaMs);
      }
    }

    double total = getTTFFMs();
    MUY_LOGI("  ─────────────────────");
    MUY_LOGI("  Total TTFF: %.1fms %s", total, targetMet() ? "✓" : "✗");
    MUY_LOGI("=============================");
  }

  /**
   * @brief Get all milestones.
   */
  const std::vector<TTFFMilestone> &getMilestones() const {
    return milestones_;
  }

private:
  mutable std::mutex mutex_;
  log::TimePoint startTime_;
  std::vector<TTFFMilestone> milestones_;
};

} // namespace muybridge

#endif // MUYBRIDGE_TTFF_TRACKER_H
