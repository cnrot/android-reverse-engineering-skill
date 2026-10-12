# Third-Party Software Notices

This plugin is licensed under the [Apache License 2.0](LICENSE). That license
covers only the plugin's own files (instructions, reference docs, and scripts).

The plugin **does not bundle or redistribute** any third-party software. Its
scripts invoke tools that you install yourself, either manually or through
`install-dep.sh` / `install-dep.ps1`, which download them from their official
upstream sources or your system package manager. Each tool is distributed by
its own authors under its own license, and your use of it is governed by that
license, not by this plugin's.

| Tool | Used for | License | Project |
|---|---|---|---|
| jadx | DEX/APK to Java decompilation (default engine) | Apache-2.0 | https://github.com/skylot/jadx |
| Vineflower | Java decompilation (Fernflower fork) | Apache-2.0 | https://github.com/Vineflower/vineflower |
| Fernflower | Java decompilation (JetBrains) | Apache-2.0 | https://github.com/JetBrains/fernflower |
| dex2jar | DEX to JAR conversion | Apache-2.0 | https://github.com/ThexXTURBOXx/dex2jar |
| Apktool | Android resource decoding (optional) | Apache-2.0 | https://apktool.org/ |
| Android SDK Platform-Tools (`adb`) | Pulling APKs from a device (optional) | Android Software Development Kit License | https://developer.android.com/tools/releases/platform-tools |
| Java (OpenJDK 17+) | Runtime required by the tools above | GPL-2.0 with Classpath Exception (varies by distribution) | https://openjdk.org/ |

When `install-dep` uses a package manager (Homebrew, apt, dnf, pacman, winget,
scoop, Chocolatey), the package comes from that manager's repositories and
under its maintainers' packaging terms.

Licenses listed here are provided for convenience and may change upstream;
the license published by each project is authoritative.

## Your responsibility

These tools decompile software. Make sure you have the right to analyze the
files you process. See the [Disclaimer](README.md#disclaimer) in the README.
