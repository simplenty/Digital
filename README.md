# Digital

A maintaince fork of [hneemann/Digital](https://github.com/hneemann/Digital) — an easy-to-use digital logic designer and circuit simulator for educational use.

This fork does **not** modify the simulator core. It focuses entirely on packaging, distribution, and CI automation.

## Changes from upstream

### File-based preferences

Upstream stores settings via `java.util.prefs.Preferences`, which on Windows writes to
`HKCU\Software\JavaSoft\Prefs\dig` in the registry. Uninstallers never clean this up.

This fork replaces it with a `prefs.properties` file:

| OS | Path |
|----|------|
| Windows | `%APPDATA%\Digital\prefs.properties` |
| macOS | `~/Library/Application Support/Digital/prefs.properties` |
| Linux | `~/.config/Digital/prefs.properties` |

On first run, legacy registry entries are migrated into the file and then removed.
All the changes live in a single class (`de.neemann.gui.Prefs`) — the simulator core is untouched.

### Pre-bundled JRE installers

Upstream ships a plain ZIP and requires users to install Java 8+ manually.

This fork bundles JRE 17 via `jpackage` and produces native installers for every platform.
No Java installation needed.

| Platform | Format | Architectures |
|----------|--------|--------------|
| Windows | `.exe` (Inno Setup) | amd64 |
| Linux | `.deb` | amd64, arm64 |
| Linux | `.rpm` | amd64, arm64 |
| Linux | `.AppImage` | amd64, arm64 |
| macOS | `.dmg` | arm64 |

The Inno Setup Windows uninstaller deletes `%APPDATA%\Digital` and the legacy registry subtree,
so the system returns to a clean state after uninstall.

### CI/CD pipeline

Every push of a `v*` tag triggers GitHub Actions to build all installers in parallel
and publish them to a GitHub Release. The workflow matrix runs 9 jobs:

| Job | Runner | Artifact |
|-----|--------|----------|
| Windows amd64 | `windows-latest` | `Digital-\<ver\>-amd64.exe` |
| Linux amd64 deb | `ubuntu-latest` | `Digital-\<ver\>-amd64.deb` |
| Linux amd64 rpm | `ubuntu-latest` | `Digital-\<ver\>-amd64.rpm` |
| Linux amd64 AppImage | `ubuntu-latest` | `Digital-\<ver\>-amd64.AppImage` |
| Linux arm64 deb | `ubuntu-24.04-arm` | `Digital-\<ver\>-arm64.deb` |
| Linux arm64 rpm | `ubuntu-24.04-arm` | `Digital-\<ver\>-arm64.rpm` |
| Linux arm64 AppImage | `ubuntu-24.04-arm` | `Digital-\<ver\>-arm64.AppImage` |
| macOS arm64 | `macos-latest` | `Digital-\<ver\>-arm64.dmg` |

## Quick start

```
mvn clean package -DskipTests
java -jar target/Digital.jar
```

To build a native installer (requires JDK 17+):

```
./packaging/package.sh
```

| Env | Default | Description |
|-----|---------|-------------|
| `PACKAGE_TYPE` | auto | `deb` / `rpm` / `appimage` / `dmg` / `exe` |
| `APP_VERSION` | `1.0.0` | Version string |
| `SKIP_BUILD` | — | Set to `1` to reuse existing `target/Digital.jar` |

## License

[GNU General Public License v3](LICENSE)
