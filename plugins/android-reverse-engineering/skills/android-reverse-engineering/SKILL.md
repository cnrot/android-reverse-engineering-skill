---
description: Decompile Android APK, XAPK, JAR, and AAR files using jadx or Fernflower/Vineflower. Reverse engineer Android apps, extract HTTP API endpoints (Retrofit, OkHttp, Volley), and trace call flows from UI to network layer. Use when the user wants to decompile, analyze, or reverse engineer Android packages, find API endpoints, or follow call flows. 中文触发词：反编译APK、安卓逆向、提取API、分析安卓应用、反编译安卓、逆向工程、追踪调用链、提取接口
trigger: decompile APK|decompile XAPK|reverse engineer Android|extract API|analyze Android|jadx|fernflower|vineflower|follow call flow|decompile JAR|decompile AAR|Android reverse engineering|find API endpoints|反编译APK|安卓逆向|提取API|分析安卓应用
---

# Android Reverse Engineering

Decompile Android APK, XAPK, JAR, and AAR files using jadx and Fernflower/Vineflower, trace call flows through application code and libraries, and produce structured documentation of extracted APIs. Two decompiler engines are supported — jadx for broad Android coverage and Fernflower for higher-quality output on complex Java code — and can be used together for comparison.

## Error Reporting Convention

All scripts follow a unified error reporting convention designed for AI-agent readability:

| Exit Code | Name | Meaning | Recovery |
|-----------|------|---------|----------|
| 0 | SUCCESS | Operation completed | — |
| 1 | USER_ERROR | Bad input, file missing, invalid args | Fix the command syntax |
| 2 | TOOL_MISSING | Required tool not installed | Run `install-dep.sh <tool>` |
| 3 | TOOL_ERROR | Tool execution failed | Check error output, fix smali/config |
| 4 | VERIFY_FAIL | Post-build crash/ANR/native-crash | Check smali modifications |
| 5 | SHELL_DETECTED | Shell residuals found (non-fatal) | Run `clean-shell.sh` |

**Machine-readable output markers** (on stderr):
- `ERROR:<code>:<context>:<message>` — Fatal error, blocks continuation
- `WARN:<context>:<message>` — Non-fatal warning, does not block
- `ACTION:<suggested-command>` — Proposed next step for recovery

AI agents should parse `ERROR:` and `WARN:` prefixes to understand what went wrong and `ACTION:` for remediation guidance.

## Prerequisites

This skill requires **Java JDK 17+** and **jadx** to be installed. **Fernflower/Vineflower** and **dex2jar** are optional but recommended for better decompilation quality. Run the dependency checker to verify:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/check-deps.sh
```

On Windows (PowerShell):
```powershell
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/check-deps.ps1"
```

If anything is missing, follow the installation instructions in `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/setup-guide.md`.

## Workflow

### Phase 0: Fingerprint the App (recommended before anything else)

Before installing tools or decompiling, run a fast triage to determine what
kind of app you are looking at. **Decompiling Java is mostly useless for
Flutter, React Native, Cordova/Capacitor, and Xamarin apps** — the real code
lives elsewhere. The fingerprint script tells you which.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/fingerprint.sh <file.apk|file.xapk>
```

It prints, in one screen:

- **Mobile framework** (Flutter / React Native / Cordova / Xamarin / Native Kotlin / etc.) with the file marker that triggered the verdict.
- **HTTP stack** (Retrofit, OkHttp, Ktor, Apollo, Volley) detected via DEX string scan — works even when class names are obfuscated.
- **DI / serialization** signals (Hilt, Dagger, Koin, kotlinx.serialization, Moshi, Gson, Jackson).
- **Obfuscation level** estimate based on root-level short-named packages.
- **Notable third-party SDKs** (AppsFlyer, Datadog, Sentry, Firebase, payment SDKs, support/chat SDKs, etc.).
- **Consolidated native libraries** across the base APK and all splits — XAPK split bundles often place `.so` files in `config.<abi>.apk`, not in `base.apk`.
- **Recommended next step**, which differs by framework (e.g. for Flutter the script suggests `blutter` / `strings libapp.so` rather than jadx).

