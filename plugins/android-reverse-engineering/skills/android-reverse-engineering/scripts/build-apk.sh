#!/usr/bin/env bash
# build-apk.sh — Rebuild APK from smali source + sign
# Supports: debug/release signing, auto keystore generation, build validation
# CRITICAL: ALWAYS clears source/build before rebuild to prevent old dex reuse
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_errors.sh"

SMALI_DIR="${1:-}"
OUTPUT_APK=""
KEYSTORE=""
KEYSTORE_PASS=""
KEYSTORE_ALIAS=""
SIGN_MODE="debug"

echo "[build-apk] ALWAYS clearing source/build cache first..."
rm -rf "$SMALI_DIR/build" 2>/dev/null || true
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT_APK="$2"; shift 2 ;;
    -o=*) OUTPUT_APK="${1#-o=}"; shift ;;
    -k) KEYSTORE="$2"; shift 2 ;;
    -k=*) KEYSTORE="${1#-k=}"; shift ;;
    -p) KEYSTORE_PASS="$2"; shift 2 ;;
    -p=*) KEYSTORE_PASS="${1#-p=}"; shift ;;
    -a) KEYSTORE_ALIAS="$2"; shift 2 ;;
    -a=*) KEYSTORE_ALIAS="${1#-a=}"; shift ;;
    --release) SIGN_MODE="release"; shift ;;
    --help|-h)
      echo "Usage: build-apk.sh [OPTIONS] <smali-dir>"
      echo "Options:"
      echo "  -o <apk>         Output APK path (default: output/<dir>-signed.apk)"
      echo "  -k <keystore>    Keystore file (default: tools/debug.keystore or debug.keystore)"
      echo "  -p <password>    Keystore password (default: android)"
      echo "  -a <alias>       Key alias (default: debug)"
      echo "  --release        Sign for release (no debug key auto-gen)"
      exit 0
      ;;
    *) shift ;;
  esac
done

_validate_input "$SMALI_DIR" "smali-directory"
if [[ ! -d "$SMALI_DIR" ]]; then
  _fail 1 "smali-directory" "Not a directory: $SMALI_DIR"
fi

# Check for AndroidManifest.xml (required for apktool build)
if [[ ! -f "$SMALI_DIR/AndroidManifest.xml" ]]; then
  _fail 1 "smali-directory" "No AndroidManifest.xml in $SMALI_DIR — not a valid apktool source directory"
fi

# Resolve apktool
_find_apktool

# Resolve output path
if [[ -z "$OUTPUT_APK" ]]; then
  mkdir -p output
  BASENAME=$(basename "$SMALI_DIR")
  OUTPUT_APK="output/${BASENAME}.apk"
fi

# Resolve keystore
if [[ -z "$KEYSTORE" ]]; then
  for candidate in "tools/debug.keystore" "debug.keystore"; do
    if [[ -f "$candidate" ]]; then
      KEYSTORE="$candidate"
      break
    fi
  done
fi
if [[ -z "$KEYSTORE" ]] && [[ "$SIGN_MODE" == "debug" ]]; then
  _warn "keystore" "No keystore found — generating debug.keystore"
  keytool -genkey -v -keystore debug.keystore -alias debug \
    -keyalg RSA -keysize 2048 -validity 365 \
    -storepass android -keypass android \
    -dname "CN=Debug, OU=Debug, O=Debug, L=Debug, ST=Debug, C=CN" 2>/dev/null || {
    _fail 3 "keytool" "Failed to generate debug keystore. Install JDK or provide keystore with -k."
  }
  KEYSTORE="debug.keystore"
fi

[[ -z "$KEYSTORE_PASS" ]] && KEYSTORE_PASS="android"
[[ -z "$KEYSTORE_ALIAS" ]] && KEYSTORE_ALIAS="debug"

# --- Step 1: Build with apktool ---
echo "=== Build: $SMALI_DIR ==="
UNSIGNED="${OUTPUT_APK%.apk}-unsigned.apk"

if [[ "$APKTOOL" == *.jar ]]; then
  if ! java -jar "$APKTOOL" b "$SMALI_DIR" -o "$UNSIGNED" 2>&1; then
    _fail 3 "apktool" "apktool build failed. Check smali for syntax errors: $SMALI_DIR"
  fi
else
  if ! "$APKTOOL" b "$SMALI_DIR" -o "$UNSIGNED" 2>&1; then
    _fail 3 "apktool" "apktool build failed for: $SMALI_DIR"
  fi
fi

if [[ ! -f "$UNSIGNED" ]]; then
  _fail 3 "apktool" "apktool reported success but output APK not found: $UNSIGNED"
fi

_ok "apktool build" "$UNSIGNED ($(du -h "$UNSIGNED" 2>/dev/null | cut -f1 || echo 'unknown'))"

# --- Step 2: Sign ---
if [[ -n "$KEYSTORE" ]] && [[ -f "$KEYSTORE" ]]; then
  SIGNED="${OUTPUT_APK%.apk}-signed.apk"
  echo "=== Sign: $KEYSTORE ==="

  jarsigner -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" \
    -keypass "$KEYSTORE_PASS" -signedjar "$SIGNED" "$UNSIGNED" "$KEYSTORE_ALIAS" 2>&1 || {
    _fail 3 "jarsigner" "Signing failed. Check keystore password and alias."
  }

  rm -f "$UNSIGNED" 2>/dev/null
  _ok "jarsigner sign" "$SIGNED ($(du -h "$SIGNED" 2>/dev/null | cut -f1 || echo 'unknown'))"

  # Basic validation: APK should be > 100KB after signing
  size=$(stat -c%s "$SIGNED" 2>/dev/null || stat -f%z "$SIGNED" 2>/dev/null || echo 0)
  if [[ "$size" -lt 102400 ]]; then
    _warn "validation" "Signed APK is unusually small: $size bytes — verify content"
  fi

  # Check if manifest is parseable (quick sanity check)
  if command -v unzip &>/dev/null; then
    if ! unzip -p "$SIGNED" AndroidManifest.xml 2>/dev/null | head -c 10 | grep -q 'PK\|<'; then
      _warn "validation" "Cannot read AndroidManifest.xml from signed APK — possible corruption"
    fi
  fi

  FINAL_APK="$SIGNED"
else
  _warn "sign" "No keystore — APK is unsigned: $UNSIGNED"
  FINAL_APK="$UNSIGNED"
fi

echo
_report_summary "Build Complete" "$FINAL_APK"

# Print install hint
if command -v adb &>/dev/null; then
  echo "ACTION:install-apk.sh $FINAL_APK [-s <device>] [-p <package>] [-a <activity>]"
fi
exit 0
