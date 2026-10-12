# Privacy Policy

_Last updated: 2026-10-11_

The **android-reverse-engineering** plugin for Claude Code is an open-source set of
instructions and local scripts. It does not include any server, account, or
telemetry operated by the author.

## Data the plugin collects

None. The plugin does not collect, store, or transmit personal data, usage
statistics, or the files you analyze.

## Local processing

APK, XAPK, JAR, and AAR files are decompiled and searched entirely on your
machine with locally installed tools (jadx, Vineflower/Fernflower, dex2jar).
Output is written to a directory on your machine and nowhere else.

The scripts do not read credentials, tokens, or API keys from your environment
or files. The "auth" search options only scan the decompiled source you point
them at for authentication-related strings.

## Network access

The only network requests the plugin's scripts make are dependency downloads,
and only when you run `install-dep.sh` / `install-dep.ps1`:

- release metadata and archives from GitHub (`api.github.com`, `github.com`)
  for jadx, Vineflower, and dex2jar;
- your system package manager (for example Homebrew, apt, winget, scoop, or
  Chocolatey) when installing Java, jadx, or optional tools such as Apktool
  and adb.

These requests go directly to those services and are subject to their own
privacy policies. No data about you or your analyzed files is included.

The tools themselves (jadx, Vineflower, dex2jar, Apktool, adb, Java) are
third-party software under their own licenses and terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Claude

Like any Claude Code plugin, the content Claude reads while using this plugin
(for example decompiled source) is processed by Claude under Anthropic's terms
and privacy policy, not by the plugin author.

## Contact

Questions or concerns: open an issue at
https://github.com/SimoneAvogadro/android-reverse-engineering-skill/issues
