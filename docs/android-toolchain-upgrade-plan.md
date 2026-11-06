# Android toolchain upgrade (Gradle, AGP, Kotlin): plan

Source: the owner saw Flutter's "support will soon be dropped" warnings for Gradle 8.14, AGP 8.11.1 and Kotlin 2.2.20.
This doc is for the implementation session. It was researched on 2026-11-05 against `main` at `615c136`.
Line numbers drift, so search for the named symbol if a line is off. Everything here is under `client/` unless a path says otherwise.

## Why this is needed now

Flutter's Gradle plugin checks the build tools on every Android build (`DependencyVersionChecker.kt` in Flutter's `flutter_tools/gradle`).
Below the "warn" version it prints the warning. Below the "error" version the build **fails**.

| Flutter | Gradle warn / error | AGP warn / error | Kotlin warn / error |
|---|---|---|---|
| 3.47.9 (stable) | 9.1.0 / 8.14.0 | 9.0.1 / 8.11.1 | 2.3.20 / 2.2.20 |
| 3.50.0-0.4.pre (beta) and master `da33f2f` (2026-11-05) | 9.5.0 / 9.3.1 | 9.3.1 / 9.1.1 | 2.4.20 / 2.4.10 |
| **This project today** | 8.14 | 8.11.1 | 2.2.20 |

- We sit exactly on 3.47's error floor. 3.50 and current master **refuse to build the APK** with our versions.
- CI is still green only because `subosito/flutter-action` caches master under a fixed key (`flutter-linux-master-any-x64-master`): CI runs a master from weeks ago and never refreshes it. The CI log of run 42108072666 shows the three warnings with the 3.47 thresholds.
- Flutter master's own new-project template is Gradle 9.5.0, AGP 9.3.1, Kotlin 2.4.20, Java 17 source level, NDK 28.2.13676358.
- Gradle 9.x also runs on Java 21 to 26, which removes the reason CI pins Java 17 (the comment in `client-verify.yml`).

## Rules for the implementing session

- Branch: the one you were given. One commit per phase (Phase 0 may be two: see there). Push after each phase and wait for the `Client - build and test` workflow. **Do not start the next phase until CI is green.**
- Stop and report instead of improvising if a gate fails in a way this plan does not cover. Report the CI log lines.
- Never use `--android-skip-build-dependency-validation`. Never skip, delete or weaken a test to get green.
- Change only what a phase lists. No unrelated refactors, no other dependency bumps (`flutter pub upgrade <name>` for the named packages only; do not run a bare `flutter pub upgrade` or `--major-versions`).
- This session probably has no Android SDK (`dl.google.com` was blocked when this plan was written). CI is the build check. If you do have one, run `flutter build apk --debug` locally too.
- Kotlin and Gradle files are not checked by `flutter analyze` or `flutter test`. Only the CI APK build checks them.
- At the end of each phase fill in its row in the Progress table at the bottom of this doc, and say what was not verified (nothing here is checked on a device until the owner does it).
- When all phases are done, add a dated entry to `docs/status.md` (format: the recent entries at its end).

---

## Phase 0: CI on a known, current Flutter

Goal: CI builds with a fixed, current Flutter master, so Phases 1-4 are tested against the Flutter that enforces the new floors.

1. `.github/workflows/client-verify.yml`, step "Set up Flutter": pin master to a commit.
   ```yaml
   - name: Set up Flutter
     uses: subosito/flutter-action@v2
     with:
       channel: master
       flutter-version: da33f2fadf235b352afffa8e7083305d44ea1dc1
       cache: true
   ```
   `da33f2f` is the master commit whose thresholds are in the table above. Rewrite the comment block above the step: keep why master (flutter_scene 0.18 needs flutter_gpu API only master has), add that the commit is pinned so CI is reproducible, that the cache key follows the pinned commit, and how to move it (change the hash, push, check CI).
2. Same file, step "Set up Java for the Android build": `java-version: "21"`. Rewrite its comment: AGP 9.3 has a known lint crash on JDK 17 (`NoSuchMethodError: java.util.List.removeLast()`), Gradle 9.5 supports 17 to 26, 21 is the LTS.
3. Push. Expect: analyze/test may now report things the old master did not.
   - `flutter analyze` treats infos as fatal. A newer master was seen reporting about 230 `deprecated_member_use` infos (see the Progress note in `docs/flutter-testing-feedback-2026-11-05-plan.md`).
   - If that happens, fix them in a **second commit** of Phase 0: apply only the replacement the deprecation message names (for example `withOpacity(x)` to `withValues(alpha: x)`, `MaterialState*` to `WidgetState*`). If a replacement is not behaviour-identical (a different default, a visual change), do not guess: list it in the Progress table and leave it for the owner, using `// ignore: deprecated_member_use` on that line with a one-line reason.
   - Expect the Android build in this run to **fail** with Flutter's error for Gradle/AGP/Kotlin being too old. That is correct and proves the pin works. Phase 1 fixes it. Note it in the Progress table and go straight on to Phase 1 (this is the one place a red build is expected).
