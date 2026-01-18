# Testing the Muybridge Video Player 🎬

A friendly guide to test your video player with a real video!

## Prerequisites

- A test video file (MP4 format recommended)
- Android device/emulator OR iOS device/simulator
- Android Studio (for Android) OR Xcode (for iOS)

---

## Option 1: Testing on Android 🤖

### Step 1: Prepare Your Video

1. Get a short test video (e.g., `test.mp4`)
2. Push it to your Android device:
   ```bash
   adb push test.mp4 /sdcard/Movies/test.mp4
   ```

### Step 2: Create a Test App

1. Create a new Android project in Android Studio
2. Add the Muybridge library:
   - Copy `platform/android/` to your project's `libs/` folder
   - Add to your app's `build.gradle.kts`:
     ```kotlin
     dependencies {
         implementation(project(":libs:muybridge-android"))
     }
     ```

3. Copy the sample code from `examples/android/MainActivity.kt` into your
   MainActivity

### Step 3: Update the Video Path

In `MainActivity.kt`, change the video path:

```kotlin
private const val TEST_VIDEO = "file:///sdcard/Movies/test.mp4"
```

### Step 4: Add Permissions

In your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
```

### Step 5: Run!

1. Click "Run" in Android Studio
2. Watch the logcat for TTFF measurements:
   ```
   [I] [TTFF] Load started @ 0.0ms
   [I] [TTFF] Media opened @ 15.2ms
   [I] [TTFF] First frame @ 142.3ms ✓
   [I] [TTFF] TARGET MET: <200ms ✓
   ```

---

## Option 2: Testing on iOS 🍎

### Step 1: Prepare Your Video

1. Get a test video (e.g., `test.mp4`)
2. Add it to your iOS app bundle:
   - Drag the video into Xcode
   - Check "Copy items if needed"
   - Add it to your target

### Step 2: Create a Test App

1. Create a new iOS project in Xcode
2. Add the Muybridge code:
   - Add `platform/ios/` files to your project
   - Add framework dependencies in Build Phases → Link Binary:
     - AVFoundation
     - CoreMedia
     - CoreVideo
     - VideoToolbox
     - Metal
     - MetalKit

3. Copy `examples/ios/VideoViewController.swift` into your project

### Step 3: Update the Video Path

In `VideoViewController.swift`:

```swift
private let testVideoURL = Bundle.main.path(forResource: "test", ofType: "mp4")!
```

### Step 4: Run!

1. Click "Run" in Xcode
2. Watch the console for TTFF:
   ```
   [MuybridgeExample] [TTFF] Load started
   [MuybridgeExample] [TTFF] First frame @ 138ms ✓
   [MuybridgeExample] [TTFF] TARGET MET: <200ms ✓
   ```

---

## What You Should See ✅

### On Screen:

- Video starts playing automatically
- Smooth playback at native frame rate
- No stuttering or tearing

### In Logs:

- TTFF breakdown showing timing for each step
- Should complete in under 200ms
- A/V sync warnings if drift exceeds ±16ms

### Example Log Output:

```
=== TTFF Breakdown Report ===
  [   0.0ms] start
  [  15.2ms] extractor_configured (+15.2ms)
  [  45.7ms] codec_configured (+30.5ms)
  [ 112.4ms] first_frame_decoded (+66.7ms)
  [ 142.3ms] complete (+29.9ms)
  ─────────────────────
  Total TTFF: 142.3ms ✓
=============================
```

---

## Quick Test (No App Needed!)

### Android Quick Test:

```bash
# Install example APK (if you build it)
adb install example.apk
adb push test.mp4 /sdcard/Movies/test.mp4
adb shell am start -n com.muybridge.example/.MainActivity
adb logcat | grep TTFF
```

### iOS Quick Test:

Use the SwiftUI example for fastest testing:

```swift
import SwiftUI

@main
struct TestApp: App {
    var body: some Scene {
        WindowGroup {
            VideoPlayerScreen(videoURL: "test.mp4")
        }
    }
}
```

---

## Troubleshooting 🔧

### "Failed to load video"

- ✅ Check file path is correct
- ✅ Verify video format (MP4/H.264 works best)
- ✅ Check file permissions

### "Playback error"

- ✅ Check video codec is supported (H.264/HEVC)
- ✅ Verify device has hardware decoder
- ✅ Check logcat/console for specific error

### No video visible

- ✅ Make sure VideoSurfaceView/MetalVideoView is added to layout
- ✅ Check view's size is not 0x0
- ✅ Verify player.setPlayer() was called

---

## Need Help?

Check the logs first! The engine logs every major step, so the answer is usually
there. Look for:

- `[TTFF]` - Timing milestones
- `[SYNC]` - A/V sync issues
- `[E]` - Error messages

Happy testing! 🎉
