#include "muybridge/AVSync.h"
#include <algorithm>

namespace muybridge {

AVSync::AVSync()
    : tolerance_(kSyncToleranceNanos), maxWait_(kMaxWaitNanos),
      maxLateness_(kMaxLatenessNanos) {}

AVSync::AVSync(Timestamp toleranceNanos, Timestamp maxWaitNanos,
               Timestamp maxLatenessNanos)
    : tolerance_(toleranceNanos), maxWait_(maxWaitNanos),
      maxLateness_(maxLatenessNanos) {}

SyncResult AVSync::calculate(Timestamp framePtsNanos,
                             Timestamp clockNowNanos) const noexcept {
  SyncResult result;
  result.driftNanos = framePtsNanos - clockNowNanos;

  Timestamp tol = tolerance_.load(std::memory_order_relaxed);
  Timestamp maxW = maxWait_.load(std::memory_order_relaxed);
  Timestamp maxL = maxLateness_.load(std::memory_order_relaxed);

  if (result.driftNanos >= -tol && result.driftNanos <= tol) {
    result.action = SyncAction::Present;
  } else if (result.driftNanos > tol) {
    if (result.driftNanos <= maxW) {
      result.action = SyncAction::Wait;
      result.waitNanos = result.driftNanos;
    } else {
      result.action = SyncAction::Wait;
      result.waitNanos = maxW;
    }
  } else {
    if (-result.driftNanos > maxL) {
      result.action = SyncAction::Drop;
    } else {
      result.action = SyncAction::Present;
    }
  }

  return result;
}

SyncResult AVSync::noFrameAvailable() const noexcept {
  SyncResult result;
  result.action = SyncAction::Repeat;
  result.waitNanos = 0;
  result.driftNanos = 0;
  return result;
}

void AVSync::recordPresent() noexcept {
  presentCount_.fetch_add(1, std::memory_order_relaxed);
}

void AVSync::recordDrop() noexcept {
  dropCount_.fetch_add(1, std::memory_order_relaxed);
}

void AVSync::recordRepeat() noexcept {
  repeatCount_.fetch_add(1, std::memory_order_relaxed);
}

uint64_t AVSync::getPresentCount() const noexcept {
  return presentCount_.load(std::memory_order_relaxed);
}

uint64_t AVSync::getDropCount() const noexcept {
  return dropCount_.load(std::memory_order_relaxed);
}

uint64_t AVSync::getRepeatCount() const noexcept {
  return repeatCount_.load(std::memory_order_relaxed);
}

void AVSync::resetStats() noexcept {
  presentCount_.store(0, std::memory_order_relaxed);
  dropCount_.store(0, std::memory_order_relaxed);
  repeatCount_.store(0, std::memory_order_relaxed);
}

void AVSync::setTolerance(Timestamp toleranceNanos) noexcept {
  tolerance_.store(toleranceNanos, std::memory_order_relaxed);
}

Timestamp AVSync::getTolerance() const noexcept {
  return tolerance_.load(std::memory_order_relaxed);
}

} // namespace muybridge