4. Gate: analyze and test green on the pinned commit.

Owner action after Phase 0 (put this in the final report in plain words): update the Flutter on their own machine to the same commit, or at least `flutter upgrade` on master, otherwise their local build will differ from CI.

## Phase 1: build tools to Flutter's current template versions

Files and exact changes:

1. `android/gradle/wrapper/gradle-wrapper.properties`:
   `distributionUrl=https\://services.gradle.org/distributions/gradle-9.5.0-all.zip` (9.5.0, not 9.5.1: 9.5.0 is the highest Flutter master marks as known and supported).
2. `android/settings.gradle`, `plugins` block:
   ```groovy
   id "com.android.application" version "9.3.1" apply false
   id "org.jetbrains.kotlin.android" version "2.4.20" apply false
   ```
3. `android/build.gradle`: replace the deprecated `buildDir` API with the template's `layout.buildDirectory` form. The output folder must stay `client/build/` (CI copies `client/build/app/outputs/flutter-apk/app-debug.apk`).
   ```groovy
   allprojects {
       repositories {
           google()
           mavenCentral()
       }
   }

   def newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
   rootProject.layout.buildDirectory.value(newBuildDir)

   subprojects {
       project.layout.buildDirectory.value(newBuildDir.dir(project.name))
   }
   subprojects {
       project.evaluationDependsOn(":app")
   }

   tasks.register("clean", Delete) {
       delete rootProject.layout.buildDirectory
   }
   ```
   (`../../build` is relative to the default `android/build`, so it is `client/build`, the same as today's `"../build"` relative to `android/`.)
4. `android/app/build.gradle`:
   - `compileOptions`: `JavaVersion.VERSION_17` for both source and target (was 1.8; the template uses 17).
   - Delete the `kotlinOptions { ... }` block inside `android { }` (deprecated since Kotlin 2.0) and add, after the `android { }` block:
     ```groovy
     kotlin {
         compilerOptions {
             jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
         }
     }
     ```
   - Leave the `plugins` block (`kotlin-android` stays in this phase).
5. `android/gradle.properties`: delete `android.enableJetifier=true` (all dependencies are AndroidX; Jetifier only slows the build). **Keep** both `android.builtInKotlin=false` and `android.newDsl=false` in this phase.

Gate:
- CI green, and the "Build debug APK" log contains none of "will soon be dropped" or "not yet tested" style messages for Gradle, AGP or Kotlin. Quote the relevant log lines in the Progress table.
- If the build fails on Jetifier removal (a message naming a `com.android.support` artifact), put the line back and record which dependency needs it.
- If `kotlin { compilerOptions }` fails in Groovy, try `kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }`; if both fail, stop and report.

Owner device check (whole app, because everything is recompiled): install the debug APK from the branch's GitHub release; connect to the backend; open a part and see the 3D view; save and reopen a project folder; Server Management (Termux) screen opens; the battery-optimisation prompt; export a mesh and Share it; the AI screen's microphone; attach an image in the AI screen.

## Phase 2: built-in Kotlin (`android.builtInKotlin=true`)

AGP 9 compiles Kotlin itself. The opt-out goes away in AGP 10, so this has to happen eventually. What blocked it here:

| Plugin | Locked | Applies the Kotlin plugin itself? | Fix |
|---|---|---|---|
| `share_plus` | 10.1.4 | Yes, always | 13.3.1 applies it only when built-in Kotlin is off |
| `speech_to_text` | 7.4.0 | Yes, always | 7.5.0 ("Migrates to built-in Kotlin") does not apply it |
| `flutter_image_compress_common` | 1.1.1 (latest) | Only when built-in Kotlin is off | Nothing needed |
| `file_picker` 8.3.7, `saf_util`, `saf_stream`, `shared_preferences_android`, `url_launcher_android`, `flutter_plugin_android_lifecycle`, `jni`, `jni_flutter` | | No | Nothing needed |

Steps:

1. `pubspec.yaml`: `share_plus: ^13.3.1`, `speech_to_text: ^7.5.0`. Then `flutter pub upgrade share_plus speech_to_text` (named packages only). Commit the `pubspec.lock` change.
2. `share_plus` 11+ deprecates `Share`. Migrate both call sites to the new API (same behaviour):
   - `lib/ai/ai_modelling_screen.dart` (`Share.shareXFiles([XFile(path)], subject: subject)`)
   - `lib/mesh_viewer/mesh_viewer_screen.dart` (`Share.shareXFiles([XFile(exportPath)], subject: 'DIDSA-CAD mesh export')`)

   New form: `await SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: subject));`. Check the `ShareParams` field names in the resolved package source before writing.
3. `speech_to_text` 7.5.0: the changelog lists no Dart API change. Run analyze and the existing `test/ai_modelling_screen_test.dart`.
4. `android/gradle.properties`: `android.builtInKotlin=true`. Keep `android.newDsl=false` (see Phase 4).
5. `android/app/build.gradle`: remove `id "kotlin-android"` from `plugins`. The `kotlin { compilerOptions }` block from Phase 1 stays (with built-in Kotlin, `jvmTarget` defaults to `targetCompatibility`, so it may also be deleted; keep it for clarity).
6. `android/settings.gradle`: keep `id "org.jetbrains.kotlin.android" version "2.4.20" apply false`. It only puts Kotlin 2.4.20 on the build classpath, which is how Flutter's own plugin template picks the Kotlin version under built-in Kotlin. If the build fails saying the plugin is no longer required, remove that line and record it.

Gate: CI green; the APK step log has no Kotlin plugin errors. Known risk: Flutter issue #192167 reported the Flutter Gradle plugin rejecting built-in Kotlin on 3.47.2. If CI fails with an error from Flutter's Gradle plugin about built-in Kotlin, revert step 4 and 5 only (keep the plugin bumps), record the error and the Flutter issue, and go on to Phase 3.

Owner device check: Share from the mesh viewer and from the AI screen (Android share sheet opens with the file); the AI screen's microphone works; attaching an image still works (image compression plugin).
If the owner uses the **Windows** desktop build: `share_plus` 13 moves to `win32` 6. CI does not build Windows, so the owner should build and try Share there.

## Phase 3: `file_picker` 8.3.7 to 13.3.2

Why: 8.x is two major versions behind; its Android build uses the old `lintOptions` DSL (a blocker for Phase 4); 13 adds persistable Android folder grants and fixes out-of-memory on image picks.
Version 12 was a rewrite. The API changes that hit this app:

| Old (8.x) | New (13.x) |
|---|---|
| `FilePicker.platform.xxx(...)` | `FilePicker.xxx(...)` (static) |
| `pickFiles(...)` returns `FilePickerResult?` with `.files` | `pickFiles(...)` returns `List<PlatformFile>` (empty on cancel); `pickFile(...)` returns `PlatformFile?` for one file |
| `allowMultiple: true` | removed: use `pickFiles` for several, `pickFile` for one |
| `withData: true` then `file.bytes` | removed: `await file.readAsBytes()` |
| `file.path` (a cached copy on Android) | `file.path` is `null` unless the file has a `file://` URI. On Android a picked file may come back as `content://` |
| `saveFile(...)` returns `String?` path; `bytes` optional; on desktop it did **not** write the bytes | `saveFile({required fileName, required bytes, ...})` returns `Uri?`, and writes the bytes itself |
| `size` | `lengthSync()` / `length()` |

Call sites (all 15 `FilePicker.platform` calls):

| File | Symbol / what it does | Required change |
|---|---|---|
| `lib/ai/ai_modelling_screen.dart` `_attachImage` | multi image pick, then `file.path` | `FilePicker.pickFiles(type: FileType.image)`; empty list = cancel. When `path` is null, use `readAsBytes()` instead of reading the path (the code after it already works on bytes; read the method before changing it) |
| same file, plan import with hook (`pickFiles(type: custom, json/md/txt)`) | reads `files.single.path` as a string | `pickFile(...)`; text from `utf8.decode(await f.readAsBytes())` so `content://` works |
| same file, plan import (`json/md/txt/zip`) | `files.single.path`, shows "Could not import plan" when null | `pickFile(...)`. A zip must be readable from a `content://` file: when `path` is null, write `readAsBytes()` to a file in `getTemporaryDirectory()` and continue with that path. Keep the existing error dialog for real failures |
| `lib/mesh_viewer/mesh_viewer_screen.dart` `_pickAndLoad` | needs a real path (`_decodeAndDecimate` reads it in an isolate) | `pickFile(type: FileType.any)`; when `path` is null, copy to a temp file as above, then go on with that path. Keep the extension check (`file.extension`) |
| `lib/materials/materials_manager_screen.dart` `_exportCsv` | `saveFile` then a manual desktop `File(savedPath).writeAsBytes` | `saveFile` now writes the bytes: remove the manual write (and its comment); `null` = cancel |
| same file `_importCsv` | `withData`, `files.single.bytes` | `pickFile(...)`, `await f.readAsBytes()` |
| `lib/sketch/sketch_screen.dart` `_saveStandaloneSketch` | `saveFile`; keeps `savedPath.split('/').last` as the last file name | Use `uri.pathSegments.last` (decoded) for the name. On Android a `content://` last segment may be a document id, not a name: if it has no `.DIDSAsketch` ending, keep the previous `_lastSavedSketchFileName` |
| same file `_openStandaloneSketch` | `withData`, `.bytes` | `pickFile(...)`, `readAsBytes()` |
| `lib/viewport3d/part_screen.dart` `_saveNativeFileViaDialog` | `saveFile`, then desktop manual write; stores `_lastSavedFileName` and `_lastSavedFilePath` from the string path | Remove the manual write. On desktop (`_canPersistFilePathForReuse`) the `Uri` is `file://`: `_lastSavedFilePath = uri.toFilePath()`. Name as in the sketch row |
| same file, Save / Save As on desktop (`picked = ... saveFile(dialogTitle: isSaveAs ? ...)`, **no bytes**) | used only to pick a location; the project is then written through `DesktopProjectRoot` | **Hard spot.** 13 requires bytes and writes them. Do not pass empty bytes (it would leave an empty file, and `withDefaultExtension` may change the name). Read the method: if the part's bytes can be produced before the dialog, pass them and let the existing write overwrite the same path. Otherwise stop and report the options; do not change how projects are saved without the owner |
| same file `_openViaDesktopFilePicker` | `withData`, `.bytes` | `pickFile(...)`, `readAsBytes()` |
| same file, the import at `pickFiles(withData: true ...)` near `extension = (picked.extension ?? ...)` | `.bytes`, `.extension`, `.name` | `pickFile(...)`, `readAsBytes()`; `extension` and `name` still exist |
| same file, Export Part (`saveFile(dialogTitle: 'Export Part' ...)`) | `saveFile`, then desktop manual write | Remove the manual write |
| `lib/storage/desktop_storage_service.dart` | `getDirectoryPath(dialogTitle: ...)` | `FilePicker.getDirectoryPath(...)`; still `String?`. Keep the `StorageException` handling |

Steps: `pubspec.yaml` `file_picker: ^13.3.2`, `flutter pub upgrade file_picker`, make the changes above, analyze, test. If a test fakes `FilePicker.platform`, update it to the new platform interface (`FilePickerPlatform.instance`). Add focused unit tests for any helper you add (for example a "path or temp copy" helper), and add the test file to whatever list the client tests use (none today: `flutter test` runs `test/`).

Gate: CI green. Grep shows no `FilePicker.platform`, `withData`, `allowMultiple`, `FilePickerResult` left in `lib/`.

Owner device check, Android and (if used) desktop. Each must behave as before:
1. AI screen: attach one image, then several; import a plan `.json`; import a plan `.zip`.
2. Mesh viewer: open an STL or GLB from Downloads and from a cloud provider (Drive or similar).
3. Materials: export CSV, import it back.
4. Sketch: Save Drawing, then Open it.
5. Part: Save Project, Save As (desktop), open a project file (desktop), import a file, Export Part (STEP or STL).
6. Desktop: choose a project folder.

## Phase 4: new DSL probe (`android.newDsl=true`), expected to fail

Not expected to work yet. Blockers found on 2026-11-05: `speech_to_text` 7.5.0 still uses `lintOptions`; `flutter_image_compress_common` 1.1.1 (latest) uses `compileSdkVersion 34` and `project.android.hasProperty`; Flutter's own Gradle plugin migration to the new DSL is open (flutter/flutter#180137).

1. One commit setting `android.newDsl=true`. Push, let CI run.
2. Record the first error (plugin and line) in the Progress table.
3. If it is green (unlikely), keep it and say so.
4. Otherwise a second commit reverts the line. CI must be green again.
5. Add a short "Not done" note to the `docs/status.md` entry: what blocks the new DSL, so it can be retried when those plugins update.

---

## Out of scope (separate work)

- `flutter_scene` 0.18 to 0.24 and leaving the master channel. 0.24 needs Flutter >= 3.47, so stable may become possible, and opaque draws are 2.5 to 6 times faster on Mali GPUs. But it breaks app code: `lib/viewport3d/mesh_geometry.dart` `bind(gpu.RenderPass, gpu.HostBuffer, Lighting)` (0.19 replaced `HostBuffer` with `TransientWriter`); 0.23 flipped front-face winding (custom geometry must swap triangle order or faces vanish); 0.24 `Scene.initializeStaticResources()` now throws on failure (`part_viewport.dart`, `mesh_viewer_render.dart`, `b1_tap_test_screen.dart`). Needs its own investigation and an on-device visual check.
- DIDSA-VR: its Godot Android build has its own Gradle and is not affected. Its `tools/setup_test_env.sh` clones the master tip, which is newer than the pin here; that is fine for `flutter test`.

## Progress

| Phase | Commit | CI run | What landed / what failed | Not verified |
|---|---|---|---|---|
| 0 | 5c4d8ad, 2f10a36 | 42121666962 (red), 42127726301 (analyze + test green; APK red as expected) | Pin to `da33f2f` and JDK 21 landed. Flutter set-up, pub get and `flutter test` passed. `flutter analyze` failed: 237 infos, all `deprecated_member_use`, all the same one: the `import 'package:flutter/material.dart'` line itself ("Use package:material_ui/material_ui.dart instead ... deprecated after v3.47.0-0.0.pre"), one per file in `lib/` and `test/`. Owner chose to add `material_ui ^1.10.0` and rewrite the 237 imports (commit 2f10a36; `pubspec.lock` not regenerated, no Flutter SDK in the session). Then analyze + test green, and the APK step failed as expected: "Your project's Gradle version (8.14.0) is lower than Flutter's minimum supported version of 9.3.1". | Everything on a device. Android build not yet reached. |
| 1 | 5634d90 (+ 158ff1a, 07a2127 below) | 42128792656 (red), then 42135533890 (green) | Gradle 9.5.0, AGP 9.3.1, Kotlin 2.4.20, `layout.buildDirectory`, Java 17, `kotlin { compilerOptions }`, Jetifier removed. First run failed on `:file_picker:checkDebugAarMetadata` (`flutter_plugin_android_lifecycle` needs compileSdk 36, `file_picker` 8.3.7 compiled against 34); owner chose to do Phase 3 first, which fixed it. Green run 42135533890: APK built and published. APK log has no 'will soon be dropped' line for Gradle, AGP or Kotlin. Only remaining: `WARNING: Your Android app project: app ... applies the Kotlin Gradle Plugin` and `plugins that apply Kotlin Gradle Plugin (KGP): flutter_image_compress_common, speech_to_text` (Phase 2). | Everything on a device. |
| 2 | 07a2127 (share_plus, pulled ahead), then the `speech_to_text` + built-in Kotlin commit | 42137067703 (green) | `share_plus ^13.3.1` + `SharePlus.instance.share(ShareParams(files:, subject:))` at both call sites (landed early, see Phase 3); `speech_to_text ^7.5.0`; `android.builtInKotlin=true`; `id "kotlin-android"` removed; `settings.gradle` kotlin plugin line kept and accepted. APK built and published; no Kotlin plugin errors, and Flutter's Gradle plugin accepted built-in Kotlin (issue #192167 did not hit). Remaining log warning: `WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): flutter_image_compress_common` (latest version, nothing to do; a future Flutter may refuse it). | Share sheet, microphone, image attach on a device. Windows `share_plus` 13 (`win32` 6) build not run. |
| 3 | 2f10a36.., WIP, 158ff1a, 07a2127 | 42133716287 (red: pub get), 42135533890 (green) | `file_picker ^13.3.2` at every call site; helper `lib/storage/picked_file.dart` + `test/picked_file_test.dart`; desktop Save / Save As now uses the folder + name-prompt flow (owner chose option 3, instead of a native save dialog); zip import reads bytes directly. `pub get` conflict (`share_plus` 10 needs `win32` 5, `file_picker` 13 needs `win32` 6) fixed by pulling Phase 2 steps 1-2 for `share_plus` ahead (13.3.1, `SharePlus.instance.share(ShareParams(...))`, owner approved); `pubspec.lock` regenerated. Local Flutter at `da33f2f`: analyze clean, full `flutter test` 3581 passed / 47 skipped. Grep: no `FilePicker.platform`, `withData`, `allowMultiple`, `FilePickerResult` in `lib/`. | Every Phase 3 item on a device (Android and desktop). Windows `share_plus`/`file_picker` builds not run. |
| 4 | | | | |
