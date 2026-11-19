#!/usr/bin/env bash
# Golden vectors for the sketch drag projector (docs/motion/sketch-projector-spec.md, section 10).
#
#   tools/sketch_vectors/export.sh            # (re)writes docs/motion/sketch-vectors.json
#   tools/sketch_vectors/export.sh --check    # exits 1 if a regeneration differs from the committed file, or the Dart
#                                             # projector does not reproduce a vector from the file alone
#
# The generator is client/test/support/sketch_vectors.dart, run through `flutter test` (not `dart run`: the projector imports
# sketch_api_client.dart, which pulls in Flutter). Check mode is the same test the full client suite runs.
set -euo pipefail
cd "$(dirname "$0")/../../client"
if [ "${1:-}" = "--check" ]; then
  flutter test test/sketch_vectors_test.dart
else
  DIDSA_SKETCH_VECTORS=write flutter test test/sketch_vectors_test.dart --plain-name "regenerate"
  flutter test test/sketch_vectors_test.dart
fi
