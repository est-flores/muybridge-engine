# Threading Architecture

## Overview

The Muybridge video engine uses a strict 4-thread model designed for:

- **Low latency**: Sub-200ms Time-to-First-Frame
- **Battery efficiency**: Threads sleep when idle
- **Predictable performance**: No thread contention in hot paths

## Thread Roles

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         THREADING MODEL                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐    Commands    ┌──────────────┐                       │
│  │   MAIN/UI    │───────────────>│   CONTROL    │                       │
│  │   Thread 1   │                │   Thread 2   │                       │
│  │              │<───────────────│              │                       │
│  │ - No blocking│    Callbacks   │ - State mgmt │                       │
│  │ - Dispatch   │                │ - Buffering  │                       │
│  └──────────────┘                └──────┬───────┘                       │
│                                         │                                │
│                          ┌──────────────┴──────────────┐                │
│                          │                              │                │
│                          ▼                              ▼                │
│                   ┌──────────────┐              ┌──────────────┐        │
│                   │    DECODE    │    Frames    │    RENDER    │        │
│                   │   Thread 3   │─────────────>│   Thread 4   │        │
│                   │              │              │              │        │
│                   │ - HW decoder │              │ - V-Sync     │        │
│                   │ - Blocking OK│              │ - GPU upload │        │
│                   └──────────────┘              └──────────────┘        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Thread Details

### Thread 1: Main/UI

- **Owner**: Application
- **Blocking**: NEVER
- **Responsibility**: Command dispatch only (play, pause, seek)
- **Communication**: Posts commands to Control thread queue

### Thread 2: Control

- **Owner**: Engine
- **Blocking**: NEVER (uses condition variables with timeouts)
- **Responsibility**:
  - State machine management
  - Buffer level monitoring
  - Clock synchronization
  - Error handling
- **Communication**: Message queue from Main, signals to Decode/Render

### Thread 3: Decode

- **Owner**: Engine
- **Blocking**: ALLOWED (hardware decoder calls)
- **Responsibility**:
  - Hardware decoder configuration
  - Frame extraction from container
  - Feeding decoder with compressed data
  - Outputting decoded frames to frame queue
- **Communication**: Frame queue to Render, status to Control

### Thread 4: Render

- **Owner**: Engine
- **Blocking**: ALLOWED (V-Sync only)
- **Responsibility**:
  - V-Sync locked presentation
  - GPU texture upload
  - A/V sync decision
  - Frame drop/repeat execution
- **Communication**: Reads from frame queue, status to Control

## Synchronization Primitives

| Primitive                 | Purpose                                           |
| ------------------------- | ------------------------------------------------- |
| `std::mutex`              | Protecting shared state (lock hierarchy enforced) |
| `std::condition_variable` | Signaling between threads                         |
| `std::atomic`             | Lock-free counters and flags                      |
| Lock-free SPSC queue      | Decode→Render frame passing                       |

## Lock Hierarchy

To prevent deadlocks, locks must be acquired in this order:

1. `stateMutex_` (Control thread state)
2. `bufferMutex_` (Buffer pool)
3. `clockMutex_` (Audio clock updates)

## Message Passing

Commands flow through a lock-free command queue:

```cpp
// Main thread
engine->play();  // Posts PlayCommand to queue

// Control thread (loop)
while (running) {
    Command cmd;
    if (commandQueue_.tryPop(cmd)) {
        handleCommand(cmd);
    }
    checkBufferLevels();
    std::this_thread::sleep_for(10ms);
}
```

## Thread Lifecycle

### Startup

1. Main: `initialize()` creates Control thread
2. Control: `load()` creates Decode thread
3. Control: First frame decoded → creates Render thread
4. Render: First frame displayed → TTFF complete

### Shutdown

1. Main: `release()` signals all threads
2. Render: Finishes current frame, exits
3. Decode: Flushes decoder, exits
4. Control: Cleans up resources, exits
5. Main: Joins all threads
