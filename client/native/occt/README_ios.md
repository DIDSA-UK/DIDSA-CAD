# iOS packaging (TODO - not attempted headlessly)

`didsa_occt_ffi` is not yet wired into `Runner.xcodeproj` - Xcode project
file surgery is hard to do (or verify) headlessly, so this is left as a
documented follow-up rather than attempted blind, matching the plan's own
"Phase B" scope for iOS.

Planned approach, mirroring `client/native/slvs/`'s own precedent and this
directory's `CMakeLists.txt`:

1. Build OCCT for the `arm64-ios` vcpkg triplet (`VCPKG_TARGET_TRIPLET=
   arm64-ios`), same manifest/CMakeLists.txt this directory already has -
   OR, if that triplet's `opencascade` port proves too immature (real risk,
   flagged in `CMakeLists.txt`'s own header comment), fall back to OCCT's
   own upstream CMake build cross-compiled with `ios.toolchain.cmake`.
   Either path should produce a **static** library (`didsa_occt_ffi.a`), not
   a shared one - the shared-`.dylib`-per-plugin convention the other three
   platforms use doesn't apply on iOS without extra app-thinning/embedding
   ceremony a static lib avoids.
2. Package the static lib (plus its own transitive OCCT static libs) as an
   `.xcframework` (`xcodebuild -create-xcframework`), so it carries its own
   per-architecture slices cleanly.
3. Embed the `.xcframework` in `Runner.xcodeproj` via Xcode's own
   "Frameworks, Libraries, and Embedded Content" build phase (General tab) -
   this is the actual project-file edit not attempted here.
4. On the Dart side, `step_loader.dart`'s `loadOcctBindingsOrNull()` already
   handles this: iOS uses `DynamicLibrary.process()` (the library is
   statically linked into the app binary itself, so every exported
   `occt_*` symbol is already resolvable process-wide - no `.open(...)`
   path needed at all).

No iOS CI job exists in `.github/workflows/client-verify.yml` for this
(or for anything else in this app) today - adding one is a separate
follow-up. Validate via a manual on-device build instead, consistent with
this app's existing "iOS builds but is untested on-device" status.