If the fingerprint says the app is Flutter / RN / Cordova / Xamarin, **stop**
and switch to the framework-appropriate tooling. Phases 1–5 below assume a
native (Java/Kotlin) Android app.

### Phase 0.5: Reinforcement Shell Detection

The fingerprint script now detects common Android packing/reinforcement shells (360 Qihoo, Tencent legu, Baidu, NetQin, etc.) by scanning for:

- **Shell library markers** (libjiagu.so, libshella-*.so, libbaiduprotect.so, etc.)
- **StubApp references** in DEX strings (360 de-shelled residual)
- **Heuristic indicators**: ndbdarm obfuscated classes, excessive single-letter root packages

**If a shell is detected**, the recommended path shifts from jadx→Java to **apktool→smali**:

```
Phase 0.5 (fingerprint):  bash scripts/fingerprint.sh <file.apk>
  ↓ if shell detected
Phase 2.5 (smali decompile):  bash scripts/decompile-smali.sh <file.apk>
Phase 2.6 (scan residuals):   bash scripts/scan-shell.sh <output-dir>
Phase 2.7 (clean residuals):  bash scripts/clean-shell.sh <output-dir>
Phase 6   (build & test):     bash scripts/test-cycle.sh <source-dir>
```

For non-packed APKs, continue with the standard jadx→Java pipeline below.

**When to use smali vs jadx**:

| Situation | Path |
|---|---|
| Shell detected (360, legu, etc.) | smali pipeline (Phase 2.5–2.7) |
| App already de-shelled but has residual StubApp/native stubs | smali pipeline |
| Normal APK, no packing | jadx pipeline (Phase 2) |
| Need to modify and rebuild APK | Always use smali pipeline |

### Phase 1: Verify and Install Dependencies

Before decompiling, confirm that the required tools are available — and install any that are missing.

**Action**: Run the dependency check script.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/check-deps.sh
```

On Windows (PowerShell):
```powershell
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/check-deps.ps1"
```

The output contains machine-readable lines:
- `INSTALL_REQUIRED:<dep>` — must be installed before proceeding
- `INSTALL_OPTIONAL:<dep>` — recommended but not blocking

**If required dependencies are missing** (exit code 1), install them automatically:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.sh <dep>
```

On Windows (PowerShell):
```powershell
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.ps1" <dep>
```

The install script detects the OS and package manager, then:
- Installs without sudo when possible (downloads to `~/.local/share/`, symlinks in `~/.local/bin/`)
- Uses sudo and the system package manager when necessary (apt, dnf, pacman)
- If sudo is needed but unavailable or the user declines, it prints the exact manual command and exits with code 2 — show these instructions to the user

**Windows notes**: The PowerShell install script uses `winget`, `scoop`, or `choco` (in that order). If none are available, it downloads directly to `%USERPROFILE%\.local\share\` and adds the directory to the user's PATH. After running `install-dep.ps1`, the PATH is persisted but the current terminal session may not see it. The `check-deps.ps1` and `decompile.ps1` scripts automatically refresh PATH from the user environment, so re-running them will find newly installed tools without restarting the terminal.

**For optional dependencies**, ask the user if they want to install them. Vineflower and dex2jar are recommended for best results.

After installation, re-run `check-deps.sh` to confirm everything is in place. Do not proceed to Phase 2 until all required dependencies are OK.

### Phase 2: Decompile

Use the decompile wrapper script to process the target file. The script supports three engines: `jadx`, `fernflower`, and `both`.

**Action**: Choose the engine and run the decompile script. The script handles APK, XAPK, JAR, and AAR files.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/decompile.sh [OPTIONS] <file>
```

On Windows (PowerShell):
```powershell
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/decompile.ps1" [OPTIONS] <file>
```

For **XAPK** files (ZIP bundles containing multiple APKs, used by APKPure and similar stores): the script automatically extracts the archive, identifies all APK files inside (base + split APKs), and decompiles each one into a separate subdirectory. The XAPK manifest is copied to the output for reference.

