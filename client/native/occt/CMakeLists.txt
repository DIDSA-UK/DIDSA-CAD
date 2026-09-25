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
# before this was added.
#
# vcpkg.json pins opencascade to exactly 7.9.3#1 via "overrides" (matching
# the backend's own pythonocc-core-wrapped OCCT version in
# backend/environment.yml, rather than tracking vcpkg's latest baseline) -
# this is load-bearing, not just for parity: a real CI failure confirmed
# that OCCT 8.0.x (vcpkg's default baseline at the time) renames/
# consolidates the classic TKSTEP/TKSTEPBase/TKSTEPAttr/TKSTEP209/TKXSBase
# toolkits this list below still names ("LINK : fatal error LNK1181: cannot
# open input file 'TKSTEP.lib'"), so linking against 8.0.x with these exact
# names fails outright. The `if(TARGET ...)` guards below are a second,
# independent safety net on top of that pin - if a future vcpkg.json bump
# (or a platform triplet whose port build genuinely differs) reintroduces
# a version where some of these targets don't exist, the build degrades to
# "link whatever of this list actually exists" instead of a hard
# configure-time or link-time failure, though occt_ffi_shim.cpp's own
# #include/API usage still assumes the classic (pre-8.0) toolkit shape and
# would need real changes to work against a consolidated TKDE/TKDESTEP
# layout - this guard only prevents linking a nonexistent name, it doesn't
# make the shim itself version-agnostic.
set(_didsa_occt_step_toolkits
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
foreach(_didsa_occt_toolkit ${_didsa_occt_step_toolkits})
    if(TARGET ${_didsa_occt_toolkit})
        target_link_libraries(didsa_occt_ffi PRIVATE ${_didsa_occt_toolkit})
    else()
        message(WARNING "didsa_occt_ffi: expected OCCT toolkit '${_didsa_occt_toolkit}' not found as a CMake target - skipping it, but occt_ffi_shim.cpp may fail to link/behave correctly without it. Check vcpkg.json's pinned opencascade version.")
    endif()
endforeach()

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
