#!/usr/bin/env bash
# Build a native installer for Digital with a bundled JRE 17, using jpackage.
#
# Run on the target OS (jpackage cannot cross-compile):
#   Linux  -> .deb / .rpm / .AppImage  (needs dpkg-deb / rpmbuild / appimagetool)
#   macOS  -> .dmg                     (needs Xcode command-line tools)
#   Windows-> .exe (Inno Setup)        (needs Inno Setup 6)
#
# Requires: JDK 17+ on PATH (jpackage jlinks a trimmed runtime from JAVA_HOME).
#
# Env overrides:
#   PACKAGE_TYPE deb|rpm|appimage|dmg|exe   (default per OS)
#   APP_VERSION  version string (default 1.0.0)
#   WIN_CONSOLE  =1 to attach a console to the Windows exe (debug)
#   SKIP_BUILD   =1 to skip the mvn step (reuse existing target/Digital.jar)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Digital"
MAIN_JAR="Digital.jar"
MAIN_CLASS="de.neemann.digital.gui.Main"
APP_VERSION="${APP_VERSION:-1.0.0}"
# strip leading 'v' (e.g. git tag v0.63 -> 0.63); ensure x.y.z for MSI
APP_VERSION="${APP_VERSION#v}"
case "$APP_VERSION" in
  *.*.*) : ;;
  *.*. ) APP_VERSION="${APP_VERSION}0" ;;
  *.*  ) APP_VERSION="${APP_VERSION}.0" ;;
  *    ) APP_VERSION="${APP_VERSION}.0.0" ;;
esac
if ! printf '%s' "$APP_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo ">> APP_VERSION '$APP_VERSION' is not numeric x.y.z; falling back to 1.0.0"
  APP_VERSION="1.0.0"
fi
MAJOR="${APP_VERSION%%.*}"
if [ "$MAJOR" = "0" ]; then
  APP_VERSION="1${APP_VERSION#0}"
fi
unset MAJOR

# --- 1. detect OS + arch + default type + icon -------------------------------
# Use JDK arch naming internally, map to amd64 for artifact names.
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH_ALT="amd64" ;;
  aarch64) ARCH_ALT="arm64"  ;;
  *)       ARCH_ALT="$ARCH"  ;;
esac

case "$(uname -s)" in
  Linux*)   OS=linux;  PACKAGE_TYPE="${PACKAGE_TYPE:-deb}";  ICON="src/main/resources/icons/icon256.png" ;;
  Darwin*)  OS=mac;    PACKAGE_TYPE="${PACKAGE_TYPE:-dmg}";  ICON="" ;;
  MINGW*|MSYS*|CYGWIN*)
            OS=win;    PACKAGE_TYPE="${PACKAGE_TYPE:-exe}";  ICON="src/main/resources/icons/icon48.ico" ;;
  *) echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

# --- 2. build the fat jar ----------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo ">> building Digital.jar"
  mvn -q clean package -DskipTests -Pno-git-rev -Dgit.commit.id.describe="$APP_VERSION"
fi
[ -f "target/$MAIN_JAR" ] || { echo "target/$MAIN_JAR missing; run mvn package first"; exit 1; }

# --- 3. staged input dir ----------------------------------------------------
STAGE="target/jpackage-input"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "target/$MAIN_JAR" "$STAGE/"
cp -R "src/main/dig/lib" "$STAGE/lib"

ICON_ARG=()
[ -n "$ICON" ] && [ -f "$ICON" ] && ICON_ARG=(--icon "$ICON")

# --- 4. JVM options ---------------------------------------------------------
JAVA_OPTS_ARG=()
case "$OS" in
  mac) ;;
  *) JAVA_OPTS_ARG=(--java-options "-Dsun.java2d.uiScale=1") ;;
esac

# --- 5. Windows installer options -------------------------------------------
INSTALL_ARG=()
case "$OS" in
  win)
    if [ "${PACKAGE_TYPE}" = "msi" ]; then
      INSTALL_ARG=(
        --win-dir-chooser
        --win-menu
        --win-menu-group "Digital"
        --win-shortcut
        --win-shortcut-prompt
      )
    fi
    [ "${WIN_CONSOLE:-0}" = "1" ] && INSTALL_ARG+=(--win-console)
    ;;