**Split/bundled APK detection**: Some APKs are actually bundle wrappers — the outer APK contains `base.apk` plus `split_config.*.apk` files inside its resources directory. When this happens, jadx will decompile the thin wrapper and produce very few Java files. The decompile scripts automatically detect this (≤10 Java files + inner APKs present) and re-decompile `base.apk` into an `<output>/base/` subdirectory. Config-only splits (ABI, language, density) are skipped. The main decompiled source will be in `<output>/base/sources/`.

Options:
- `-o <dir>` — Custom output directory (default: `<filename>-decompiled`)
- `--deobf` — Enable deobfuscation (recommended for obfuscated apps)
- `--no-res` — Skip resources, decompile code only (faster)
- `--engine ENGINE` — `jadx` (default), `fernflower`, or `both`

**Engine selection strategy**:

| Situation | Engine |
|---|---|
| First pass on any APK | `jadx` (fastest, handles resources) |
| JAR/AAR library analysis | `fernflower` (better Java output) |
| jadx output has warnings/broken code | `both` (compare and pick best per class) |
| Complex lambdas, generics, streams | `fernflower` |
| Quick overview of a large APK | `jadx --no-res` |

When using `--engine both`, the outputs go into `<output>/jadx/` and `<output>/fernflower/` respectively, with a comparison summary at the end showing file counts and jadx warning counts. Review classes with jadx warnings in the Fernflower output for better code.

For APK files with Fernflower, the script automatically uses dex2jar as an intermediate step. dex2jar must be installed for this to work.

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/jadx-usage.md` and `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/fernflower-usage.md` for the full CLI references.

### Phase 2.5: Smali Decompilation (for reinforced/packed APKs)

When the fingerprint detects a reinforcement shell, or when you need to modify and rebuild the APK, use apktool to decompile to smali (DEX assembly) instead of jadx→Java. Smali-level editing is the only reliable way to patch reinforced APKs.

**Action**: Run the smali decompile script.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/decompile-smali.sh [-o <dir>] <file.apk>
```

The script:
- Resolves apktool from `$APKTOOL_JAR` env var, `tools/apktool_3.0.2.jar` (project local), or PATH
- Decompiles all DEX to smali (smali/, smali_classes2/ ... smali_classesN/)
- Decodes resources (res/), manifest, assets, and native libraries
- Outputs to `<filename>-smali/` by default

### Phase 2.6: Scan for Shell Residuals

After smali decompilation, scan for reinforcement shell residuals that must be cleaned before rebuilding.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/scan-shell.sh <smali-dir>
```

Detects:
- **StubApp references** (360 residual) — `Lcom/stub/StubApp;` calls in smali
- **Native method stubs** — `native onCreate` and other methods replaced by 360
- **Obfuscated shell packages** — ndbdarm, com/muhuaya, yz/local
- **Manifest injections** — fake resource types (invalid16), ndbdarm providers
- Exit code 1 if residuals found, 0 if clean.

### Phase 2.7: Clean Shell Residuals

Automatically remove 360 (Qihoo) reinforcement residuals from smali.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/clean-shell.sh <smali-dir>
```

This script performs 5 cleaning passes:
1. **Remove StubApp invocations**: `interface11(I)V`, `getOrigApplicationContext(Context)Context`, `interface22`, `interface24`, `interface12(DexFile)Enumeration` → `DexFile.entries()`
2. **Fix duplicate move-result-object**: leftover from `getOrigApplicationContext` removal when `.line` annotations separate invoke from move-result
3. **Fix native onCreate stubs**: replace `native` modifier with `invoke-super` to parent class
4. **Clean manifest injections**: remove ndbdarm.o/mg/mh entries, fake resource types (invalid16), delete res/invalid*/ directories
5. **Clean const leftovers**: remove orphaned `const vX, 0xNNNN` from removed interface11 calls

