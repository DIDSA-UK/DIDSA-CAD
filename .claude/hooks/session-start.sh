#!/bin/bash
# SessionStart hook: installs the Flutter SDK (client/) and the backend
# conda/micromamba environment (backend/) so a fresh Claude Code on the web
# session can immediately run `flutter test`/`flutter analyze` and `pytest`
# without manual setup. Web-only: local/desktop sessions skip this entirely.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SDK_DIR="/opt/sdks"
FLUTTER_DIR="$SDK_DIR/flutter"
MICROMAMBA_BIN="$SDK_DIR/micromamba"
MAMBA_ROOT_PREFIX="$SDK_DIR/micromamba_root"
BACKEND_ENV_NAME="didsa-backend"

mkdir -p "$SDK_DIR"

FLUTTER_STATUS=0
BACKEND_STATUS=0

# --- Flutter SDK (client/) ------------------------------------------------
# flutter_scene (client/pubspec.lock) depends on flutter_gpu APIs that only
# exist on Flutter's master channel as of this pin - see the same channel
# choice and rationale in .github/workflows/client-verify.yml.
install_flutter() {
  if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
    echo "[session-start] Cloning Flutter SDK (master channel)..."
    rm -rf "$FLUTTER_DIR"
    if ! git clone --depth 1 -b master https://github.com/flutter/flutter.git "$FLUTTER_DIR"; then
      echo "[session-start] ERROR: Flutter clone failed" >&2
      return 1
    fi
  else
    echo "[session-start] Flutter SDK already present, skipping clone."
  fi

  export PATH="$FLUTTER_DIR/bin:$PATH"

  echo "[session-start] Priming Flutter SDK (downloads Dart SDK/engine on first run)..."
  if ! flutter --version >/tmp/flutter-version.log 2>&1; then
    echo "[session-start] ERROR: flutter --version failed" >&2
    cat /tmp/flutter-version.log >&2
    return 1
  fi

  if [ -f "$REPO_DIR/client/pubspec.yaml" ]; then
    echo "[session-start] flutter pub get (client/)..."
    if ! (cd "$REPO_DIR/client" && flutter pub get >/tmp/flutter-pub-get.log 2>&1); then
      echo "[session-start] ERROR: flutter pub get failed" >&2
      cat /tmp/flutter-pub-get.log >&2
      return 1
    fi
  fi

  return 0
}

# --- Backend conda env (backend/) -----------------------------------------
install_backend_env() {
  if [ ! -x "$MICROMAMBA_BIN" ]; then
    echo "[session-start] Downloading micromamba..."
    if ! curl -fsSL -o "$MICROMAMBA_BIN" \
        "https://github.com/mamba-org/micromamba-releases/releases/latest/download/micromamba-linux-64"; then
      echo "[session-start] ERROR: micromamba download failed" >&2
      return 1
    fi
    chmod +x "$MICROMAMBA_BIN"
  else
    echo "[session-start] micromamba already present, skipping download."
  fi

  export MAMBA_ROOT_PREFIX

  if [ -d "$MAMBA_ROOT_PREFIX/envs/$BACKEND_ENV_NAME" ]; then
    echo "[session-start] Backend conda env already present, skipping create."
    return 0
  fi

  if [ ! -f "$REPO_DIR/backend/environment.yml" ]; then
    echo "[session-start] No backend/environment.yml found, skipping backend env."
    return 0
  fi

  echo "[session-start] Creating backend conda env (this can take a few minutes)..."
  if ! "$MICROMAMBA_BIN" create -y -n "$BACKEND_ENV_NAME" -f "$REPO_DIR/backend/environment.yml" \
      >/tmp/micromamba-create.log 2>&1; then
    echo "[session-start] ERROR: micromamba create failed" >&2
    cat /tmp/micromamba-create.log >&2
    return 1
  fi

  return 0
}

# Run both installs in parallel - independent toolchains, no shared state.
install_flutter &
FLUTTER_PID=$!
install_backend_env &
BACKEND_PID=$!

wait "$FLUTTER_PID" || FLUTTER_STATUS=$?
wait "$BACKEND_PID" || BACKEND_STATUS=$?

# --- Persist env for the rest of the session -------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$FLUTTER_DIR/bin:\$PATH\""
    echo "export MAMBA_ROOT_PREFIX=\"$MAMBA_ROOT_PREFIX\""
  } >> "$CLAUDE_ENV_FILE"
fi

if [ "$FLUTTER_STATUS" -ne 0 ]; then
  echo "[session-start] Flutter setup failed - client/ commands will not work until this is fixed." >&2
fi
if [ "$BACKEND_STATUS" -ne 0 ]; then
  echo "[session-start] Backend env setup failed - run 'micromamba create -y -n $BACKEND_ENV_NAME -f backend/environment.yml' manually." >&2
fi

echo "[session-start] Done. Flutter: $([ "$FLUTTER_STATUS" -eq 0 ] && echo ok || echo FAILED), Backend env: $([ "$BACKEND_STATUS" -eq 0 ] && echo ok || echo FAILED)"
echo "[session-start] Backend tests: $MICROMAMBA_BIN run -n $BACKEND_ENV_NAME python -m pytest backend/tests/ -q"

if [ "$FLUTTER_STATUS" -ne 0 ] || [ "$BACKEND_STATUS" -ne 0 ]; then
  exit 1
fi
exit 0
