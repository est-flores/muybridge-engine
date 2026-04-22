/**
 * @file MuybridgeJNI.cpp
 * @brief JNI bridge between Kotlin and native Muybridge engine.
 */

#include "AndroidVideoDecoder.h"
#include "VideoTextureRenderer.h"
#include "muybridge/Log.h"

#include <android/native_window_jni.h>
#include <jni.h>

#include <memory>
#include <mutex>
#include <unordered_map>

namespace {

// Global engine instances (per-player, indexed by handle)
struct PlayerInstance {
  std::unique_ptr<muybridge::android::AndroidVideoDecoder> decoder;
  std::unique_ptr<muybridge::android::VideoTextureRenderer> renderer;
  jobject callbackRef = nullptr;
  JavaVM *jvm = nullptr;
};

std::mutex g_mutex;
int64_t g_nextHandle = 1;
std::unordered_map<int64_t, std::unique_ptr<PlayerInstance>> g_players;

PlayerInstance *getPlayer(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_players.find(handle);
  return it != g_players.end() ? it->second.get() : nullptr;
}

JNIEnv *getEnv(JavaVM *jvm) {
  JNIEnv *env = nullptr;
  jvm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
  return env;
}

} // anonymous namespace

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void * /*reserved*/) {
  MUY_LOGI("Muybridge JNI loaded");
  muybridge::log::g_startTime = muybridge::log::Clock::now();
  return JNI_VERSION_1_6;
}

JNIEXPORT void JNI_OnUnload(JavaVM * /*vm*/, void * /*reserved*/) {
  MUY_LOGI("Muybridge JNI unloaded");
  std::lock_guard<std::mutex> lock(g_mutex);
  g_players.clear();
}

//------------------------------------------------------------------------------
// Player Lifecycle
//------------------------------------------------------------------------------

JNIEXPORT jlong JNICALL Java_com_muybridge_player_MuybridgePlayer_nativeCreate(
    JNIEnv *env, jobject thiz) {

  std::lock_guard<std::mutex> lock(g_mutex);

  auto player = std::make_unique<PlayerInstance>();
  player->decoder = std::make_unique<muybridge::android::AndroidVideoDecoder>();
  player->renderer =
      std::make_unique<muybridge::android::VideoTextureRenderer>();
  env->GetJavaVM(&player->jvm);

  int64_t handle = g_nextHandle++;
  g_players[handle] = std::move(player);

  MUY_LOGI("Player created: handle=%lld", handle);
  return handle;
}

JNIEXPORT void JNICALL Java_com_muybridge_player_MuybridgePlayer_nativeRelease(
    JNIEnv *env, jobject thiz, jlong handle) {

  std::lock_guard<std::mutex> lock(g_mutex);

  auto it = g_players.find(handle);
  if (it != g_players.end()) {
    if (it->second->callbackRef) {
      env->DeleteGlobalRef(it->second->callbackRef);
    }
    g_players.erase(it);
    MUY_LOGI("Player released: handle=%lld", handle);
  }
}

//------------------------------------------------------------------------------
// Surface Management
//------------------------------------------------------------------------------

JNIEXPORT void JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeSetSurface(JNIEnv *env,
                                                           jobject thiz,
                                                           jlong handle,
                                                           jobject surface) {

  auto *player = getPlayer(handle);
  if (!player)
    return;

  ANativeWindow *window = nullptr;
  if (surface) {
    window = ANativeWindow_fromSurface(env, surface);
  }

  player->decoder->setSurface(window);

  if (window) {
    ANativeWindow_release(window); // decoder acquired its own ref
  }
}

JNIEXPORT jint JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeGetTextureId(JNIEnv *env,
                                                             jobject thiz,
                                                             jlong handle) {

  auto *player = getPlayer(handle);
  if (!player)
    return 0;

  return static_cast<jint>(player->renderer->getTextureId());
}

//------------------------------------------------------------------------------
// Playback Control
//------------------------------------------------------------------------------