**Options**:
- `--dry-run` — Preview changes without modifying files
- `--backup` — Create .bak backups before modifying
- `--only-360` — Clean only 360 StubApp residuals
- `--only-native` — Fix only native method stubs
- `--only-manifest` — Clean only manifest injections

Supports multiple packers: 360 Qihoo, Ijiami, Bangcle/SecNeo, Tencent legu, Baidu.

**Typical results** (from real-world 360-packed 45MB APK):
| Pass | Items Cleaned |
|------|--------------|
| StubApp calls | ~294 (93 interface11 + 188 getOrigApplicationContext + 13 others) |
| Duplicate move-result | ~134 files |
| Native onCreate | 29 classes |
| Manifest entries | 3-5 entries |

### Phase 3: Analyze Structure

Navigate the decompiled output to understand the app's architecture.

**Actions**:

1. **Read AndroidManifest.xml** from `<output>/resources/AndroidManifest.xml`:
   - Identify the main launcher Activity
   - List all Activities, Services, BroadcastReceivers, ContentProviders
   - Note permissions (especially `INTERNET`, `ACCESS_NETWORK_STATE`)
   - Find the application class (`android:name` on `<application>`)

2. **Survey the package structure** under `<output>/sources/`:
   - Identify the main app package and sub-packages
   - Distinguish app code from third-party libraries
   - Look for packages named `api`, `network`, `data`, `repository`, `service`, `retrofit`, `http` — these are where API calls live

3. **Read every `BuildConfig.java`** — these are almost never obfuscated and frequently leak the highest-signal constants in the entire APK (base URLs, flavor names, build type, third-party API keys, feature flags):
   ```bash
   find <output>/sources -name BuildConfig.java -exec grep -H '=' {} \;
   ```
   Each Gradle module emits its own `BuildConfig`, so expect 1–N hits. Read all of them.

4. **Identify the architecture pattern**:
   - MVP: look for `Presenter` classes
   - MVVM: look for `ViewModel` classes and `LiveData`/`StateFlow`
   - Clean Architecture: look for `domain`, `data`, `presentation` packages
   - This informs where to look for network calls in the next phases

### Phase 3.5: Recover Kotlin Class Names (only for obfuscated Kotlin apps)

If Phase 0 reported moderate / high obfuscation **and** the app is Kotlin
(Compose / kotlin_module markers detected), run the metadata recovery
script before tracing call flows. R8 obfuscates JVM symbols but cannot
strip Kotlin metadata strings, so original FQNs leak through
`@DebugMetadata` and `@Metadata.d2`.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/recover-kotlin-names.sh \
    <output>/sources <output>/mapping
```

Then use the lookup helper instead of plain grep — every hit comes
annotated with the owning class's real name:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/lookup-name.sh \
    <output>/mapping --grep '"/api/' <output>/sources
```

Typical recovery on a real-world Kotlin app: ~100% of `*Repository` /
`*ViewModel` / `*UseCase` / `*Impl` classes, ~80% of DTOs.

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/kotlin-name-recovery.md`
for the full technique and limitations.

### Phase 4: Trace Call Flows

Follow execution paths from user-facing entry points down to network calls.

**Actions**:

1. **Start from entry points**: Read the main Activity or Application class identified in Phase 3.

2. **Follow the initialization chain**: Application.onCreate() often sets up the HTTP client, base URL, and DI framework. Read this first.

3. **Trace user actions**: From an Activity, follow:
   - `onCreate()` → view setup → click listeners
   - Click handler → ViewModel/Presenter method
   - ViewModel → Repository → API service interface
   - API service → actual HTTP call

4. **Map DI bindings** (if Dagger/Hilt is used): Find `@Module` classes to understand which implementations are provided for which interfaces.

5. **Handle obfuscated code**: When class names are mangled, use string literals and library API calls as anchors. Retrofit annotations and URL strings are never obfuscated.

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/call-flow-analysis.md` for detailed techniques and grep commands.

### Phase 5: Extract and Document APIs

Find all API endpoints and produce structured documentation.

