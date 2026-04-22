add_executable(muybridge_core_tests
    core/AVSyncTest.cpp
    core/ClockTest.cpp
    core/BufferPoolTest.cpp
)

target_link_libraries(muybridge_core_tests PRIVATE
    muybridge_core
    GTest::gtest_main
)

target_include_directories(muybridge_core_tests PRIVATE
    ${MUYBRIDGE_INCLUDE_DIR}
)

include(GoogleTest)
gtest_discover_tests(muybridge_core_tests)
