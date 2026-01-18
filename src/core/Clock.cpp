#include "muybridge/Clock.h"

namespace muybridge {

//------------------------------------------------------------------------------
// SystemClock Implementation
//------------------------------------------------------------------------------

SystemClock::SystemClock() = default;

int64_t SystemClock::systemTimeNanos() noexcept {
  auto now = SteadyClock::now();
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             now.time_since_epoch())
      .count();
}

Timestamp SystemClock::now() const noexcept {
  if (!running_.load(std::memory_order_acquire)) {
    return baseMediaTime_.load(std::memory_order_relaxed);
  }

  int64_t elapsed =
      systemTimeNanos() - baseSystemTime_.load(std::memory_order_relaxed);
  float speed = speed_.load(std::memory_order_relaxed);
  Timestamp delta =
      static_cast<Timestamp>(static_cast<double>(elapsed) * speed);

  return baseMediaTime_.load(std::memory_order_relaxed) + delta;
}

bool SystemClock::isRunning() const noexcept {
  return running_.load(std::memory_order_acquire);
}

void SystemClock::start(Timestamp mediaTimeNanos) {
  baseMediaTime_.store(mediaTimeNanos, std::memory_order_relaxed);
  baseSystemTime_.store(systemTimeNanos(), std::memory_order_relaxed);
  running_.store(true, std::memory_order_release);
}

void SystemClock::pause() {
  if (running_.load(std::memory_order_acquire)) {
    baseMediaTime_.store(now(), std::memory_order_relaxed);
    running_.store(false, std::memory_order_release);
  }
}

void SystemClock::setSpeed(float speed) {
  if (running_.load(std::memory_order_acquire)) {
    Timestamp current = now();
    baseMediaTime_.store(current, std::memory_order_relaxed);
    baseSystemTime_.store(systemTimeNanos(), std::memory_order_relaxed);
  }
  speed_.store(speed, std::memory_order_release);
}

float SystemClock::getSpeed() const noexcept {
  return speed_.load(std::memory_order_relaxed);
}

//------------------------------------------------------------------------------
// AudioClock Implementation
//------------------------------------------------------------------------------

AudioClock::AudioClock() = default;

Timestamp AudioClock::systemTimeNanos() noexcept {
  auto now = std::chrono::steady_clock::now();
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             now.time_since_epoch())
      .count();
}

Timestamp AudioClock::now() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);

  if (!running_) {
    return pausedMediaTime_;
  }

  Timestamp sysNow = systemTimeNanos();
  Timestamp elapsed = sysNow - lastUpdateSystemTime_;
  Timestamp delta =
      static_cast<Timestamp>(static_cast<double>(elapsed) * speed_);

  return lastAudioPts_ + delta;
}

bool AudioClock::isRunning() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return running_;
}

void AudioClock::start(Timestamp mediaTimeNanos) {
  std::lock_guard<std::mutex> lock(mutex_);
  lastAudioPts_ = mediaTimeNanos;
  lastUpdateSystemTime_ = systemTimeNanos();
  running_ = true;
}

void AudioClock::pause() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_) {
    pausedMediaTime_ =
        lastAudioPts_ +
        static_cast<Timestamp>((systemTimeNanos() - lastUpdateSystemTime_) *
                               speed_);
    running_ = false;
  }
}

void AudioClock::setSpeed(float speed) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_) {
    Timestamp sysNow = systemTimeNanos();
    lastAudioPts_ +=
        static_cast<Timestamp>((sysNow - lastUpdateSystemTime_) * speed_);
    lastUpdateSystemTime_ = sysNow;
  }
  speed_ = speed;
}

float AudioClock::getSpeed() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return speed_;
}

void AudioClock::update(Timestamp audioPtsNanos, Timestamp systemTimeNanos) {
  std::lock_guard<std::mutex> lock(mutex_);
  lastAudioPts_ = audioPtsNanos;
  lastUpdateSystemTime_ = systemTimeNanos;
}

Timestamp AudioClock::timeSinceLastUpdate() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return systemTimeNanos() - lastUpdateSystemTime_;
}

//------------------------------------------------------------------------------
// Factory
//------------------------------------------------------------------------------

std::unique_ptr<IClock> createClock(bool hasAudio) {
  if (hasAudio) {
    return std::make_unique<AudioClock>();
  }
  return std::make_unique<SystemClock>();
}

} // namespace muybridge
