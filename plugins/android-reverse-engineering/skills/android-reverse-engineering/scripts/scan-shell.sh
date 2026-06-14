#!/usr/bin/env bash
# scan-shell.sh — Multi-packer reinforcement shell residual scanner
# Detects 360, Tencent legu, Baidu, Ijiami, Bangcle, Alibaba, NetEase, and more.
# Structured output with severity levels and suggested remediation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_errors.sh"

SMALI_DIR="${1:-}"
_validate_input "$SMALI_DIR" "smali-directory"

if [[ ! -d "$SMALI_DIR" ]]; then
  _fail 1 "smali-directory" "Not a directory: $SMALI_DIR"
fi

MANIFEST="$SMALI_DIR/AndroidManifest.xml"
if [[ ! -f "$MANIFEST" ]]; then
  _warn "scan" "AndroidManifest.xml not found in $SMALI_DIR — some checks skipped"
fi

echo "=== Multi-Packer Shell Scanner ==="
echo "Target: $(realpath "$SMALI_DIR")"
echo

declare -A findings=()
severity_total=0
has_any=false
SHELL_SUBTYPE="unknown"

# --- Helper: count smali patterns ---
_count_smali() {
  find "$SMALI_DIR" -name "*.smali" -exec grep -l "$1" {} \; 2>/dev/null | wc -l
}

_count_lines() {
  grep -r "$1" "$SMALI_DIR" --include="*.smali" -c 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}'
}

# ====================================================================
#  Layer 1: Known packer/residual signatures
# ====================================================================
echo "--- Packer Signatures ---"

# 360 (Qihoo) — StubApp + ndbdarm
stub_count=$(_count_smali "Lcom/stub/StubApp;")
ndb_count=$(find "$SMALI_DIR" -path "*/ndbdarm/*" -name "*.smali" 2>/dev/null | wc -l)
if [[ "$stub_count" -gt 0 ]]; then
  findings["360:StubApp_residual"]="$stub_count files"
  _warn "360" "StubApp references: $stub_count files — residual after de-shelling"
  has_any=true
elif has_any_360=$(grep -rl "com/qihoo" "$SMALI_DIR" --include="*.smali" 2>/dev/null | wc -l) && [[ "$has_any_360" -gt 0 ]]; then
  findings["360:qihoo_refs"]="$has_any_360 files"
  _warn "360" "Qihoo/360 references found"
  has_any=true
fi

# Tencent legu
legu_count=$(_count_smali "libshella-\|libshellx-\|libtup\|liblegus")
legu_dex=$(_count_smali "com/tencent/StubShell\|com/tencent/bugly")
if [[ "$legu_count" -gt 0 ]] || [[ "$legu_dex" -gt 0 ]]; then
  findings["Tencent_legu"]="$legu_count lib refs, $legu_dex dex refs"
  _warn "Tencent_legu" "Tencent legu shell detected"
  has_any=true
fi

# Ijiami — libegis.so + com.ijiami
ijiami_count=$(_count_smali "com/ijiami/\|libegis")
if [[ "$ijiami_count" -gt 0 ]]; then
  findings["Ijiami"]="$ijiami_count files"
  _warn "Ijiami" "Ijiami reinforcement detected"
  has_any=true
fi

# Bangcle / SecNeo
bangcle_count=$(_count_smali "com/secneo/\|libapkprotect\|libDexHelper")
if [[ "$bangcle_count" -gt 0 ]]; then
  findings["Bangcle"]="$bangcle_count files"
  _warn "Bangcle" "Bangcle/SecNeo reinforcement detected"
  has_any=true
fi

# Alibaba
ali_count=$(_count_smali "libsgmain\|libsgsecuritybody\|com/alibaba/wireless")
if [[ "$ali_count" -gt 0 ]]; then
  findings["Alibaba"]="$ali_count files"
  _warn "Alibaba" "Alibaba security SDK detected"
  has_any=true
fi

# NetEase
netease_count=$(_count_smali "libprotectClass\|com/netease/nis")
if [[ "$netease_count" -gt 0 ]]; then
  findings["NetEase"]="$netease_count files"
  _warn "NetEase" "NetEase reinforcement detected"
  has_any=true
