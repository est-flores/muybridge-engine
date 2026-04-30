#ifndef MUYBRIDGE_STATE_H
#define MUYBRIDGE_STATE_H

/**
 * @file State.h
 * @brief Engine state machine enumeration for the Muybridge video engine.
 * 
 * Defines all possible states the video engine can be in during its lifecycle.
 * State transitions are managed by the Control thread and must follow the
 * documented state machine diagram.
 * 
 * @note Thread Safety: State reads are atomic; transitions are controlled
 *       exclusively by the Control thread.
 */

#include <cstdint>
#include <string_view>

namespace muybridge {

/**
 * @enum State
 * @brief Represents the current operational state of the video engine.
 * 
 * State Machine:
 * @code
 * ┌─────────────────────────────────────────────────────────────┐
 * │                                                             │
 * │  ┌──────┐  initialize()  ┌─────────┐  load()  ┌─────────┐  │
 * │  │ Idle │───────────────>│ Loading │─────────>│Buffering│  │
 * │  └──────┘                └─────────┘          └────┬────┘  │
 * │      ▲                        │                    │       │
 * │      │                        │                    ▼       │
 * │      │                        │               ┌─────────┐  │
 * │      │ release()              │ error         │ Playing │◄─┤
 * │      │                        ▼               └────┬────┘  │
 * │      │                   ┌─────────┐              │       │
 * │      └───────────────────│  Error  │              ▼       │
 * │                          └─────────┘         ┌─────────┐  │
 * │                               ▲              │ Paused  │  │
 * │                               │              └─────────┘  │
 * │                               │                    │       │
 * │                          (any state)               │       │
 * │                               └──────────Seeking◄──┘       │
 * │                                                             │
 * └─────────────────────────────────────────────────────────────┘
 * @endcode
 */
enum class State : uint8_t {
    /**
     * @brief Initial state, no resources allocated.
     * 
     * Valid transitions: Idle -> Loading (via initialize() + load())
     */
    Idle = 0,
    
    /**
     * @brief Media source is being opened and parsed.
     * 
     * During this state:
     * - Container format is detected
     * - Stream information is extracted
     * - Hardware decoder is configured
     * 
     * Valid transitions: Loading -> Buffering, Loading -> Error
     */
    Loading,
    
    /**
     * @brief Prebuffering frames for smooth playback.
     * 
     * During this state:
     * - Decode thread is filling the frame buffer
     * - Target: enough frames for smooth startup
     * - TTFF timer is running
     * 
     * Valid transitions: Buffering -> Playing, Buffering -> Error
     */
    Buffering,
    
    /**
     * @brief Active playback with video/audio rendering.
     * 
     * During this state:
     * - Render thread is presenting frames at V-Sync
     * - Audio is playing (if present)
     * - A/V sync is actively managed
     * 
     * Valid transitions: Playing -> Paused, Playing -> Buffering,
     *                    Playing -> Seeking, Playing -> Error
     */
    Playing,
    
    /**
     * @brief Playback is paused, last frame displayed.
     * 
     * During this state:
     * - Audio is stopped
     * - Video frame is held on screen
     * - Buffers may be partially filled
     * 
     * Valid transitions: Paused -> Playing, Paused -> Seeking,
     *                    Paused -> Idle (via release())
     */
    Paused,
    
    /**
     * @brief Seeking to a new position in the stream.
     * 
     * During this state:
     * - Keyframe search is in progress
     * - Decode buffers are being flushed/refilled
     * - Last valid frame may be displayed
     * 
     * Valid transitions: Seeking -> Playing, Seeking -> Paused,
     *                    Seeking -> Buffering, Seeking -> Error
     */
    Seeking,
    
    /**
     * @brief Unrecoverable error occurred.
     * 
     * Check getErrorCode() for specific error information.
     * Only valid transition: Error -> Idle (via release())
     */
    Error
};

/**
 * @brief Convert State enum to human-readable string.
 * 
 * @param state The state to convert
 * @return String view of the state name (e.g., "Playing")
 * 
 * @note Returns "Unknown" for invalid state values.
 */
constexpr std::string_view stateToString(State state) noexcept {
    switch (state) {
        case State::Idle:      return "Idle";
        case State::Loading:   return "Loading";
        case State::Buffering: return "Buffering";
        case State::Playing:   return "Playing";
        case State::Paused:    return "Paused";
        case State::Seeking:   return "Seeking";
        case State::Error:     return "Error";
        default:               return "Unknown";
    }
}

/**
 * @brief Check if the engine is in an active playback state.
 * 
 * @param state The state to check
 * @return true if Playing, Buffering, or Seeking
 */
constexpr bool isActiveState(State state) noexcept {
    return state == State::Playing || 
           state == State::Buffering || 
           state == State::Seeking;
}

/**
 * @brief Check if the state transition is valid.
 * 
 * @param from Current state
 * @param to Target state
 * @return true if the transition is allowed
 */
constexpr bool isValidTransition(State from, State to) noexcept {
    // Error state can only transition to Idle via release()
    if (from == State::Error) {
        return to == State::Idle;
    }
    
    // Any state can transition to Error
    if (to == State::Error) {
        return true;
    }
    
    // Idle can only go to Loading
    if (from == State::Idle) {
        return to == State::Loading;
    }
    
    // Define valid transitions for other states
    switch (from) {
        case State::Loading:
            return to == State::Buffering;
            
        case State::Buffering:
            return to == State::Playing;
            
        case State::Playing:
            return to == State::Paused || 
                   to == State::Buffering || 
                   to == State::Seeking ||
                   to == State::Idle;
            
        case State::Paused:
            return to == State::Playing || 
                   to == State::Seeking ||
                   to == State::Idle;
            
        case State::Seeking:
            return to == State::Playing || 
                   to == State::Paused ||
                   to == State::Buffering;
            
        default:
            return false;
    }
}

} // namespace muybridge

#endif // MUYBRIDGE_STATE_H
