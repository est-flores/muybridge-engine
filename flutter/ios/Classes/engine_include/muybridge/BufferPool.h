#ifndef MUYBRIDGE_BUFFERPOOL_H
#define MUYBRIDGE_BUFFERPOOL_H

/**
 * @file BufferPool.h
 * @brief Pre-allocated memory buffer pool for zero-copy video pipeline.
 */

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace muybridge {

class BufferPool;

/**
 * @class Buffer
 * @brief RAII handle to a pooled buffer.
 */
class Buffer {
public:
  Buffer() noexcept = default;
  ~Buffer();

  Buffer(Buffer &&other) noexcept;
  Buffer &operator=(Buffer &&other) noexcept;
  Buffer(const Buffer &) = delete;
  Buffer &operator=(const Buffer &) = delete;

  explicit operator bool() const noexcept { return data_ != nullptr; }
  uint8_t *data() noexcept { return data_; }
  const uint8_t *data() const noexcept { return data_; }
  size_t capacity() const noexcept { return capacity_; }
  size_t size() const noexcept { return size_; }
  void setSize(size_t size) noexcept;
  int32_t index() const noexcept { return index_; }

private:
  friend class BufferPool;
  Buffer(uint8_t *data, size_t capacity, int32_t index, BufferPool *pool);

  uint8_t *data_ = nullptr;
  size_t capacity_ = 0;
  size_t size_ = 0;
  int32_t index_ = -1;
  BufferPool *pool_ = nullptr;
};

/**
 * @struct BufferPoolConfig
 * @brief Configuration for buffer pool allocation.
 */
struct BufferPoolConfig {
  size_t bufferCount = 8;
  size_t bufferSize = 1024 * 1024;
  const char *name = "default";
};

/**
 * @class BufferPool
 * @brief Pre-allocated pool of reusable buffers.
 */
class BufferPool {
public:
  BufferPool();
  explicit BufferPool(const BufferPoolConfig &config);
  ~BufferPool();

  BufferPool(const BufferPool &) = delete;
  BufferPool &operator=(const BufferPool &) = delete;

  Buffer acquire(int32_t timeoutMs = -1);
  Buffer tryAcquire();
  size_t available() const noexcept;
  size_t total() const noexcept;
  size_t bufferSize() const noexcept;
  const char *name() const noexcept { return name_; }
  uint64_t acquireCount() const noexcept;
  uint64_t blockCount() const noexcept;
  size_t peakUsage() const noexcept;

private:
  friend class Buffer;
  void returnBuffer(int32_t index);

  const char *name_;
  size_t bufferSize_;
  size_t bufferCount_;
  std::unique_ptr<uint8_t[]> memory_;
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::vector<int32_t> freeList_;
  std::atomic<uint64_t> acquireCount_{0};
  std::atomic<uint64_t> blockCount_{0};
  std::atomic<size_t> currentUsage_{0};
  std::atomic<size_t> peakUsage_{0};
};

} // namespace muybridge

#endif // MUYBRIDGE_BUFFERPOOL_H
