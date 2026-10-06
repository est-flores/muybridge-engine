cmake_minimum_required(VERSION 3.16)

#===============================================================================
# MUYBRIDGE ENGINE - Core Video Engine for Mobile
#===============================================================================
# A hardware-accelerated video pipeline for Android/iOS, designed for a
# sub-200ms Time-to-First-Frame (TTFF) target with a zero-copy architecture.
#===============================================================================

project(muybridge-engine
    VERSION 0.1.0
    DESCRIPTION "Hardware-accelerated mobile video engine"
    LANGUAGES CXX
)

#-------------------------------------------------------------------------------
# Build Configuration
#-------------------------------------------------------------------------------

# C++17 is required for std::optional, std::variant, structured bindings
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Export compile commands for IDE integration
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

#-------------------------------------------------------------------------------
# Platform Detection
#-------------------------------------------------------------------------------

# Detect platform and set appropriate flags
if(CMAKE_SYSTEM_NAME STREQUAL "Android")
    message(STATUS "Building for Android (NDK)")
    set(MUYBRIDGE_PLATFORM "ANDROID")
    set(MUYBRIDGE_PLATFORM_ANDROID ON)
    
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(STATUS "Building for iOS")
    set(MUYBRIDGE_PLATFORM "IOS")
    set(MUYBRIDGE_PLATFORM_IOS ON)
    
    # iOS-specific settings
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum iOS version")
    set(CMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET ${CMAKE_OSX_DEPLOYMENT_TARGET})
    
elseif(APPLE)
    message(STATUS "Building for macOS (development)")
    set(MUYBRIDGE_PLATFORM "MACOS")
    set(MUYBRIDGE_PLATFORM_MACOS ON)
    
elseif(UNIX)
    message(STATUS "Building for Linux (development)")
    set(MUYBRIDGE_PLATFORM "LINUX")
    set(MUYBRIDGE_PLATFORM_LINUX ON)
    
else()
    message(FATAL_ERROR "Unsupported platform: ${CMAKE_SYSTEM_NAME}")
endif()

# Make platform available to source code
add_compile_definitions(MUYBRIDGE_PLATFORM_${MUYBRIDGE_PLATFORM}=1)

#-------------------------------------------------------------------------------
# Compiler Warnings
#-------------------------------------------------------------------------------

# Strict warning flags to catch issues early
set(MUYBRIDGE_WARNING_FLAGS
    -Wall
    -Wextra
    -Wpedantic
    -Werror=return-type
    -Wno-unused-parameter  # Allow unused params in virtual interface stubs
)

# Additional warnings for Clang/GCC
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    list(APPEND MUYBRIDGE_WARNING_FLAGS
        -Wshadow
        -Wconversion
        -Wsign-conversion
        -Wnull-dereference
    )
endif()

#-------------------------------------------------------------------------------
# Include Paths
#-------------------------------------------------------------------------------

# Public headers accessible to consumers
set(MUYBRIDGE_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/include)

#-------------------------------------------------------------------------------
# Core Library Target
#-------------------------------------------------------------------------------

# Collect core source files
set(MUYBRIDGE_CORE_SOURCES
    src/core/Clock.cpp
    src/core/AVSync.cpp
    src/core/BufferPool.cpp
)

# Create the core library (STATIC for mobile embedding)
add_library(muybridge_core STATIC ${MUYBRIDGE_CORE_SOURCES})

# Apply include directories
target_include_directories(muybridge_core
    PUBLIC
        $<BUILD_INTERFACE:${MUYBRIDGE_INCLUDE_DIR}>
        $<INSTALL_INTERFACE:include>
)

# Apply warning flags
target_compile_options(muybridge_core PRIVATE ${MUYBRIDGE_WARNING_FLAGS})

# Position-independent code for shared library compatibility
set_target_properties(muybridge_core PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

#-------------------------------------------------------------------------------
# Platform-Specific Libraries (Placeholder for Phase 2/3)
#-------------------------------------------------------------------------------

if(MUYBRIDGE_PLATFORM_ANDROID)
    # Will add: platform/android/CMakeLists.txt
    # add_subdirectory(platform/android)
endif()

if(MUYBRIDGE_PLATFORM_IOS)
    # Will add: platform/ios/CMakeLists.txt
    # add_subdirectory(platform/ios)
endif()

#-------------------------------------------------------------------------------
# Threading Support
#-------------------------------------------------------------------------------

find_package(Threads REQUIRED)
target_link_libraries(muybridge_core PUBLIC Threads::Threads)

#-------------------------------------------------------------------------------
# Installation Configuration
#-------------------------------------------------------------------------------

include(GNUInstallDirs)

install(TARGETS muybridge_core
    EXPORT muybridge-targets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
)

install(DIRECTORY ${MUYBRIDGE_INCLUDE_DIR}/muybridge
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

#-------------------------------------------------------------------------------
# Tests
#-------------------------------------------------------------------------------

option(BUILD_TESTS "Build unit tests" OFF)

if(BUILD_TESTS)
    enable_testing()

    include(FetchContent)
    FetchContent_Declare(
        googletest
        URL https://github.com/google/googletest/archive/v1.14.0.zip
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)

    add_subdirectory(tests)
endif()

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------

message(STATUS "")
message(STATUS "=== Muybridge Engine Configuration ===")
message(STATUS "Version:    ${PROJECT_VERSION}")
message(STATUS "Platform:   ${MUYBRIDGE_PLATFORM}")
message(STATUS "C++ Std:    ${CMAKE_CXX_STANDARD}")
message(STATUS "Build Type: ${CMAKE_BUILD_TYPE}")
message(STATUS "=======================================")
message(STATUS "")