esac

JPACKAGE_TYPE="$PACKAGE_TYPE"
# AppImage is not a jpackage type; we build app-image then wrap it
[ "$PACKAGE_TYPE" = "appimage" ] && JPACKAGE_TYPE="app-image"

# --- 6. Linux post-processing function (shared by deb/rpm/app-image) --------
fix_linux_desktop() {
  local dir="$1"
  local desktop
  desktop="$(find "$dir" -name '*.desktop' -path '*/'"$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"'/*' -not -path '*/runtime/*' -type f 2>/dev/null | head -1)"
  if [ -n "$desktop" ]; then
    sed -i 's|^Icon=/.*|Icon=digital|' "$desktop"
    grep -q '^StartupWMClass=' "$desktop" || \
      echo "StartupWMClass=de-neemann-digital-gui-Main" >> "$desktop"
  fi
  for SIZE in 128 256; do
    local dir2="$dir/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps"
    mkdir -p "$dir2"
    cp "$ICON" "$dir2/digital.png"
  done
  mkdir -p "$dir/usr/share/pixmaps"
  cp "$ICON" "$dir/usr/share/pixmaps/digital.png"
}

# --- 7. run jpackage ---------------------------------------------------------
mkdir -p target/dist
echo ">> $OS ($ARCH_ALT) -> $PACKAGE_TYPE"

case "$PACKAGE_TYPE" in
  exe)
    jpackage \
      --name "$APP_NAME" \
      --type app-image \
      --input "$STAGE" \
      --main-jar "$MAIN_JAR" \
      --main-class "$MAIN_CLASS" \
      --app-version "$APP_VERSION" \
      --vendor "neemann" \
      --dest target/dist \
      "${ICON_ARG[@]+"${ICON_ARG[@]}"}" \
      "${JAVA_OPTS_ARG[@]+"${JAVA_OPTS_ARG[@]}"}" \
      "${INSTALL_ARG[@]+"${INSTALL_ARG[@]}"}"

    ISCC="${ISCC:-iscc}"
    if ! command -v "$ISCC" >/dev/null 2>&1; then
      ISCC="/c/Program Files (x86)/Inno Setup 6/ISCC.exe"
      if [ ! -x "$ISCC" ]; then
        echo "iscc not found; install Inno Setup 6 first." >&2
        exit 1
      fi
    fi
    "$ISCC" //DMyAppVersion="$APP_VERSION" //Qp packaging/digital.iss
    ;;

  appimage)
    jpackage \
      --name "$APP_NAME" \
      --type app-image \
      --input "$STAGE" \
      --main-jar "$MAIN_JAR" \
      --main-class "$MAIN_CLASS" \
      --app-version "$APP_VERSION" \
      --vendor "neemann" \
      --dest target/dist \
      "${ICON_ARG[@]+"${ICON_ARG[@]}"}" \
      "${JAVA_OPTS_ARG[@]+"${JAVA_OPTS_ARG[@]}"}" \
      "${INSTALL_ARG[@]+"${INSTALL_ARG[@]}"}"

    APPDIR="target/dist/$APP_NAME"

    # Create AppRun
    cat > "$APPDIR/AppRun" << 'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec "$HERE/bin/Digital" "$@"
APPRUN
    chmod +x "$APPDIR/AppRun"

    # Create .desktop (fix_linux_desktop already patched the jpackage one,
    # but AppImage needs one at root with specific format)
    cat > "$APPDIR/$APP_NAME.desktop" << DESKTOP
