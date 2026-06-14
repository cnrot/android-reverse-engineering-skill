#!/usr/bin/env bash
# install-apk.sh — Install APK, launch, and verify no crashes
# Auto-detects package/activity, handles multi-device, retry logic
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_errors.sh"

APK_FILE="${1:-}"
ADB_DEVICE=""
PACKAGE=""
LAUNCH_ACTIVITY=""
WAIT_SECONDS=8

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) ADB_DEVICE="$2"; shift 2 ;;
    -s=*) ADB_DEVICE="${1#-s=}"; shift ;;
    -p) PACKAGE="$2"; shift 2 ;;
    -p=*) PACKAGE="${1#-p=}"; shift ;;
    -a) LAUNCH_ACTIVITY="$2"; shift 2 ;;
    -a=*) LAUNCH_ACTIVITY="${1#-a=}"; shift ;;
    -w) WAIT_SECONDS="$2"; shift 2 ;;
    -w=*) WAIT_SECONDS="${1#-w=}"; shift ;;
    --help|-h)
      echo "Usage: install-apk.sh [OPTIONS] <signed.apk>"
      echo "Options:"
      echo "  -s <device>    ADB device serial (127.0.0.1:7555 for MuMu)"
      echo "  -p <package>   Package name (auto-detected if omitted)"
      echo "  -a <activity>  Launch activity (auto-detected if omitted)"
      echo "  -w <seconds>   Wait time after launch (default: 8)"
      exit 0
      ;;
    *) shift ;;
  esac
done

_validate_input "$APK_FILE" "apk-file"

_find_adb

# Handle multi-device case
if [[ -z "$ADB_DEVICE" ]]; then
  device_count=$("$ADB" devices 2>/dev/null | grep -c "device$" || echo 0)
  if [[ "$device_count" -eq 0 ]]; then
    _fail 1 "adb" "No devices connected. Start emulator or connect device, then retry."
  elif [[ "$device_count" -gt 1 ]]; then
    _fail 1 "adb" "Multiple devices ($device_count). Specify device with -s <serial>:"
    "$ADB" devices 2>/dev/null | grep "device$" | head -10
    exit 1
  fi
fi

ADB_CMD=("$ADB")
[[ -n "$ADB_DEVICE" ]] && ADB_CMD+=(-s "$ADB_DEVICE")

# Auto-detect package from APK
if [[ -z "$PACKAGE" ]]; then
  _find_tool AAPT aapt "" "aapt" "aapt2" || true
  if [[ -n "$AAPT" ]]; then
    PACKAGE=$("$AAPT" dump badging "$APK_FILE" 2>/dev/null | grep "package: name=" | head -1 | sed "s/.*name='\([^']*\)'.*/\1/" || echo "")
    if [[ -z "$PACKAGE" ]] && command -v aapt2 &>/dev/null; then
      PACKAGE=$(aapt2 dump badging "$APK_FILE" 2>/dev/null | grep "package: name=" | head -1 | sed "s/.*name='\([^']*\)'.*/\1/" || echo "")
    fi
  fi
  if [[ -z "$PACKAGE" ]]; then
    # Fallback: try to read from AndroidManifest in APK using unzip
    if command -v unzip &>/dev/null; then
      PACKAGE=$(unzip -p "$APK_FILE" AndroidManifest.xml 2>/dev/null | grep -ao 'package="[^"]*"' | head -1 | sed 's/package="//;s/"//' || echo "")
    fi
  fi
  if [[ -z "$PACKAGE" ]]; then
    _warn "package" "Cannot auto-detect package from $APK_FILE. Provide with -p <package>"
  fi
fi

# Auto-detect launch activity
if [[ -z "$LAUNCH_ACTIVITY" ]] && [[ -n "$PACKAGE" ]]; then
  if [[ -n "${AAPT:-}" ]]; then
    LAUNCH_ACTIVITY=$("$AAPT" dump badging "$APK_FILE" 2>/dev/null | grep "launchable-activity" | head -1 | sed "s/.*name='\([^']*\)'.*/\1/" || echo "")
  fi
  if [[ -z "$LAUNCH_ACTIVITY" ]]; then
    # Fallback: try common patterns
    LAUNCH_ACTIVITY="${PACKAGE}.MainActivity"
    _warn "activity" "Cannot auto-detect launch activity. Trying: $LAUNCH_ACTIVITY"
  fi
fi

# --- Execute ---
echo "=== Install & Test ==="
echo "APK:      $APK_FILE"
[[ -n "$ADB_DEVICE" ]] && echo "Device:   $ADB_DEVICE"
[[ -n "$PACKAGE" ]] && echo "Package:  $PACKAGE"
[[ -n "$LAUNCH_ACTIVITY" ]] && echo "Activity: $LAUNCH_ACTIVITY"
echo

# Step 1: Force-stop existing
if [[ -n "$PACKAGE" ]]; then
  "${ADB_CMD[@]}" shell am force-stop "$PACKAGE" 2>/dev/null || _warn "force-stop" "Could not force-stop $PACKAGE (may not be installed)"
fi

# Step 2: Install
if ! "${ADB_CMD[@]}" install -r "$APK_FILE" 2>&1; then
  _fail 3 "install" "APK installation failed. Check device connection and available storage."
fi
_ok "Installed"

# Step 3: Launch
if [[ -n "$PACKAGE" ]] && [[ -n "$LAUNCH_ACTIVITY" ]]; then
  # Clear logcat for clean crash detection
  "${ADB_CMD[@]}" logcat -c 2>/dev/null || true

  if ! "${ADB_CMD[@]}" shell am start -n "$PACKAGE/$LAUNCH_ACTIVITY" 2>&1; then
    _fail 3 "launch" "Failed to start $PACKAGE/$LAUNCH_ACTIVITY"
  fi
  _ok "Launched" "$PACKAGE/$LAUNCH_ACTIVITY"

  # Step 4: Wait and check for crashes
  echo "  Waiting ${WAIT_SECONDS}s for crash detection..."
  sleep "$WAIT_SECONDS"

  # Check for fatal exceptions
  fatals=$("${ADB_CMD[@]}" logcat -d -s AndroidRuntime:E 2>/dev/null | grep -c "FATAL EXCEPTION" || echo 0)

  # Check for native crashes (tombstones)
  native_crash=$("${ADB_CMD[@]}" logcat -d 2>/dev/null | grep -c "signal.*(SIGABRT\|signal.*(SIGSEGV\|DEBUG.*pid:" || echo 0)

  # Check for ANR
  anr=$("${ADB_CMD[@]}" logcat -d -s ActivityManager:E 2>/dev/null | grep -c "ANR in" || echo 0)

  if [[ "$fatals" -gt 0 ]]; then
    _error 4 "crash" "FATAL: $fatals Java crash(es) detected"
    echo "--- Crash Log ---"
    "${ADB_CMD[@]}" logcat -d -s AndroidRuntime:E 2>/dev/null | tail -30
    exit 4
  elif [[ "$native_crash" -gt 0 ]]; then
    _error 4 "native" "$native_crash native crash signal(s) detected"
    exit 4
  elif [[ "$anr" -gt 0 ]]; then
    _error 4 "anr" "$anr ANR (Application Not Responding) detected"
    exit 4
  else
    _ok "No crashes" "Java crash: $fatals, native: $native_crash, ANR: $anr"
  fi
else
  _warn "skip" "Cannot launch: missing package or activity. APK installed but not tested."
fi

echo
_report_summary "Test Complete" "App installed and launched successfully."
exit 0
