#!/usr/bin/env bash
# Shape-proposal vectors for the hybrid drag (docs/motion/sketch-projector-spec.md, section 13).
#
#   tools/sketch_vectors/export_shapes.sh            # (re)writes docs/motion/sketch-shape-vectors.json, then checks it
#   tools/sketch_vectors/export_shapes.sh --check    # exits 1 if a regeneration differs from the committed file, or a frame's
#                                                    # written-back positions are not the projector's answer from the file alone
#
# The generator is the "shape proposal vectors (F6)" group of client/test/sketch_controller_test.dart (it drives the app's
# own drag code on the hybrid-drag tests' fake backend); the file-only check is client/test/sketch_shape_vectors_test.dart.
# Both run in the full client suite too.
set -euo pipefail
cd "$(dirname "$0")/../../client"
if [ "${1:-}" != "--check" ]; then
  DIDSA_SHAPE_VECTORS=write flutter test test/sketch_controller_test.dart --plain-name "shape proposal vectors"
fi
flutter test test/sketch_controller_test.dart --plain-name "shape proposal vectors"
flutter test test/sketch_shape_vectors_test.dart
