# Muybridge Player - ProGuard Rules

# Keep JNI methods
-keepclasseswithmembernames class com.muybridge.player.MuybridgePlayer {
    native <methods>;
}

# Keep public API
-keep class com.muybridge.player.MuybridgePlayer { *; }
-keep class com.muybridge.player.MuybridgePlayer$State { *; }
-keep class com.muybridge.player.VideoSurfaceView { *; }
