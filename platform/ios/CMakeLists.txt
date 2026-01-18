# iOS platform library for Muybridge Engine
# Requires iOS 13.0+ and Xcode 14+

cmake_minimum_required(VERSION 3.16)

project(muybridge_ios
    VERSION 0.1.0
    LANGUAGES CXX OBJCXX
)

# Require C++17 and Objective-C++
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)

# iOS-specific checks
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "This CMakeLists.txt is for iOS only")
endif()

#-------------------------------------------------------------------------------
# Source Files
#-------------------------------------------------------------------------------

set(IOS_SOURCES
    src/IOSVideoDecoder.mm
    src/MetalVideoRenderer.mm
    src/MuybridgeBridge.mm
)

set(METAL_SHADERS
    shaders/VideoShaders.metal
)

#-------------------------------------------------------------------------------
# iOS Static Library
#-------------------------------------------------------------------------------

add_library(muybridge_ios STATIC ${IOS_SOURCES})

# Include paths
target_include_directories(muybridge_ios
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${CMAKE_SOURCE_DIR}/include
)

# Link core library
target_link_libraries(muybridge_ios
    PRIVATE
        muybridge_core
)

#-------------------------------------------------------------------------------
# iOS Frameworks
#-------------------------------------------------------------------------------

find_library(AVFOUNDATION_FW AVFoundation REQUIRED)
find_library(COREMEDIA_FW CoreMedia REQUIRED)
find_library(COREVIDEO_FW CoreVideo REQUIRED)
find_library(VIDEOTOOLBOX_FW VideoToolbox REQUIRED)
find_library(METAL_FW Metal REQUIRED)
find_library(METALKIT_FW MetalKit REQUIRED)
find_library(QUARTZCORE_FW QuartzCore REQUIRED)

target_link_libraries(muybridge_ios
    PRIVATE
        ${AVFOUNDATION_FW}
        ${COREMEDIA_FW}
        ${COREVIDEO_FW}
        ${VIDEOTOOLBOX_FW}
        ${METAL_FW}
        ${METALKIT_FW}
        ${QUARTZCORE_FW}
)

#-------------------------------------------------------------------------------
# Compiler Flags
#-------------------------------------------------------------------------------

target_compile_options(muybridge_ios
    PRIVATE
        -Wall
        -Wextra
        -fobjc-arc
        -fvisibility=hidden
)

set_target_properties(muybridge_ios PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)
