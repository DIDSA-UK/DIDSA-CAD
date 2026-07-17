# Builds the production dart:ffi shim (slvs_ffi_shim.cpp/.h) over the
# vendored SolveSpace fork's slvs_static target.
#
# Two-step build, deliberately not a single `add_subdirectory(vendor)` -
# the vendored CMakeLists.txt (third-party source, kept unmodified for easy
# rebasing - see the rollout plan's "ongoing cost" section) hardcodes
# CMAKE_SOURCE_DIR in several places, assuming it is always the top-level
# project; add_subdirectory() breaks that assumption. This is also exactly
# the two-invocation shape the spike already proved works for the real
# Android NDK cross-compile (see docs/sketcher-spikes-ffi-and-plane-
# sketch.md's Track 1 verdict), so the host and Android builds share one
# recipe:
#
#   1. Configure/build vendor/ as its own standalone project:
#        cmake -B <vendor-build> -S vendor -DBUILD_PYTHON=OFF -DENABLE_GUI=OFF \
#              -DCMAKE_POLICY_VERSION_MINIMUM=3.5 [toolchain flags]
#        cmake --build <vendor-build> --target slvs_static
#   2. Configure/build this shim against the result:
#        cmake -B <shim-build> -S . -DSLVS_VENDOR_BUILD_DIR=<vendor-build> [toolchain flags]
#        cmake --build <shim-build>
cmake_minimum_required(VERSION 3.18)
project(didsa_slvs_shim CXX)

if(NOT DEFINED SLVS_VENDOR_BUILD_DIR)
    message(FATAL_ERROR "SLVS_VENDOR_BUILD_DIR must point at a directory where "
        "vendor/'s own CMakeLists.txt has already been configured and built "
        "(target slvs_static) - see the recipe in this file's own header comment.")
endif()

# Not find_library(): the Android NDK toolchain file sets
# CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY, which silently ignores an
# explicit PATHS argument outside the NDK sysroot - the build artifact
# directory always is. The static archive's name/location is fully known
# (it's this same recipe's own step 1 output), so just construct the path
# directly using the platform's real prefix/suffix.
set(SLVS_STATIC_LIBRARY
    "${SLVS_VENDOR_BUILD_DIR}/src/${CMAKE_STATIC_LIBRARY_PREFIX}slvs_static${CMAKE_STATIC_LIBRARY_SUFFIX}")
if(NOT EXISTS "${SLVS_STATIC_LIBRARY}")
    message(FATAL_ERROR "Expected slvs_static at ${SLVS_STATIC_LIBRARY} - "
        "has vendor/ been built yet (step 1 of this file's own recipe)?")
endif()

add_library(didsa_slvs_ffi SHARED
    slvs_ffi_shim.cpp
    slvs_ffi_shim.h)

target_include_directories(didsa_slvs_ffi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/src/swig
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/include)

# On Windows, slvs.h defaults every Slvs_* prototype to __declspec(dllimport)
# unless SLVS_STATIC_LIB is defined - correct for consuming the shared `slvs`
# target, but wrong here: we link the static archive directly, so the
# import-library stub dllimport expects doesn't exist (surfaces as an
# unresolved `__imp_Slvs_Solve` at link time without this).
target_compile_definitions(didsa_slvs_ffi PRIVATE SLVS_STATIC_LIB)

target_link_libraries(didsa_slvs_ffi PRIVATE ${SLVS_STATIC_LIBRARY})

set_target_properties(didsa_slvs_ffi PROPERTIES
    CXX_STANDARD 11
    CXX_STANDARD_REQUIRED YES)

# Spike finding (Track 1 verdict): the shim's default dynamic link against
# the toolchain's C++ runtime fails to load at all on a real Android device
# (`dlopen` can't find libc++_shared.so, since nothing bundles it) - static-
# linking the C++ runtime is required, not optional polish, on every
# toolchain that supports it.
if(MINGW OR ANDROID)
    target_link_options(didsa_slvs_ffi PRIVATE -static-libstdc++ -static-libgcc)
endif()
