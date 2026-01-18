#ifndef MUYBRIDGE_LOG_H
#define MUYBRIDGE_LOG_H

/**
 * @file Log.h
 * @brief Structured logging system for TTFF analysis and debugging.
 *
 * Provides macro-based logging with:
 * - Nanosecond timestamps for precise TTFF measurement
 * - Log levels (VERBOSE, DEBUG, INFO, WARN, ERROR)
 * - Platform-specific output (Android logcat, iOS os_log, stderr)
 * - Zero overhead when disabled in release builds
 *
 * @note All timestamps are relative to engine initialization for easy
 *       TTFF breakdown analysis.
 */

#include <chrono>
#include <cstdint>
#include <cstdio>

// Platform-specific includes
#if defined(MUYBRIDGE_PLATFORM_ANDROID)
#include <android/log.h>
#elif defined(MUYBRIDGE_PLATFORM_IOS) || defined(MUYBRIDGE_PLATFORM_MACOS)
#include <os/log.h>
#endif

namespace muybridge {
namespace log {

/**
 * @enum Level
 * @brief Log severity levels.
 */
enum class Level : uint8_t {
  Verbose = 0, ///< Detailed tracing (disabled in release)
  Debug = 1,   ///< Debug information (disabled in release)
  Info = 2,    ///< Informational messages
  Warn = 3,    ///< Warning conditions
  Error = 4    ///< Error conditions
};

/**
 * @brief High-resolution clock for TTFF measurement.
 */
using Clock = std::chrono::steady_clock;
using TimePoint = Clock::time_point;
using Nanoseconds = std::chrono::nanoseconds;

/**
 * @brief Global reference point for relative timestamps.
 *
 * Set this during engine initialization:
 * @code
 * muybridge::log::g_startTime = muybridge::log::Clock::now();
 * @endcode
 */
inline TimePoint g_startTime = Clock::now();

/**
 * @brief Get elapsed time since g_startTime in nanoseconds.
 * @return Nanoseconds since engine start
 */
inline int64_t elapsedNanos() noexcept {
  return std::chrono::duration_cast<Nanoseconds>(Clock::now() - g_startTime)
      .count();
}

/**
 * @brief Get elapsed time since g_startTime in milliseconds (floating point).
 * @return Milliseconds since engine start with fractional precision
 */
inline double elapsedMillis() noexcept {
  return static_cast<double>(elapsedNanos()) / 1'000'000.0;
}

// Minimum log level (configurable at compile time)
#ifndef MUYBRIDGE_LOG_LEVEL
#ifdef NDEBUG
#define MUYBRIDGE_LOG_LEVEL 2 // Info in release
#else
#define MUYBRIDGE_LOG_LEVEL 0 // Verbose in debug
#endif
#endif

// Log tag for platform loggers
constexpr const char *kLogTag = "Muybridge";

/**
 * @brief Internal logging function.
 *
 * @param level Log level
 * @param file Source file name
 * @param line Source line number
 * @param fmt Printf-style format string
 * @param ... Format arguments
 */
template <typename... Args>
inline void logImpl(Level level, [[maybe_unused]] const char *file,
                    [[maybe_unused]] int line, const char *fmt, Args... args) {
  // Skip if below minimum level
  if (static_cast<uint8_t>(level) < MUYBRIDGE_LOG_LEVEL) {
    return;
  }

  // Level prefixes
  const char *levelStr = "";
  switch (level) {
  case Level::Verbose:
    levelStr = "V";
    break;
  case Level::Debug:
    levelStr = "D";
    break;
  case Level::Info:
    levelStr = "I";
    break;
  case Level::Warn:
    levelStr = "W";
    break;
  case Level::Error:
    levelStr = "E";
    break;
  }

  // Format timestamp + message
  char buffer[512];
  char msgBuffer[384];

  // First format the user message (handles the format-security warning)
  if constexpr (sizeof...(args) == 0) {
    std::snprintf(msgBuffer, sizeof(msgBuffer), "%s", fmt);
  } else {
    std::snprintf(msgBuffer, sizeof(msgBuffer), fmt, args...);
  }

  // Then format the final output with timestamp
  std::snprintf(buffer, sizeof(buffer), "[%s] [%8.3fms] %s", levelStr,
                elapsedMillis(), msgBuffer);

#if defined(MUYBRIDGE_PLATFORM_ANDROID)
  int priority = ANDROID_LOG_VERBOSE;
  switch (level) {
  case Level::Verbose:
    priority = ANDROID_LOG_VERBOSE;
    break;
  case Level::Debug:
    priority = ANDROID_LOG_DEBUG;
    break;
  case Level::Info:
    priority = ANDROID_LOG_INFO;
    break;
  case Level::Warn:
    priority = ANDROID_LOG_WARN;
    break;
  case Level::Error:
    priority = ANDROID_LOG_ERROR;
    break;
  }
  __android_log_write(priority, kLogTag, buffer);

#elif defined(MUYBRIDGE_PLATFORM_IOS) || defined(MUYBRIDGE_PLATFORM_MACOS)
  // Use os_log for Apple platforms (formatted as public for debugging)
  os_log_type_t type = OS_LOG_TYPE_DEFAULT;
  switch (level) {
  case Level::Verbose:
    type = OS_LOG_TYPE_DEBUG;
    break;
  case Level::Debug:
    type = OS_LOG_TYPE_DEBUG;
    break;
  case Level::Info:
    type = OS_LOG_TYPE_INFO;
    break;
  case Level::Warn:
    type = OS_LOG_TYPE_DEFAULT;
    break;
  case Level::Error:
    type = OS_LOG_TYPE_ERROR;
    break;
  }
  os_log_with_type(OS_LOG_DEFAULT, type, "%{public}s", buffer);

#else
  // Default to stderr
  std::fprintf(stderr, "%s\n", buffer);
#endif
}

} // namespace log
} // namespace muybridge

