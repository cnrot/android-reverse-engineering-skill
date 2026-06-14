#!/usr/bin/env bash
# decompile-smali.sh — Decompile APK to smali via apktool (for reinforced/packed APKs)
# Usage: bash decompile-smali.sh [-o <dir>] <file.apk>
# Output: <dir>/ (AndroidManifest.xml, smali/, smali_classes*/, res/, lib/, assets/)
set -euo pipefail

OUTPUT_DIR=""
APK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTPUT_DIR="$2"; shift 2 ;;
    -o=*) OUTPUT_DIR="${1#-o=}"; shift ;;
    *) APK_FILE="$1"; shift ;;
  esac
done

if [[ -z "$APK_FILE" ]]; then
  echo "Usage: bash decompile-smali.sh [-o <dir>] <file.apk>"
  exit 1
fi

if [[ ! -f "$APK_FILE" ]]; then
  echo "ERROR: File not found: $APK_FILE"
  exit 1
fi

# Resolve apktool: check env var, local jar, or PATH
APKTOOL="${APKTOOL_JAR:-}"
if [[ -z "$APKTOOL" ]]; then
  # Check project tools directory
  if [[ -f "tools/apktool_3.0.2.jar" ]]; then
    APKTOOL="tools/apktool_3.0.2.jar"
  elif [[ -f "apktool.jar" ]]; then
    APKTOOL="apktool.jar"
  elif command -v apktool &>/dev/null; then
    APKTOOL="apktool"
  else
    echo "ERROR: apktool not found. Set APKTOOL_JAR env var, place apktool.jar in tools/, or install apktool in PATH."
    exit 1
  fi
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  # Derive output dir from APK filename (sanitize non-ASCII)
  BASENAME=$(basename "$APK_FILE" .apk | tr -dc '[:alnum:]_-' | sed 's/[^[:alnum:]_-]/_/g')
  OUTPUT_DIR="${BASENAME}-smali"
fi

echo "=== Smali Decompiling: $APK_FILE ==="
echo "Output directory: $OUTPUT_DIR"

if [[ "$APKTOOL" == *.jar ]]; then
  APKTOOL_CMD=(java -jar "$APKTOOL")
else
  APKTOOL_CMD=("$APKTOOL")
fi

"${APKTOOL_CMD[@]}" d -f "$APK_FILE" -o "$OUTPUT_DIR" 2>&1

echo
echo "=== Smali Decompilation Complete ==="
echo
echo "Next steps:"
echo "  1. Scan for shell residuals: bash <skill>/scripts/scan-shell.sh $OUTPUT_DIR"
echo "  2. Clean shell residuals:    bash <skill>/scripts/clean-shell.sh $OUTPUT_DIR"
echo "  3. Modify smali as needed in: $OUTPUT_DIR/smali*/"
echo "  4. Rebuild:                bash <skill>/scripts/build-apk.sh $OUTPUT_DIR"
