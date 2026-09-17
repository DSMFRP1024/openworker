#!/usr/bin/env bash
# Build the OpenWorker **desktop** tarball using the Tauri v1 shell
# (surfaces/gui/src-tauri-v1). See that crate's README.md for why a second shell exists.
#
# Why not build_linux.sh: that one drives Tauri v2, whose `webkit2gtk-4.1` requirement no
# RHEL 8-derived distro (Kylin V10, UOS 20) can satisfy, and whose binaries are linked against
# a much newer glibc. This script builds the v1 shell, which links `webkit2gtk-4.0`, inside
# whatever glibc it runs in — CI wraps it in a debian:11 (glibc 2.31) container so the
# artifact's floor matches the target machine exactly.
#
# Deliberately NOT used here, and both for the same reason:
#   * the Tauri CLI — @tauri-apps/cli v2 cannot build a v1 app, and pulling the v1 CLI in just
#     to compile adds a moving part to a build that already has to survive an EOL toolchain;
#   * Tauri's bundlers — deb/AppImage would drag in linuxdeploy-plugin-gtk, which downloads a
#     *prebuilt* GTK/WebKit bundle compiled against glibc 2.38, i.e. exactly what we are
#     avoiding. `bundle.active` is false in src-tauri-v1/tauri.conf.json for that reason.
# `cargo build --features custom-protocol` is all that is needed: that feature is what embeds
# ../dist into the binary.
#
# Prerequisites: Rust (rustup), Node/npm, and the v1 GUI deps —
#   libwebkit2gtk-4.0-dev libgtk-3-dev libsoup2.4-dev libjavascriptcoregtk-4.0-dev pkg-config
# The tray needs no -dev package: `libappindicator-sys` dlopens `libayatana-appindicator3.so.1`
# (or the legacy `libappindicator3.so.1`) at *runtime* and degrades if neither is present.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$HERE/.." && pwd)"
GUI="$PLATFORM/surfaces/gui"
V1="$GUI/src-tauri-v1"

# The v2 shell's config stays the single source of truth for the version; the v1 config carries
# its own copy because v1 and v2 put `version` in different places (package.version vs
# version). Assert they agree instead of letting them drift silently.
VERSION="$(node -p "require('$GUI/src-tauri/tauri.conf.json').version")"
V1_VERSION="$(node -p "require('$V1/tauri.conf.json').package.version")"
if [ "$VERSION" != "$V1_VERSION" ]; then
  echo "ERROR: version drift — src-tauri=$VERSION src-tauri-v1=$V1_VERSION" >&2
  exit 1
fi

TRIPLE="$(rustc -vV | sed -n 's/host: //p')"
ARCH="${TRIPLE%%-*}"
GLIBC_MAX="${OCW_GLIBC_MAX:-2.31}"
SIDECAR_SRC="$HERE/dist-v1/openworker-server"
DIST="$HERE/dist-v1-bundle"
STAGE_ROOT="$HERE/dist-portable-v1"
STAGE="$STAGE_ROOT/openworker-$VERSION-linux-$ARCH-desktop"

echo "==> target $TRIPLE  arch $ARCH  version $VERSION  glibc ceiling $GLIBC_MAX"
echo "==> webkit2gtk: $(pkg-config --modversion webkit2gtk-4.0 2>/dev/null || echo '<pkg-config cannot see 4.0>')"
echo "==> gtk+-3.0:   $(pkg-config --modversion gtk+-3.0 2>/dev/null || echo '<pkg-config cannot see gtk3>')"

echo "==> [1/6] PyInstaller: bundling openworker-server (DESKTOP entry)"
# COWORKER_SERVICE selects the browser-served entry point in openworker-server.spec. A value
# leaking in from the environment would silently ship the wrong entry point (and it has a
# different CLI), so strip it rather than trusting the caller.
env -u COWORKER_SERVICE "$PLATFORM/.venv/bin/pyinstaller" --noconfirm --clean \
  --distpath "$HERE/dist-v1" --workpath "$HERE/build-v1" "$HERE/openworker-server.spec"

echo "==> [2/6] checking the PyInstaller onedir bundle"
# NOT staged into the crate tree: `bundle.resources` is absent from tauri.conf.json on purpose
# (see src-tauri-v1/build.rs — on v1 tauri-build would *copy* it into target/ on every build).
# The onedir bundle goes straight into the tarball in [5/6].
[ -x "$SIDECAR_SRC/openworker-server" ] || {
  echo "ERROR: no sidecar entrypoint at $SIDECAR_SRC/openworker-server" >&2
  exit 1
}

echo "==> [3/6] frontend (one build, shared by the browser build and both desktop shells)"
( cd "$GUI" && npm run build )
[ -f "$GUI/dist/index.html" ] || { echo "ERROR: npm run build produced no dist/index.html" >&2; exit 1; }