//------------------------------------------------------------------------------
// Logging Macros
//------------------------------------------------------------------------------

/**
 * @def MUY_LOGV
 * @brief Log verbose message (disabled in release builds)
 */
#define MUY_LOGV(fmt, ...)                                                     \
  muybridge::log::logImpl(muybridge::log::Level::Verbose, __FILE__, __LINE__,  \
                          fmt, ##__VA_ARGS__)

/**
 * @def MUY_LOGD
 * @brief Log debug message (disabled in release builds)
 */
#define MUY_LOGD(fmt, ...)                                                     \
  muybridge::log::logImpl(muybridge::log::Level::Debug, __FILE__, __LINE__,    \
                          fmt, ##__VA_ARGS__)

/**
 * @def MUY_LOGI
 * @brief Log informational message
 */
#define MUY_LOGI(fmt, ...)                                                     \
  muybridge::log::logImpl(muybridge::log::Level::Info, __FILE__, __LINE__,     \
                          fmt, ##__VA_ARGS__)

/**
 * @def MUY_LOGW
 * @brief Log warning message
 */
#define MUY_LOGW(fmt, ...)                                                     \
  muybridge::log::logImpl(muybridge::log::Level::Warn, __FILE__, __LINE__,     \
                          fmt, ##__VA_ARGS__)

/**
 * @def MUY_LOGE
 * @brief Log error message
 */
#define MUY_LOGE(fmt, ...)                                                     \
  muybridge::log::logImpl(muybridge::log::Level::Error, __FILE__, __LINE__,    \
                          fmt, ##__VA_ARGS__)

//------------------------------------------------------------------------------
// TTFF Milestone Logging
//------------------------------------------------------------------------------

/**
 * @def MUY_TTFF_MILESTONE
 * @brief Log a TTFF milestone with precise timing.
 *
 * Usage:
 * @code
 * MUY_TTFF_MILESTONE("decoder_configured");
 * MUY_TTFF_MILESTONE("first_frame_decoded");
 * MUY_TTFF_MILESTONE("first_frame_rendered");
 * @endcode
 */
#define MUY_TTFF_MILESTONE(name)                                               \
  MUY_LOGI("[TTFF] %s @ %.3fms", name, muybridge::log::elapsedMillis())

#endif // MUYBRIDGE_LOG_H