JNIEXPORT jboolean JNICALL Java_com_muybridge_player_MuybridgePlayer_nativeLoad(
    JNIEnv *env, jobject thiz, jlong handle, jstring url) {

  auto *player = getPlayer(handle);
  if (!player)
    return JNI_FALSE;

  const char *urlChars = env->GetStringUTFChars(url, nullptr);
  std::string urlStr(urlChars);
  env->ReleaseStringUTFChars(url, urlChars);

  bool result = player->decoder->open(urlStr);
  return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_com_muybridge_player_MuybridgePlayer_nativePlay(
    JNIEnv *env, jobject thiz, jlong handle) {

  auto *player = getPlayer(handle);
  if (player) {
    player->decoder->start();
  }
}

JNIEXPORT void JNICALL Java_com_muybridge_player_MuybridgePlayer_nativePause(
    JNIEnv *env, jobject thiz, jlong handle) {

  auto *player = getPlayer(handle);
  if (player) {
    player->decoder->stop();
  }
}

JNIEXPORT void JNICALL Java_com_muybridge_player_MuybridgePlayer_nativeSeek(
    JNIEnv *env, jobject thiz, jlong handle, jlong positionNanos) {

  auto *player = getPlayer(handle);
  if (player) {
    player->decoder->seek(positionNanos);
  }
}

//------------------------------------------------------------------------------
// Rendering
//------------------------------------------------------------------------------

JNIEXPORT jboolean JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeInitRenderer(JNIEnv *env,
                                                             jobject thiz,
                                                             jlong handle) {

  auto *player = getPlayer(handle);
  if (!player)
    return JNI_FALSE;

  return player->renderer->initialize() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeSetViewport(
    JNIEnv *env, jobject thiz, jlong handle, jint width, jint height) {

  auto *player = getPlayer(handle);
  if (player) {
    player->renderer->setViewport(width, height);
  }
}

JNIEXPORT void JNICALL Java_com_muybridge_player_MuybridgePlayer_nativeRender(
    JNIEnv *env, jobject thiz, jlong handle, jfloatArray transformMatrix) {

  auto *player = getPlayer(handle);
  if (!player)
    return;

  float *matrix = nullptr;
  if (transformMatrix) {
    matrix = env->GetFloatArrayElements(transformMatrix, nullptr);
  }

  player->renderer->render(matrix);

  if (matrix) {
    env->ReleaseFloatArrayElements(transformMatrix, matrix, JNI_ABORT);
  }
}

JNIEXPORT void JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeReleaseRenderer(JNIEnv *env,
                                                                jobject thiz,
                                                                jlong handle) {

  auto *player = getPlayer(handle);
  if (player) {
    player->renderer->release();
  }
}

//------------------------------------------------------------------------------
// Media Info
//------------------------------------------------------------------------------

JNIEXPORT jlong JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeGetDuration(JNIEnv *env,
                                                            jobject thiz,
                                                            jlong handle) {

  auto *player = getPlayer(handle);
  if (!player)
    return 0;

  return player->decoder->getMediaInfo().durationNanos;
}

JNIEXPORT jint JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeGetVideoWidth(JNIEnv *env,
                                                              jobject thiz,
                                                              jlong handle) {

  auto *player = getPlayer(handle);
  if (!player)
    return 0;

  return player->decoder->getMediaInfo().videoWidth;
}

JNIEXPORT jint JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeGetVideoHeight(JNIEnv *env,
                                                               jobject thiz,
                                                               jlong handle) {

  auto *player = getPlayer(handle);
  if (!player)
    return 0;

  return player->decoder->getMediaInfo().videoHeight;
}

JNIEXPORT jboolean JNICALL
Java_com_muybridge_player_MuybridgePlayer_nativeIsEndOfStream(JNIEnv *env,
                                                              jobject thiz,
                                                              jlong handle) {
  auto *player = getPlayer(handle);
  return (player && player->decoder->isEndOfStream()) ? JNI_TRUE : JNI_FALSE;
}

} // extern "C"
