cmake_minimum_required(VERSION 3.22.1)
project("cclaude")

# Find the Zig-compiled shared library
# The Zig library will be built separately and placed in jniLibs
add_library(cclaude SHARED IMPORTED)
set_target_properties(cclaude PROPERTIES
    IMPORTED_LOCATION ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libcclaude.so
)

# JNI wrapper
add_library(cclaude-jni SHARED
    cclaude_jni.cpp
)

target_link_libraries(cclaude-jni
    cclaude
    log
)
