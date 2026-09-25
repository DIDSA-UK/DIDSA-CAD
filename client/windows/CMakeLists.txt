# STEP/OCCT (see the DIDSA_ENABLE_OCCT block near the bottom of this file):
# `flutter build windows -- -DFOO=BAR` does NOT forward trailing args to the
# underlying cmake configure - flutter's own arg parser treats them as
# target-file arguments instead (confirmed by a real CI failure: "Target
# file \"-DDIDSA_ENABLE_OCCT=ON\" not found."). vcpkg's toolchain file must
# also be set before the first project() call below to actually take effect
# (it hooks compiler detection at that point) - so both the OCCT toggle and
# the vcpkg toolchain/triplet are read from environment variables here,
# before project(), rather than from -D command-line args. Set
# DIDSA_ENABLE_OCCT=1, CMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/
# vcpkg.cmake and VCPKG_TARGET_TRIPLET=x64-windows in the environment before
# running `flutter build windows` (see .github/workflows/client-verify.yml's
# Windows job).
if(DEFINED ENV{DIDSA_ENABLE_OCCT} AND DEFINED ENV{CMAKE_TOOLCHAIN_FILE})
  set(CMAKE_TOOLCHAIN_FILE "$ENV{CMAKE_TOOLCHAIN_FILE}" CACHE FILEPATH "Vcpkg toolchain file")
endif()
if(DEFINED ENV{VCPKG_TARGET_TRIPLET})
  set(VCPKG_TARGET_TRIPLET "$ENV{VCPKG_TARGET_TRIPLET}" CACHE STRING "Vcpkg triplet")
endif()

# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(didsa_cad_client LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "didsa_cad_client")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# STEP support for the Mesh Viewer (client/lib/mesh_viewer/step_loader.dart) -
# builds client/native/occt/'s own didsa_occt_ffi shim and installs it next
# to the app's .exe, same "co-located native library" convention every other
# Flutter-managed plugin DLL already uses on this platform (see
# PLUGIN_BUNDLED_LIBRARIES above). Off by default (DIDSA_ENABLE_OCCT) -
# client/native/occt/CMakeLists.txt's own find_package(OpenCASCADE CONFIG
# REQUIRED) needs a configured vcpkg toolchain file that a plain `flutter
# build windows` has no reason to have set up; enable explicitly
# (-DDIDSA_ENABLE_OCCT=ON, alongside -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/
# buildsystems/vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-windows) from a CI job
# or a developer machine with vcpkg already set up - see
# .github/workflows/client-verify.yml's own Windows job.
option(DIDSA_ENABLE_OCCT "Build the STEP/OCCT FFI shim (needs a configured vcpkg toolchain)" OFF)
if(DEFINED ENV{DIDSA_ENABLE_OCCT} AND NOT DIDSA_ENABLE_OCCT)
  set(DIDSA_ENABLE_OCCT ON)
endif()
if(DIDSA_ENABLE_OCCT)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native/occt" "${CMAKE_CURRENT_BINARY_DIR}/didsa_occt")
  install(FILES $<TARGET_FILE:didsa_occt_ffi> DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
endif()