**Action**: Run the API search script for a broad sweep.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/
```

On Windows (PowerShell):
```powershell
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.ps1" <output>/sources/
```

Targeted searches:
```bash
# Only Retrofit
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --retrofit

# Only hardcoded URLs
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --urls

# Only auth patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --auth
```

On Windows (PowerShell):
```powershell
# Only Retrofit
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.ps1" <output>/sources/ -Retrofit

# Only hardcoded URLs
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.ps1" <output>/sources/ -Urls

# Only auth patterns
& "${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.ps1" <output>/sources/ -Auth
```

Document the endpoints in **two tiers** — going deep on every endpoint is
prohibitively expensive on apps with 100+ paths, and most of them do not
warrant it. Always produce Tier 1; expand Tier 2 only for the endpoints
that matter.

#### Tier 1 — flat inventory (always)

A single table covering every discovered endpoint. Aim for one line each;
if you cannot determine a column, write `?`.

| Host | Method | Path | Auth | Source file |
|------|--------|------|------|-------------|
| `api.example.com` | GET | `/v1/users/profile` | Bearer | `com/example/api/UserApi.java` |
| `api.example.com` | POST | `/v1/auth/login` | none | `com/example/api/AuthApi.java` |

This table answers "what does the backend look like" in one screen and
takes ~5 minutes to produce from the `--paths` output even on a large app.

#### Tier 2 — per-endpoint detail (only for high-value endpoints)

Reserve the detailed format for the few endpoints that actually need it:

- the entire authentication flow (login, refresh, logout, OTP/SMS, anonymous, registration)
- payment / checkout / order-creation endpoints
- anything the user explicitly asked about
- anything that looked unusual during the scan (custom signing, undocumented headers, etc.)

```markdown
### `METHOD /path`

- **Source**: `com.example.api.ApiService` (ApiService.java:42)
- **Base URL**: `https://api.example.com/v1`
- **Path params**: `id` (String)
- **Query params**: `page` (int), `limit` (int)
- **Headers**: `Authorization: Bearer <token>`
- **Request body**: `{ "email": "string", "password": "string" }`
- **Response**: `ApiResponse<User>`
- **Called from**: `LoginActivity → LoginViewModel → UserRepository → ApiService`
```

As a default, do not produce Tier 2 entries for more than ~10 endpoints
unless the user explicitly asks for more — Tier 1 plus a Tier 2 deep dive
on auth + 1-2 key flows is what most consumers of this work actually want.

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/api-extraction-patterns.md` for library-specific search patterns and the full documentation template.

### Phase 6: Build, Sign, Install & Test (Smali Pipeline)

When working with the smali pipeline (Phase 2.5–2.7), use these scripts to rebuild and test modified APKs.

#### 6.1 Build & Sign

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/build-apk.sh <smali-dir> [-o <output.apk>] [-k <keystore>]
```

Rebuilds APK from smali source with apktool, then signs with jarsigner. Default output: `output/<dir>-signed.apk`. Resolves keystore from `tools/debug.keystore` or `debug.keystore` (project-local).

#### 6.2 Install & Test

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-apk.sh <signed.apk> [-s <device>] [-p <package>] [-a <activity>]
```

Installs APK to device/emulator, launches the app, waits 5 seconds, and checks logcat for `FATAL EXCEPTION` crashes. Reports [OK] or [FAIL] with crash logs.

#### 6.3 Full Test Cycle

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/test-cycle.sh <smali-dir> [-p <package>] [-a <activity>] [-s <device>]
```

Single command that runs the complete modify→build→sign→install→launch→crash-check loop. Ideal for rapid iteration during reverse engineering.

**Quick reference** (from real-world workflow):
```bash
# After modifying smali files in source/
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/test-cycle.sh source -p cn.education.online -a cn.education.online.ui.activity.LaunchActivity -s 127.0.0.1:7555
```

## Output

At the end of the workflow, deliver:

1. **Decompiled source** in the output directory
2. **Architecture summary** — app structure, main packages, pattern used
3. **API documentation** — all discovered endpoints in the format above
4. **Call flow map** — key paths from UI to network (especially authentication and main features)

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/setup-guide.md` — Installing Java, jadx, Fernflower/Vineflower, dex2jar, and optional tools
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/jadx-usage.md` — jadx CLI options and workflows
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/fernflower-usage.md` — Fernflower/Vineflower CLI options, when to use, APK workflow
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/api-extraction-patterns.md` — Library-specific search patterns and documentation template
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/call-flow-analysis.md` — Techniques for tracing call flows in decompiled code