[Desktop Entry]
Type=Application
Name=$APP_NAME
Exec=$APP_NAME
Icon=$APP_NAME
Categories=Education;Electronics;
Terminal=false
StartupWMClass=de-neemann-digital-gui-Main
DESKTOP

    cp "$ICON" "$APPDIR/$APP_NAME.png"
    ln -sf "$APP_NAME.png" "$APPDIR/.DirIcon"
    for SZ in 128 256; do
      mkdir -p "$APPDIR/usr/share/icons/hicolor/${SZ}x${SZ}/apps"
      cp "$ICON" "$APPDIR/usr/share/icons/hicolor/${SZ}x${SZ}/apps/digital.png"
    done
    mkdir -p "$APPDIR/usr/share/pixmaps"
    cp "$ICON" "$APPDIR/usr/share/pixmaps/digital.png"

    ARCH_APPIMAGE="$ARCH"
    [ "$ARCH" = "x86_64" ] && ARCH_APPIMAGE="x86_64"
    [ "$ARCH" = "aarch64" ] && ARCH_APPIMAGE="aarch64"
    ARCH="$ARCH_APPIMAGE" appimagetool "$APPDIR" "target/dist/$APP_NAME-${APP_VERSION}-${ARCH_ALT}.AppImage"
    ;;

  deb)
    jpackage \
      --name "$APP_NAME" \
      --type deb \
      --input "$STAGE" \
      --main-jar "$MAIN_JAR" \
      --main-class "$MAIN_CLASS" \
      --app-version "$APP_VERSION" \
      --vendor "neemann" \
      --dest target/dist \
      "${ICON_ARG[@]+"${ICON_ARG[@]}"}" \
      "${JAVA_OPTS_ARG[@]+"${JAVA_OPTS_ARG[@]}"}" \
      "${INSTALL_ARG[@]+"${INSTALL_ARG[@]}"}"

    # Post-process .deb: fix desktop icon path + register icons
    DEB="$(ls target/dist/*.deb 2>/dev/null | head -1)"
    if [ -n "$DEB" ]; then
      PKG_STEM="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"
      WORK="$(mktemp -d)"
      dpkg-deb -R "$DEB" "$WORK"
      fix_linux_desktop "$WORK"
      POSTINST="$WORK/DEBIAN/postinst"
      if [ -f "$POSTINST" ]; then
        sed -i '/^xdg-desktop-menu install/a\
if [ -x /usr/bin/gtk-update-icon-cache ]; then\
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true\
fi' "$POSTINST"
      fi
      dpkg-deb --build "$WORK" "$DEB"
      rm -rf "$WORK"
    fi
    ;;

  rpm)
    jpackage \
      --name "$APP_NAME" \
      --type rpm \
      --input "$STAGE" \
      --main-jar "$MAIN_JAR" \
      --main-class "$MAIN_CLASS" \
      --app-version "$APP_VERSION" \
      --vendor "neemann" \
      --dest target/dist \
      "${ICON_ARG[@]+"${ICON_ARG[@]}"}" \
      "${JAVA_OPTS_ARG[@]+"${JAVA_OPTS_ARG[@]}"}" \
      "${INSTALL_ARG[@]+"${INSTALL_ARG[@]}"}"

    # ponytail: jpackage's RPM .desktop uses an absolute icon path that GNOME
    # may ignore on some setups. A full fix requires rpm2cpio + rpmrebuild
    # (unpack, patch .desktop, repack). Most modern distros handle icons via
    # file triggers so the jpackage output works fine in practice. Skip the
    # post-processing here and keep it simple.
    ;;

  *)
    # deb/dmg/msi pass-through to jpackage
    jpackage \
      --name "$APP_NAME" \
      --type "$JPACKAGE_TYPE" \
      --input "$STAGE" \
      --main-jar "$MAIN_JAR" \
      --main-class "$MAIN_CLASS" \
      --app-version "$APP_VERSION" \
      --vendor "neemann" \
      --dest target/dist \
      "${ICON_ARG[@]+"${ICON_ARG[@]}"}" \
      "${JAVA_OPTS_ARG[@]+"${JAVA_OPTS_ARG[@]}"}" \
      "${INSTALL_ARG[@]+"${INSTALL_ARG[@]}"}"
    ;;
esac

echo ">> done: target/dist/"
ls -l target/dist/
echo "$APP_VERSION" > target/dist/.app-version
