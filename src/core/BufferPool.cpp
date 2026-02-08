#include "muybridge/BufferPool.h"
#include <algorithm>
#include <cstring>

namespace muybridge {

//------------------------------------------------------------------------------
// Buffer Implementation
//------------------------------------------------------------------------------

Buffer::Buffer(uint8_t *data, const size_t capacity, const int32_t index, BufferPool *pool)
    : data_(data), capacity_(capacity), size_(0), index_(index), pool_(pool) {}

Buffer::~Buffer() {
  if (pool_ && index_ >= 0) {
    pool_->returnBuffer(index_);
  }
}

Buffer::Buffer(Buffer &&other) noexcept
    : data_(other.data_), capacity_(other.capacity_), size_(other.size_),
      index_(other.index_), pool_(other.pool_) {
  other.data_ = nullptr;
  other.capacity_ = 0;
  other.size_ = 0;
  other.index_ = -1;
  other.pool_ = nullptr;
}

Buffer &Buffer::operator=(Buffer &&other) noexcept {
  if (this != &other) {
    if (pool_ && index_ >= 0) {
      pool_->returnBuffer(index_);
    }
    data_ = other.data_;
    capacity_ = other.capacity_;
    size_ = other.size_;
    index_ = other.index_;
    pool_ = other.pool_;
    other.data_ = nullptr;
    other.capacity_ = 0;
    other.size_ = 0;
    other.index_ = -1;
    other.pool_ = nullptr;
  }
  return *this;
}

void Buffer::setSize(size_t size) noexcept {
  size_ = std::min(size, capacity_);
}

//------------------------------------------------------------------------------
// BufferPool Implementation
//------------------------------------------------------------------------------

BufferPool::BufferPool() : BufferPool(BufferPoolConfig{}) {}

BufferPool::BufferPool(const BufferPoolConfig &config)
    : name_(config.name), bufferSize_(config.bufferSize),
      bufferCount_(config.bufferCount) {
  memory_ = std::make_unique<uint8_t[]>(bufferSize_ * bufferCount_);
  freeList_.reserve(bufferCount_);
  for (size_t i = 0; i < bufferCount_; ++i) {
    freeList_.push_back(static_cast<int32_t>(i));
  }
}

BufferPool::~BufferPool() = default;

Buffer BufferPool::acquire(int32_t timeoutMs) {
  std::unique_lock<std::mutex> lock(mutex_);
  acquireCount_.fetch_add(1, std::memory_order_relaxed);

  if (freeList_.empty()) {
    blockCount_.fetch_add(1, std::memory_order_relaxed);
    if (timeoutMs < 0) {
      cv_.wait(lock, [this] { return !freeList_.empty(); });
    } else {
      auto pred = [this] { return !freeList_.empty(); };
      if (!cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), pred)) {
        return Buffer();
      }
    }
  }

  int32_t index = freeList_.back();
  freeList_.pop_back();

  size_t usage = currentUsage_.fetch_add(1, std::memory_order_relaxed) + 1;
  size_t peak = peakUsage_.load(std::memory_order_relaxed);
  while (usage > peak && !peakUsage_.compare_exchange_weak(peak, usage)) {
  }

  uint8_t *data = memory_.get() + (static_cast<size_t>(index) * bufferSize_);
  return Buffer(data, bufferSize_, index, this);
}

Buffer BufferPool::tryAcquire() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (freeList_.empty()) {
    return Buffer();
  }

  acquireCount_.fetch_add(1, std::memory_order_relaxed);
  int32_t index = freeList_.back();
  freeList_.pop_back();

  currentUsage_.fetch_add(1, std::memory_order_relaxed);
  uint8_t *data = memory_.get() + (static_cast<size_t>(index) * bufferSize_);
  return Buffer(data, bufferSize_, index, this);
}

void BufferPool::returnBuffer(int32_t index) {
  std::lock_guard<std::mutex> lock(mutex_);
  freeList_.push_back(index);
  currentUsage_.fetch_sub(1, std::memory_order_relaxed);
  cv_.notify_one();
}

size_t BufferPool::available() const noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  return freeList_.size();
}

size_t BufferPool::total() const noexcept { return bufferCount_; }

size_t BufferPool::bufferSize() const noexcept { return bufferSize_; }

uint64_t BufferPool::acquireCount() const noexcept {
  return acquireCount_.load(std::memory_order_relaxed);
}

uint64_t BufferPool::blockCount() const noexcept {
  return blockCount_.load(std::memory_order_relaxed);
}

size_t BufferPool::peakUsage() const noexcept {
  return peakUsage_.load(std::memory_order_relaxed);
}

} // namespace muybridge