## Smali Pipeline for Reinforced APKs

When working with packed/reinforced APKs (360, Tencent legu, etc.), the standard jadx→Java pipeline is often insufficient. Use the smali pipeline instead:

```
Phase 0:   fingerprint.sh <apk>            # Detect shell type
Phase 2.5: decompile-smali.sh <apk>         # apktool → smali
Phase 2.6: scan-shell.sh <dir>              # Find residuals
Phase 2.7: clean-shell.sh <dir>             # Remove residuals
  [modify smali as needed]
Phase 6:   test-cycle.sh <dir>              # Build → sign → install → test
```

## Golden Rules from Real-World Battle Testing

### Rule 1: ALWAYS Use jadx + apktool Together

**Never work in smali alone.** The standard workflow is a two-stage process:

1. **jadx first** — decompile the APK/DEX to readable Java to understand the architecture, trace call chains, and identify key classes
2. **apktool/smali second** — make precise bytecode-level modifications based on the Java analysis

Working exclusively in smali (42,000+ smali files) is like performing surgery blindfolded. jadx gives you the "map" — readable Java method names, control flow, and class relationships. smali is the "scalpel" — the only format you can edit and rebuild.

**Real case**: An agent spent 4+ hours failing to locate a payment dialog in smali, making 22 failed build attempts. Switching to jadx for analysis + smali for editing solved it in 2 rounds.

### Rule 2: ALWAYS Clear the apktool Build Cache Before Rebuilding

```
rm -rf source/build
java -jar apktool.jar b source -f -o output.apk
```

Apktool stores compiled `.dex` files in `source/build/apk/`. These cached files are reused across builds, even when smali source files have been modified. This is the **#1 cause of "I changed the code but the APK still has old behavior"**.

**Verification step**: After building, ALWAYS search the output APK binary for the strings/code you expect to be removed:
```bash
python -c "data = open('output.apk','rb').read(); print('FOUND' if b'deleted_class' in data else 'CLEAN')"
```

### Rule 3: Third-Party Payment/Verification SDKs Are Common

Many repackaged APKs contain third-party payment SDKs that are:
- Completely isolated in a single dex file (usually the last one, e.g., classes11.dex)
- Zero-coupled with the main app code (no imports from main app)
- Activated via ActivityLifecycleCallbacks, ContentProvider auto-start, or runtime plugin download

**Detection checklist** (use `scan-shell.sh` or manual search):
- `showType`, `payChannel`, `autoTrial`, `packId` in smali — payment config fields
- Cloudflare IPs (`104.19.*`, `104.18.*`, `172.64.*`) — DNS bypass mechanism
- `ContentProvider` + `ActivityLifecycleCallbacks` on same class — auto-start pattern
- `.apk` download strings in plugin framework code — runtime plugin replacement

### Rule 4: Verify Changes at the Binary Level

Smali-level verification is NOT sufficient. Always verify at the APK binary level:
```bash
# Check if payment code is truly gone from the built APK
python -c "data=open('output.apk','rb').read(); [print(f'FOUND: {t}') for t in [b'ndbdarm',b'muhuaya',b'gxogyub',b'zhongzhipian'] if t in data]"
```

### Rule 5: HTTP Packet Capture Reveals What Code Search Cannot

Direct IP connections, DNS-resolved addresses, and runtime-constructed URLs may not appear as plain strings in any smali file. Use `adb shell` + packet capture tools (or the phone's HTTP proxy/VPN capture) on a running APK to discover the actual network connections.
