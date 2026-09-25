# Builds the production dart:ffi shim (occt_ffi_shim.cpp/.h) over a vendor
# vcpkg build of OpenCASCADE (OCCT) - trimmed to only the toolkits needed for
# STEP-read + tessellation (no TKV3d/visualization stack at all -
# flutter_scene renders, this shim never draws anything).
#
# Two-step configure, mirroring client/native/slvs/CMakeLists.txt's own
# documented two-step vcpkg shape (that file's header comment explains why
# a vendored/third-party build and this project's own CMakeLists stay
# separate invocations rather than one add_subdirectory):
#   1. Bootstrap vcpkg once (`./vcpkg/bootstrap-vcpkg.sh` or `.bat`), then let
#      its toolchain file resolve `vcpkg.json`'s "opencascade" port for the
#      target triplet:
#        cmake -B <build-dir> -S . \
#              -DCMAKE_TOOLCHAIN_FILE=<vcpkg-root>/scripts/buildsystems/vcpkg.cmake \
#              -DVCPKG_TARGET_TRIPLET=x64-windows   # or x64-linux / arm64-android / arm64-ios
#        cmake --build <build-dir> --target didsa_occt_ffi
#   2. That's it - unlike slvs's vendor/ (a plain source checkout this
#      project configures itself), vcpkg's own port build system handles
#      OCCT's own configure/build/install step internally; this file only
#      needs `find_package(OpenCASCADE CONFIG REQUIRED)` once vcpkg has
#      installed the port for the active triplet.
#
# Honesty check (same spirit as slvs's own CMakeLists.txt, which documents
# Android as a still-manual NDK cross-compile): x64-windows and x64-linux are
# vcpkg's most mature triplets for the "opencascade" port and are expected to
# just work. arm64-android and arm64-ios triplet support for this specific
# port is NOT verified in this sandbox (no network access to actually fetch
# and build vcpkg's opencascade port here) - if either proves too immature
# when actually attempted, the documented fallback is OCCT's own upstream
# CMake build, cross-compiled directly with the Android NDK toolchain file
# (or `ios.toolchain.cmake` for iOS) instead of going through vcpkg at all -
# the same "vendor's own CMakeLists, not vcpkg" shape slvs's build already
# uses for Android today. Whichever path is used, the resulting library must
# still be named/placed exactly as this file's `add_library` line produces,
# so the Dart-side loader (step_loader.dart's loadOcctBindingsOrNull) keeps
# working unchanged.
cmake_minimum_required(VERSION 3.21)
project(didsa_occt_shim CXX)

find_package(OpenCASCADE CONFIG REQUIRED)

add_library(didsa_occt_ffi SHARED
    occt_ffi_shim.cpp
    occt_ffi_shim.h)

target_include_directories(didsa_occt_ffi PRIVATE ${OpenCASCADE_INCLUDE_DIR})

# Only the toolkits actually reachable from this shim's own STEP-read +
# XCAF-enumerate + BRepMesh-tessellate call set - see occt_ffi_shim.cpp's
# #include list for exactly which OCCT headers that is. No TKV3d/
# visualization toolkits at all: this keeps the shipped library genuinely
# lightweight rather than linking all of OCCT, even though it's built from
# the same OCCT source the backend's own pythonocc-core already trusts (see
# backend/app/document/import_geometry.py / mesh.py).
#
# TKXDESTEP (STEPCAFControl_Reader's own real toolkit, confirmed by an
# actual local build/link against a real OCCT 7.6.3 install - the original
# plan's own toolkit list omitted it, since STEP-only reading might
# plausibly have lived in TKSTEP/TKSTEPBase/TKXCAF alone; it doesn't -
# `STEPCAFControl_Reader` links against `TKXDESTEP` specifically) is not in
# the plan's original list above TKMesh - added here, confirmed necessary by
# a real `undefined symbol: _ZN21STEPCAFControl_ReaderC1Ev` link failure
# before this was added. A different OCCT/vcpkg port version may name this
# toolkit differently (some releases fold STEP CAF support into a renamed
# `TKDESTEP`) - if `TKXDESTEP` isn't found for a given vcpkg triplet, check
# that port's own toolkit list for STEPCAFControl_Reader's actual home.
target_link_libraries(didsa_occt_ffi PRIVATE
    TKernel
    TKMath
    TKBRep
    TKG2d
    TKG3d
    TKGeomBase
    TKGeomAlgo
    TKTopAlgo
    TKShHealing
    TKSTEP
    TKSTEPBase
    TKSTEPAttr
    TKSTEP209
    TKXSBase
    TKXDESTEP
    TKXCAF
    TKCAF
    TKLCAF
    TKMesh)

set_target_properties(didsa_occt_ffi PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED YES)

# Same "static C++ runtime, not the toolchain's shared one" fix slvs's own
# CMakeLists.txt documents and needed for real - a shared libc++/libstdc++
# dependency fails to dlopen on a real Android device (nothing bundles
# libc++_shared.so alongside this library), so this is required, not
# optional polish, on every toolchain that supports the flag.
if(MINGW OR ANDROID)
    target_link_options(didsa_occt_ffi PRIVATE -static-libstdc++ -static-libgcc)
endif()
