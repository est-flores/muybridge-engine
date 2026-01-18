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

if(ANDROID_NATIVE_API_LEVEL LESS 24)
    message(FATAL_ERROR "Muybridge requires Android API level 24+")
endif()

#-------------------------------------------------------------------------------
# Source Files
#-------------------------------------------------------------------------------

set(ANDROID_SOURCES
    src/AndroidVideoDecoder.cpp
    src/VideoTextureRenderer.cpp
    src/MuybridgeJNI.cpp
)

#-------------------------------------------------------------------------------
# Android Library
#-------------------------------------------------------------------------------

add_library(muybridge_android SHARED ${ANDROID_SOURCES})

# Include paths
target_include_directories(muybridge_android
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_SOURCE_DIR}/include
)

# Link core library
target_link_libraries(muybridge_android
    PRIVATE
        muybridge_core
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

target_link_libraries(muybridge_android
    PRIVATE
        ${MEDIANDK_LIB}
        ${ANDROID_LIB}
        ${LOG_LIB}
        ${GLES3_LIB}
        ${EGL_LIB}
)

#-------------------------------------------------------------------------------
# Compiler Flags
#-------------------------------------------------------------------------------

target_compile_options(muybridge_android
    PRIVATE
        -Wall
        -Wextra
        -Wpedantic
        -fvisibility=hidden
)

# Hide all symbols except JNI exports
set_target_properties(muybridge_android PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
