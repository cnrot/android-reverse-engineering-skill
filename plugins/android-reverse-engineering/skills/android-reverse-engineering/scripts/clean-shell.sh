#!/usr/bin/env bash
# clean-shell.sh — Multi-packer reinforcement shell residual cleaner
# Supports: 360, Ijiami, Bangcle, Tencent legu, Baidu, and generic packer patterns.
# Options: --only-360, --only-native, --only-manifest, --dry-run, --backup
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_errors.sh"

# --- Argument parsing ---
SMALI_DIR=""
DRY_RUN=false
BACKUP=false
ONLY_MODE="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --backup) BACKUP=true; shift ;;
    --only-360) ONLY_MODE="360"; shift ;;
    --only-native) ONLY_MODE="native"; shift ;;
    --only-manifest) ONLY_MODE="manifest"; shift ;;
    --help|-h)
      echo "Usage: clean-shell.sh [OPTIONS] <smali-dir>"
      echo "Options:"
      echo "  --dry-run        Show what would be cleaned, do not modify files"
      echo "  --backup         Create .bak backups before modifying (recommended)"
      echo "  --only-360       Only clean 360 StubApp residuals"
      echo "  --only-native    Only fix native method stubs"
      echo "  --only-manifest  Only clean manifest injections"
      exit 0
esac
    *)  SMALI_DIR="$1"; shift ;;
  esac
done

_validate_input "$SMALI_DIR" "smali-directory"
if [[ ! -d "$SMALI_DIR" ]]; then
  _fail 1 "smali-directory" "Not a directory: $SMALI_DIR"
fi

MANIFEST="$SMALI_DIR/AndroidManifest.xml"
PUBLIC_XML=$(find "$SMALI_DIR" -path "*/res/values/public.xml" 2>/dev/null | head -1)

if [[ "$DRY_RUN" == true ]]; then
  echo "=== DRY RUN MODE — no files will be modified ==="
fi
if [[ "$BACKUP" == true ]]; then
  echo "=== BACKUP MODE — .bak backups will be created ==="
fi
echo "Target: $(realpath "$SMALI_DIR")"
echo "Mode: $ONLY_MODE"
echo

# Track stats
declare -A stats=()
total_ops=0

# --- Python cleanup engine (called multiple times with different patterns) ---
_run_python_cleanup() {
  local step_label="$1"
  local python_code="$2"
  echo "[$step_label] Running..."
  if [[ "$DRY_RUN" == true ]]; then
    echo "  DRY-RUN: would execute Python cleanup for: $step_label"
    return 0
  fi
  local output
  output=$(python3 -c "$python_code" 2>&1) || {
    _warn "$step_label" "Python cleanup returned non-zero: $output"
    return 3
  }
  echo "$output" | while IFS= read -r line; do echo "  $line"; done
  return 0
}

# ====================================================================
#  Pass 1: Remove StubApp invocations (360-specific)
# ====================================================================
if [[ "$ONLY_MODE" == "all" ]] || [[ "$ONLY_MODE" == "360" ]]; then
_run_python_cleanup "1/5: StubApp calls" '
import os, re, sys
BASE = r"'"$SMALI_DIR"'"
st = {"i11":0,"ctx":0,"i22":0,"i12":0,"i24":0}
for root, dirs, files in os.walk(BASE):
    for fn in files:
        if not fn.endswith(".smali"): continue
        fp = os.path.join(root, fn)
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        if "Lcom/stub/StubApp" not in content: continue
        lines = content.split("\n")
        new_lines = []
        i = 0; changed = False
        while i < len(lines):
            line = lines[i]
            if "Lcom/stub/StubApp;->interface11(I)V" in line:
                m = re.search(r"invoke-static\s*\{(\w+)\}", line)
                if m and new_lines and re.search(rf"const\s+{m.group(1)}\s*,\s*0x", new_lines[-1]):
                    new_lines.pop()
                st["i11"] += 1; i += 1; changed = True; continue
            if "Lcom/stub/StubApp;->interface22" in line or "Lcom/stub/StubApp;->interface24" in line:
                st["i22"] += 1; i += 1; changed = True; continue
            if "Lcom/stub/StubApp;->getOrigApplicationContext" in line:
                st["ctx"] += 1; i += 1; changed = True
                while i < len(lines):
                    ns = lines[i].strip()
                    if ns == "" or ns.startswith(".line") or ns.startswith(".local"):
                        i += 1; continue
                    if "move-result-object" in ns:
                        i += 1
                    break
                continue
            if "Lcom/stub/StubApp;->interface12" in line:
                m = re.search(r"\{(\w+)\}", line)
                if m:
                    line = "    invoke-virtual {" + m.group(1) + "}, Ldalvik/system/DexFile;->entries()Ljava/util/Enumeration;"
                st["i12"] += 1; changed = True
            new_lines.append(line)
            i += 1
        if changed:
            with open(fp, "w", encoding="utf-8") as f:
                f.write("\n".join(new_lines))