fi

# Baidu
baidu_count=$(_count_smali "libbaiduprotect\|com/baidu/mshield")
if [[ "$baidu_count" -gt 0 ]]; then
  findings["Baidu"]="$baidu_count files"
  _warn "Baidu" "Baidu reinforcement detected"
  has_any=true
fi

# NetQin
nq_count=$(_count_smali "libnqshield\|com/nqmobile")
if [[ "$nq_count" -gt 0 ]]; then
  findings["NetQin"]="$nq_count files"
  _warn "NetQin" "NetQin Shield detected"
  has_any=true
fi

# ====================================================================
#  Layer 2: Native method stubs (common to most packers)
# ====================================================================
echo "--- Native Method Stubs ---"
native_total=$(_count_lines "\.method.*native ")
native_oncreate=$(grep -r "native onCreate(Landroid/os/Bundle;)V" "$SMALI_DIR" --include="*.smali" -l 2>/dev/null | wc -l)
native_init=$(grep -r "native.*onCreate\|native.*\.init(" "$SMALI_DIR" --include="*.smali" -c 2>/dev/null | awk -F: '{sum+=$2} END{print sum+0}')

if [[ "$native_total" -gt 0 ]]; then
  findings["native_methods"]="$native_total total, $native_oncreate native onCreate"
  if [[ "$native_oncreate" -gt 5 ]]; then
    _warn "native" "HIGH: $native_oncreate Activities with native onCreate — must fix before rebuild"
    severity_total=$((severity_total + native_oncreate))
  elif [[ "$native_oncreate" -gt 0 ]]; then
    _warn "native" "$native_oncreate Activities with native onCreate — verify each"
    severity_total=$((severity_total + 1))
  fi
  has_any=true
else
  _ok "native" "No native method stubs"
fi

# ====================================================================
#  Layer 3: Manifest injections (fake resources, shell providers)
# ====================================================================
echo "--- Manifest Injections ---"
if [[ -f "$MANIFEST" ]]; then
  # Fake resource types (360 uses invalid16, legu uses invalid etc.)
  invalid_count=$(grep -c 'type="invalid' "$MANIFEST" 2>/dev/null || echo 0)
  if [[ "$invalid_count" -gt 0 ]]; then
    findings["manifest:invalid_types"]="$invalid_count entries"
    _warn "manifest" "$invalid_count fake resource type(s) — remove from public.xml and manifest"
    has_any=true
  fi

  # Shell providers with non-existent classes
  for shell_prov in "ndbdarm\.o" "com\.stub\." "com\.secneo\."; do
    pc=$(grep -c "$shell_prov" "$MANIFEST" 2>/dev/null || echo 0)
    if [[ "$pc" -gt 0 ]]; then
      findings["manifest:shell_provider"]="$shell_prov ($pc entries)"
      _warn "manifest" "Shell provider detected: $shell_prov — class likely removed, remove from manifest"
      has_any=true
    fi
  done
else
  _warn "manifest" "AndroidManifest.xml not found — skipping manifest checks"
fi

# ====================================================================
#  Layer 4: Anti-tampering & protection patterns
# ====================================================================
echo "--- Protection Patterns ---"

# Signature verification
sig_count=$(_count_smali "getPackageManager.*getPackageInfo\|GET_SIGNATURES\|SIGNATURE\|checkSignatures")
if [[ "$sig_count" -gt 0 ]]; then
  findings["protection:signature_check"]="$sig_count files"
  _warn "protection" "Signature verification in $sig_count files"
  has_any=true
fi

# Emulator detection
emu_count=$(_count_smali "isEmulator\|emulator\|qemu\|goldfish\|vbox\|genymotion")
if [[ "$emu_count" -gt 0 ]]; then
  findings["protection:emulator_detect"]="$emu_count files"
  _warn "protection" "Emulator detection in $emu_count files"
  has_any=true
fi

# Debug detection
debug_count=$(_count_smali "isDebuggerConnected\|Debug.isDebuggerConnected\|android/os/Debug;->isDebuggerConnected")
if [[ "$debug_count" -gt 0 ]]; then
  findings["protection:debug_detect"]="$debug_count files"
  _warn "protection" "Debugger detection in $debug_count files"
  has_any=true
