cmake_minimum_required(VERSION 3.18.1)

project(roadcast_jni C)

# libroadcast_client.so is NOT distributed with this repository on purpose
# (see the Roadcast section of the README). Build it from the public
# Roadcast source and place it at
# android/app/src/main/jniLibs/arm64-v8a/libroadcast_client.so, or run
# scripts/update_roadcast_client.sh --roadcast-root <roadcast checkout>.
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libroadcast_client.so")
    message(FATAL_ERROR
        "Missing libroadcast_client.so for ${ANDROID_ABI}. "
        "This repository does not distribute the Roadcast binaries on purpose — "
        "see the Roadcast section of the README for how to build them from "
        "https://github.com/Timoteohss/roadcast and where to place them.")
endif()
add_library(roadcast_client SHARED IMPORTED)
set_target_properties(
        roadcast_client
        PROPERTIES
        IMPORTED_LOCATION
        "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libroadcast_client.so"
        IMPORTED_NO_SONAME TRUE)

add_library(roadcast_jni SHARED roadcast_jni.c)
target_compile_options(roadcast_jni PRIVATE -O2 -Wall -Wextra -Werror)
target_link_libraries(roadcast_jni roadcast_client)