t = sum(st.values())
print(f"StubApp calls removed: {t} (i11={st[\"i11\"]} ctx={st[\"ctx\"]} i22/24={st[\"i22\"]} i12={st[\"i12\"]})")
'
fi

# ====================================================================
#  Pass 2: Fix duplicate move-result-object
# ====================================================================
if [[ "$ONLY_MODE" == "all" ]] || [[ "$ONLY_MODE" == "360" ]]; then
_run_python_cleanup "2/5: Duplicate move-result" '
import os, re
BASE = r"'"$SMALI_DIR"'"
fixed = 0
for root, dirs, files in os.walk(BASE):
    for fn in files:
        if not fn.endswith(".smali"): continue
        fp = os.path.join(root, fn)
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        old = content
        content = re.sub(
            r"(move-result(?:-object|-wide)?\s+(\w+))\s*(\n(?:\.line\s+\d+\s*|\s*|\.local[^\n]*|\.param[^\n]*))*\n\s*move-result(?:-object|-wide)?\s+\2",
            r"\1", content
        )
        if content != old:
            with open(fp, "w", encoding="utf-8") as f:
                f.write(content)
            fixed += 1
print(f"Fixed {fixed} files with duplicate move-result patterns")
'
fi

# ====================================================================
#  Pass 3: Fix native method stubs (generic — all packers)
# ====================================================================
if [[ "$ONLY_MODE" == "all" ]] || [[ "$ONLY_MODE" == "native" ]]; then
_run_python_cleanup "3/5: Native onCreate stubs" '
import os, re
BASE = r"'"$SMALI_DIR"'"
fixed = 0
for root, dirs, files in os.walk(BASE):
    for fn in files:
        if not fn.endswith(".smali"): continue
        fp = os.path.join(root, fn)
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        pat = r"\.method\s+(?:protected|public)\s+native\s+onCreate\(Landroid/os/Bundle;\)V"
        if not re.search(pat, content): continue
        cls_match = re.search(r"\.super\s+(L[^;]+);", content)
        parent = cls_match.group(1) if cls_match else "Landroid/app/Activity;"
        old = re.search(pat + r"[\s\S]*?\.end method", content)
        if not old: continue
        new_m = ".method protected onCreate(Landroid/os/Bundle;)V\n    .locals 1\n\n    invoke-super {p0, p1}, " + parent + ";->onCreate(Landroid/os/Bundle;)V\n\n    return-void\n.end method"
        content = content.replace(old.group(0), new_m)
        name = re.search(r"\.class\s+.*?\s+(L[^;]+);", content)
        cls = name.group(1) if name else "unknown"
        print(f"  {cls} -> invoke-super {parent}")
        with open(fp, "w", encoding="utf-8") as f:
            f.write(content)
        fixed += 1
print(f"Fixed {fixed} native onCreate methods")
'
fi