fi

# Root detection (common patterns)
root_count=$(_count_smali "/su\|/system/app/Superuser\|magisk\|/sbin/su")
if [[ "$root_count" -gt 0 ]]; then
  findings["protection:root_detect"]="$root_count files"
  _warn "protection" "Root detection in $root_count files"
  has_any=true
fi

# Hook detection (Xposed, Frida, Substrate/Cydia)
hook_count=$(_count_smali "de\.robv\.android\.xposed\|XposedBridge\|XposedHelpers\|com\.saurik\.substrate\|frida")
if [[ "$hook_count" -gt 0 ]]; then
  findings["protection:hook_detect"]="$hook_count files"
  _warn "protection" "Hook framework detection (Xposed/Frida/Substrate) in $hook_count files"
  has_any=true
fi

# ====================================================================
#  Layer 5: Code integrity & obfuscation
# ====================================================================
echo "--- Code Integrity ---"

# Obfuscated single-letter packages (packer injected)
single_letter=$(find "$SMALI_DIR" -mindepth 2 -maxdepth 2 -type d -name "[a-z]" 2>/dev/null | wc -l)
if [[ "$single_letter" -gt 50 ]]; then
  findings["code:single_letter_pkgs"]="$single_letter dirs"
  _warn "code" "HIGH: $single_letter single-letter root packages — heavy obfuscation or packer injection"
  severity_total=$((severity_total + 1))
  has_any=true
elif [[ "$single_letter" -gt 10 ]]; then
  findings["code:single_letter_pkgs"]="$single_letter dirs"
  _warn "code" "$single_letter single-letter root packages — moderate obfuscation"
  has_any=true
fi

# Duplicate class references (leftover from multi-dex after packing)
dup_count=$(find "$SMALI_DIR" -name "*.smali" -exec grep -l "^\.source.*\..*" {} \; 2>/dev/null | wc -l)
# Not critical, just informational
if [[ "$dup_count" -gt 1000 ]]; then
  _warn "code" "Large corpus: $dup_count+ smali files with .source references"
fi

# ====================================================================
#  Summary and Exit
# ====================================================================
echo
echo "=== Scan Summary ==="
if [[ "$has_any" != true ]]; then
  _report_summary "CLEAN" "No reinforcement shell residuals or protection artifacts detected."
  exit 0
fi

echo
echo "Findings:"
for key in "${!findings[@]}"; do
  echo "  [$key] ${findings[$key]}"
done
echo
echo "Severity: $severity_total issues requiring attention"
echo

# Build actionable output
echo "=== Recommended Actions ==="
if [[ -n "${findings["360:StubApp_residual"]+x}" ]] || [[ "$native_oncreate" -gt 0 ]]; then
  _action "Run clean-shell.sh $SMALI_DIR to remove residual StubApp calls and fix native stubs"
fi
if [[ -n "${findings["manifest:invalid_types"]+x}" ]] || [[ -n "${findings["manifest:shell_provider"]+x}" ]]; then
  _action "Manually remove shell entries from AndroidManifest.xml and res/values/public.xml"
fi
if [[ -n "${findings["protection:signature_check"]+x}" ]]; then
  _action "Signature verification found: patch smali in ${findings["protection:signature_check"]} to return true/pass"
fi
if [[ -n "${findings["protection:emulator_detect"]+x}" ]]; then
  _action "Emulator detection: patch or remove emulator checks in ${findings["protection:emulator_detect"]} files for testing"
fi
if [[ -n "${findings["protection:debug_detect"]+x}" ]]; then
  _action "Debug detection: bypass isDebuggerConnected() checks for debugging"
fi
if [[ -n "${findings["protection:hook_detect"]+x}" ]]; then
  _action "Hook detection: if using Xposed/Frida for testing, bypass these checks"
fi

echo
_report_summary "DETECTED" "$((${#findings[@]})) issues found across ${#findings[@]} categories. Run clean-shell.sh for automated cleanup or address findings manually."
exit 5