echo "==> [4/6] cargo build (Tauri v1 shell)"
( cd "$V1" && cargo build --release --features custom-protocol )
# On Linux the executable keeps the Cargo PACKAGE name; `productName` only names the bundle.
CARGO_NAME="$(sed -n 's/^name = "\(.*\)"/\1/p' "$V1/Cargo.toml" | head -1)"
RELEASE_BIN="$V1/target/release/$CARGO_NAME"
[ -x "$RELEASE_BIN" ] || { echo "ERROR: release binary not found at $RELEASE_BIN" >&2; exit 1; }
# The one thing that must never quietly come back: a link against webkit2gtk-4.1, which would
# put us right back at the unsolvable dependency.
if readelf -d "$RELEASE_BIN" | grep -q 'libwebkit2gtk-4\.1'; then
  echo "ERROR: the v1 shell linked webkit2gtk-4.1 — the v1 baseline is broken" >&2
  exit 1
fi
readelf -d "$RELEASE_BIN" | grep -E 'NEEDED.*(webkit2gtk|gtk-3|soup|javascriptcore)' || true

echo "==> [5/6] assembling the tarball tree"
rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE"
# `sidecar/` NEXT TO the executable is the first place the shell looks (src-tauri-v1/src/lib.rs
# `server_bin`), so this layout works with no configuration.
cp "$RELEASE_BIN" "$STAGE/openworker-desktop"
# -L (dereference): PyInstaller's onedir bundle contains symlinks into _internal/, and a tarball
# should carry plain files so it survives unpacking anywhere.
cp -RL "$SIDECAR_SRC" "$STAGE/sidecar"
chmod +x "$STAGE/sidecar/openworker-server"
rm -rf "$STAGE/sidecar/_internal/Python.framework"
cp "$V1/icons/128x128.png" "$STAGE/openworker-desktop.png"

cat > "$STAGE/run.sh" <<'EOF'
#!/bin/sh
# Launch OpenWorker from wherever this tarball was unpacked. POSIX sh: the target may be a
# distro whose /bin/sh is dash.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# WebKitGTK under some ARM64 Mesa drivers renders a black window without these.
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
exec "$HERE/openworker-desktop" ${@+"$@"}
EOF
chmod +x "$STAGE/run.sh"

cat > "$STAGE/install-menu-entry.sh" <<'EOF'
#!/bin/sh
# Add OpenWorker to this user's application menu (no root, no package manager).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor/128x128/apps"
mkdir -p "$APPS" "$ICONS"
cp "$HERE/openworker-desktop.png" "$ICONS/openworker.png"
cat > "$APPS/openworker.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=OpenWorker
Comment=Local-first AI coworker
Exec="$HERE/run.sh"
Icon=openworker
Terminal=false
Categories=Utility;Development;
DESKTOP
chmod +x "$APPS/openworker.desktop" 2>/dev/null || true
echo "Installed $APPS/openworker.desktop"
echo "Remove it with: rm $APPS/openworker.desktop"
EOF
chmod +x "$STAGE/install-menu-entry.sh"

cat > "$STAGE/README.txt" <<EOF
OpenWorker $VERSION — Linux $ARCH desktop (portable, Tauri v1 shell)

Unpack anywhere and run ./run.sh  (or double-click openworker-desktop).
Optional: ./install-menu-entry.sh adds it to your application menu.

Runtime requirements — these are system libraries, installed with your distro's
package manager. They are NOT bundled, by design: bundling them would mean shipping
copies linked against a newer glibc than yours, which is exactly the failure this
build exists to avoid.

  Debian/Ubuntu:  sudo apt install libwebkit2gtk-4.0-37 libgtk-3-0 libsoup2.4-1
  Kylin V10 / RHEL 8 base:  sudo yum install webkit2gtk3 gtk3 libsoup
  Fedora:         sudo dnf install webkit2gtk4.0 gtk3 libsoup

Note the WebKitGTK version: WebKitGTK **4.0**, not 4.1. That is the whole point of
this build — 4.0 is what the RHEL 8 family ships, and it is why the usual desktop
build cannot run there.

The system tray needs libayatana-appindicator3 (or the older libappindicator3) at
runtime. Without it the app still starts and works; it just loses the tray icon, and
closing the window then quits instead of hiding to the tray.

The Python agent server (sidecar/) is bundled — no Python install required. Keep the
sidecar/ folder next to the openworker-desktop executable.

Not in this build, on purpose:
  * Voice input — the dictation engine is macOS/Windows only.
  * Auto-update — Linux artifacts are not in the update manifest. Install a newer
    tarball over this one instead.

Logs: ~/.config/coworker/logs/openworker-server.log (previous run kept as .old)
EOF

echo "==> [6/6] glibc ceiling check"
"${OCW_PYTHON:-python3}" "$HERE/check_glibc_ceiling.py" --max "$GLIBC_MAX" "$STAGE"

mkdir -p "$DIST"
rm -f "$DIST"/openworker-*-desktop.tar.gz "$DIST/SHA256SUMS"
tar -C "$STAGE_ROOT" -czf "$DIST/openworker-$VERSION-linux-$ARCH-desktop.tar.gz" \
  "$(basename "$STAGE")"
( cd "$DIST" && sha256sum openworker-*-desktop.tar.gz > SHA256SUMS )

echo ""
echo "Done. Artifacts under: $DIST"
ls -la "$DIST"
cat "$DIST/SHA256SUMS"