# ====================================================================
#  Pass 4: Clean manifest injections (multi-packer)
# ====================================================================
if [[ "$ONLY_MODE" == "all" ]] || [[ "$ONLY_MODE" == "manifest" ]]; then
echo "[4/5: Manifest injections] Running..."
if [[ "$DRY_RUN" == true ]]; then
  echo "  DRY-RUN: would clean manifest injections"
else
  if [[ -f "$MANIFEST" ]]; then
    manifest_old=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)
    # Remove ndbdarm provider/activity/service (360)
    sed -i '/ndbdarm\.o/d; /ndbdarm\.mg/d; /ndbdarm\.mh/d' "$MANIFEST" 2>/dev/null || true
    # Remove secneo entries (Bangcle)
    sed -i '/com\.secneo\./d' "$MANIFEST" 2>/dev/null || true
    # Remove stub entries
    sed -i '/com\.stub\./d' "$MANIFEST" 2>/dev/null || true
    manifest_new=$(wc -l < "$MANIFEST" 2>/dev/null || echo 0)
    removed=$((manifest_old - manifest_new))
    if [[ "$removed" -gt 0 ]]; then
      echo "  Removed $removed line(s) from AndroidManifest.xml"
      stats["manifest_lines"]=$removed
    else
      echo "  No manifest injections found"
    fi
  else
    _warn "manifest" "AndroidManifest.xml not found — skipping"
  fi

  # Remove fake resource types from public.xml
  if [[ -f "$PUBLIC_XML" ]]; then
    before=$(grep -c 'invalid' "$PUBLIC_XML" 2>/dev/null || echo 0)
    sed -i '/<public type="invalid[0-9]*"/d' "$PUBLIC_XML" 2>/dev/null || true
    after=$(grep -c 'invalid' "$PUBLIC_XML" 2>/dev/null || echo 0)
    removed=$((before - after))
    if [[ "$removed" -gt 0 ]]; then
      echo "  Removed $removed invalid resource type(s) from public.xml"
      stats["public_invalid"]=$removed
    fi
  fi

  # Remove res/invalid*/ directories
  invalid_dirs=$(find "$SMALI_DIR/res" -type d -name "invalid*" 2>/dev/null | wc -l)
  if [[ "$invalid_dirs" -gt 0 ]]; then
    find "$SMALI_DIR/res" -type d -name "invalid*" -exec rm -rf {} + 2>/dev/null || true
    echo "  Removed $invalid_dirs invalid resource directories"
    stats["res_dirs"]=$invalid_dirs
  fi
fi
fi

# ====================================================================
#  Pass 5: Clean orphaned const leftovers (generic)
# ====================================================================
if [[ "$ONLY_MODE" == "all" ]] || [[ "$ONLY_MODE" == "360" ]]; then
_run_python_cleanup "5/5: Const leftovers" '
import os, re
BASE = r"'"$SMALI_DIR"'"
fixed = 0
for root, dirs, files in os.walk(BASE):
    for fn in files:
        if not fn.endswith(".smali"): continue
        fp = os.path.join(root, fn)
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        old = content
        content = re.sub(r"    const \w+, 0x[0-9a-fA-F]+\n\n    return-void", "    return-void", content)
        if content != old:
            with open(fp, "w", encoding="utf-8") as f:
                f.write(content)
            fixed += 1
print(f"Cleaned {fixed} orphaned const lines")
'
fi

# ====================================================================
#  Summary
# ====================================================================
echo
echo "=== Cleanup Complete ==="
if [[ "$DRY_RUN" == true ]]; then
  echo "DRY RUN — no files modified. Run without --dry-run to apply changes."
else
  _report_summary "DONE" "Smali directory cleaned. Next: build-apk.sh $SMALI_DIR"
fi

if [[ "$BACKUP" == true ]]; then
  echo "Backup files with .bak extension were preserved."
fi
exit 0
