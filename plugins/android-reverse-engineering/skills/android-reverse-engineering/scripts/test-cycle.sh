#!/usr/bin/env bash
# test-cycle.sh — Full modify→build→sign→install→test loop
# Single command for rapid reverse-engineering iteration.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_errors.sh"

SMALI_DIR="${1:-}"
ADB_DEVICE=""
PACKAGE=""
LAUNCH_ACTIVITY=""
EXTRA_BUILD_ARGS=()
TIMEOUT_MINUTES=5

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) ADB_DEVICE="$2"; shift 2 ;;
    -s=*) ADB_DEVICE="${1#-s=}"; shift ;;
    -p) PACKAGE="$2"; shift 2 ;;
    -p=*) PACKAGE="${1#-p=}"; shift ;;
    -a) LAUNCH_ACTIVITY="$2"; shift 2 ;;
    -a=*) LAUNCH_ACTIVITY="${1#-a=}"; shift ;;
    --timeout) TIMEOUT_MINUTES="$2"; shift 2 ;;
    --timeout=*) TIMEOUT_MINUTES="${1#--timeout=}"; shift ;;
    -k) EXTRA_BUILD_ARGS+=(-k "$2"); shift 2 ;;
    --release) EXTRA_BUILD_ARGS+=(--release); shift ;;
    --help|-h)
      echo "Usage: test-cycle.sh <smali-dir> [-s <device>] [-p <package>] [-a <activity>]"
      echo "Options:"
      echo "  -s <device>    ADB device serial"
      echo "  -p <package>   App package name"
      echo "  -a <activity>  Launch activity"
      echo "  --timeout <N>  Max build minutes (default: 5)"
      echo "  -k <keystore>  Custom keystore"
      echo "  --release      Release mode signing"
      exit 0
      ;;
    *) shift ;;
  esac
done

_validate_input "$SMALI_DIR" "smali-directory"

# Collect install args for forwarding
INSTALL_ARGS=()
[[ -n "$ADB_DEVICE" ]] && INSTALL_ARGS+=(-s "$ADB_DEVICE")
[[ -n "$PACKAGE" ]] && INSTALL_ARGS+=(-p "$PACKAGE")
[[ -n "$LAUNCH_ACTIVITY" ]] && INSTALL_ARGS+=(-a "$LAUNCH_ACTIVITY")

echo "========================================="
echo "  Android RE Test Cycle"
echo "  Source: $SMALI_DIR"
echo "  Device: ${ADB_DEVICE:-auto}"
echo "  Package: ${PACKAGE:-auto-detect}"
echo "========================================="
echo

# --- Step 1: Build & Sign ---
echo "[1/3: Build & Sign]"
BUILD_START=$SECONDS

if ! bash "$SCRIPT_DIR/build-apk.sh" "$SMALI_DIR" "${EXTRA_BUILD_ARGS[@]}"; then
  _fail 3 "build" "Build failed. Check smali for syntax errors: $SMALI_DIR"
fi

BUILD_TIME=$((SECONDS - BUILD_START))
_ok "Build completed in ${BUILD_TIME}s"

# Find the built APK
SIGNED_APK=$(ls -t output/*-signed.apk 2>/dev/null | head -1)
if [[ -z "$SIGNED_APK" ]]; then
  SIGNED_APK=$(ls -t output/*.apk 2>/dev/null | head -1)
fi
if [[ -z "$SIGNED_APK" ]]; then
  _fail 3 "build" "Build succeeded but cannot find output APK in output/"
fi
echo "APK: $SIGNED_APK"

# --- Step 2: Install & Test ---
echo
echo "[2/3: Install & Test]"

if ! bash "$SCRIPT_DIR/install-apk.sh" "$SIGNED_APK" "${INSTALL_ARGS[@]}"; then
  ret=$?
  if [[ $ret -eq 4 ]]; then
    # Crash detected — try to take screenshot for debugging
    if [[ -n "$ADB_DEVICE" ]]; then
      SCREENSHOT="crash_$(date +%H%M%S).png"
      "$ADB" -s "$ADB_DEVICE" exec-out screencap -p > "$SCREENSHOT" 2>/dev/null && \
        echo "Crash screenshot saved: $SCREENSHOT" || true
    fi
    _fail 4 "test" "App crashed after installation. Check smali modifications."
  else
    _fail 3 "install" "Install/launch failed (exit code: $ret)"
  fi
fi

TOTAL_TIME=$((SECONDS - BUILD_START))
echo
echo "[3/3: Complete - ${TOTAL_TIME}s total]"
_report_summary "PASS" "App built, installed, launched, and verified with no crashes."
exit 0
