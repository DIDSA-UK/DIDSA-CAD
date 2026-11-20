#!/usr/bin/env bash
# Vectors for the sketch rigidity analysis (docs/sketch-rigidity-spec.md, section 6).
#
#   tools/sketch_vectors/export_rigidity.sh            # (re)writes docs/sketch-rigidity-vectors.json, then checks it
#   tools/sketch_vectors/export_rigidity.sh --check    # exits 1 if a regeneration differs from the committed file, or a case
#                                                      # does not reproduce from the file alone
#
# The generator and the check are client/test/sketch_rigidity_vectors_test.dart (the cases are
# client/test/support/sketch_rigidity_cases.dart); the full client suite runs the check too.
set -euo pipefail
cd "$(dirname "$0")/../../client"
if [ "${1:-}" != "--check" ]; then
  DIDSA_RIGIDITY_VECTORS=write flutter test test/sketch_rigidity_vectors_test.dart --plain-name "regenerate"
fi
flutter test test/sketch_rigidity_vectors_test.dart
