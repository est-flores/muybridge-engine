# Android platform library for Muybridge Engine
# Requires Android NDK r21+ with API level 24+

cmake_minimum_required(VERSION 3.16)

project(muybridge_android
    VERSION 0.1.0
    LANGUAGES CXX
)

# Require C++17
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Android-specific checks
if(NOT ANDROID)
    message(FATAL_ERROR "This CMakeLists.txt is for Android only")
endif()

if(ANDROID_PLATFORM_LEVEL LESS 26)
    message(FATAL_ERROR "AAudio requires minSdk 26 (Android 8.0)")
endif()

#-------------------------------------------------------------------------------
# Core Library Sources (inline build)
#-------------------------------------------------------------------------------

set(CORE_SOURCES
    ../../src/core/Clock.cpp
    ../../src/core/AVSync.cpp
    ../../src/core/BufferPool.cpp
)

#-------------------------------------------------------------------------------
# Android-specific Sources
#-------------------------------------------------------------------------------

set(ANDROID_SOURCES
    src/AndroidVideoDecoder.cpp
    src/VideoTextureRenderer.cpp
    src/MuybridgeJNI.cpp
)

#-------------------------------------------------------------------------------
# Android Library
#-------------------------------------------------------------------------------

add_library(muybridge_android SHARED 
    ${CORE_SOURCES}
    ${ANDROID_SOURCES}
)

# Include paths
target_include_directories(muybridge_android
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_CURRENT_SOURCE_DIR}/../../include
)

#-------------------------------------------------------------------------------
# Android NDK Libraries
#-------------------------------------------------------------------------------

# Media NDK (AMediaCodec, AMediaExtractor)
find_library(MEDIANDK_LIB mediandk REQUIRED)

# Android runtime
find_library(ANDROID_LIB android REQUIRED)

# Logging
find_library(LOG_LIB log REQUIRED)

# OpenGL ES 3.0
find_library(GLES3_LIB GLESv3 REQUIRED)

# EGL
find_library(EGL_LIB EGL REQUIRED)

# AAudio (API 26+; NDK stubs allow linking with any minSdk)
find_library(AAUDIO_LIB aaudio)

target_link_libraries(muybridge_android
    PRIVATE
        ${MEDIANDK_LIB}
        ${ANDROID_LIB}
        ${LOG_LIB}
        ${GLES3_LIB}
        ${EGL_LIB}
        $<$<BOOL:${AAUDIO_LIB}>:${AAUDIO_LIB}>
)

#-------------------------------------------------------------------------------
# Compiler Flags
#-------------------------------------------------------------------------------

target_compile_options(muybridge_android
    PRIVATE
        -Wall
        -Wextra
        -fvisibility=hidden
)

# Hide all symbols except JNI exports
set_target_properties(muybridge_android PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
