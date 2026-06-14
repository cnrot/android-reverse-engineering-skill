#!/usr/bin/env bash
# _errors.sh — Shared error codes and reporting for Android reverse-engineering scripts
# Source this in other scripts: source "$(dirname "${BASH_SOURCE[0]}")/_errors.sh"
#
# Exit code convention:
#   0   Success
#   1   USER_ERROR    — bad input, file not found, invalid args
#   2   TOOL_MISSING  — required tool not installed / not in PATH
#   3   TOOL_ERROR    — tool ran but failed (apktool error, jadx crash, etc.)
#   4   VERIFY_FAIL   — post-build verification failed (crash detected, signature mismatch)
#   5   SHELL_DETECTED — reinforcement shell residuals found (scan-shell, non-fatal)
#   6   TIMEOUT       — operation timed out
#
# Output convention:
#   ERROR:<code>:<context>:<message>        — machine-readable, AI-agent parsable
#   WARN:<context>:<message>                — non-fatal warning
#   ACTION:<command-or-next-step>           — suggested recovery action
#
# All scripts in this skill should follow these conventions.

# --- Error reporting functions ---

_error() {
  local code="$1"
  local context="$2"
  local message="$3"
  echo "ERROR:${code}:${context}:${message}" >&2
}

_warn() {
  local context="$1"
  local message="$2"
  echo "WARN:${context}:${message}" >&2
}

_action() {
  local suggestion="$1"
  echo "ACTION:${suggestion}" >&2
}

_fail() {
  local code="$1"
  local context="$2"
  local message="$3"
  _error "$code" "$context" "$message"
  exit "$code"
}

# --- Tool resolution helpers ---

_find_tool() {
  # Usage: _find_tool <var-name> <cmd-name> [env-var] [fallback-path...]
  # Sets the named variable to the resolved tool path.
  local var_name="$1"
  local tool_name="$2"
  local env_var="${3:-}"
  shift 3 2>/dev/null || true

  # 1. Check env var if provided
  if [[ -n "$env_var" ]]; then
    local env_val="${!env_var}"
    if [[ -n "$env_val" ]] && { command -v "$env_val" &>/dev/null || [[ -f "$env_val" ]]; }; then
      eval "$var_name=\"$env_val\""
      return 0
    fi
  fi

  # 2. Check PATH
  if command -v "$tool_name" &>/dev/null; then
    eval "$var_name=\"$tool_name\""
    return 0
  fi

  # 3. Check fallback paths (most specific first)
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      eval "$var_name=\"$candidate\""
      return 0
    fi
  done

  # Not found
  eval "$var_name=\"\""
  return 1
}

_find_java() {
  _find_tool JAVA_CMD java "JAVA_HOME" \
    "${JAVA_HOME:+$JAVA_HOME/bin/java}" \
    "java"
  if [[ -z "$JAVA_CMD" ]]; then
    _fail 2 "java" "Java JDK 17+ required but not found. Set JAVA_HOME or install JDK 17+."
  fi
}

_find_apktool() {
  _find_tool APKTOOL apktool "APKTOOL_JAR" \
    "tools/apktool_3.0.2.jar" \
    "tools/apktool.jar" \
    "apktool.jar"
  if [[ -z "$APKTOOL" ]]; then
    _fail 2 "apktool" "apktool not found. Set APKTOOL_JAR env var, place apktool.jar in tools/, or run: install-dep.sh apktool"
  fi
}

_find_adb() {
  _find_tool ADB adb "ADB_PATH" \
    "adb" \
    "D:/Program Files/Netease/MuMu/nx_main/adb.exe"
  if [[ -z "$ADB" ]]; then
    _fail 2 "adb" "adb not found. Set ADB_PATH, install platform-tools, or run: install-dep.sh adb"
  fi
}

# Validate input file exists and is readable
_validate_input() {
  local file="$1"
  local label="${2:-input file}"
  if [[ -z "$file" ]]; then
    _fail 1 "$label" "No $label specified. Usage: $(basename "$0") <$label> [options]"
  fi
  if [[ ! -f "$file" ]]; then
    _fail 1 "$label" "$label not found: $file"
  fi
  if [[ ! -r "$file" ]]; then
    _fail 1 "$label" "$label is not readable: $file"
  fi
}

# Validate required command is available
_require_cmd() {
  local cmd="$1"
  local install_hint="${2:-install it manually}"
  if ! command -v "$cmd" &>/dev/null; then
    _fail 2 "$cmd" "'$cmd' command not found. $install_hint"
  fi
}

# --- Result reporting ---

_ok() {
  local context="$1"
  local detail="${2:-}"
  echo "[OK] $context${detail:+ — $detail}"
}

_report_summary() {
  local status="$1"
  local message="$2"
  echo
  echo "=== $status ==="
  echo "$message"
}
