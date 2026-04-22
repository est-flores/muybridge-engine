cmake_minimum_required(VERSION 3.22)
project(muybridge_android)

set(ENGINE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../..")

add_library(muybridge_android SHARED
    ${ENGINE_ROOT}/src/core/Clock.cpp
    ${ENGINE_ROOT}/src/core/AVSync.cpp
    ${ENGINE_ROOT}/src/core/BufferPool.cpp
    ${ENGINE_ROOT}/platform/android/src/AndroidVideoDecoder.cpp
    ${ENGINE_ROOT}/platform/android/src/VideoTextureRenderer.cpp
    ${ENGINE_ROOT}/platform/android/src/MuybridgeJNI.cpp
)

target_compile_features(muybridge_android PRIVATE cxx_std_17)

target_compile_definitions(muybridge_android PRIVATE
    MUYBRIDGE_PLATFORM_ANDROID=1
)

target_include_directories(muybridge_android PRIVATE
    ${ENGINE_ROOT}/include
    ${ENGINE_ROOT}/platform/android/src
)

target_link_libraries(muybridge_android
    mediandk
    android
    log
    EGL
    GLESv3
)
