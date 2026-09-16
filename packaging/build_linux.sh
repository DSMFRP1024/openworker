#!/usr/bin/env bash
# Build the Linux desktop app (deb + AppImage by default) for the HOST architecture.
#
# Linux counterpart to build_dmg.sh / build_windows.ps1 — same three phases:
#   1. PyInstaller-bundle the server into a standalone onedir folder (no venv at runtime).
#   2. Stage it at binaries/sidecar/ for Tauri's `resources` slot.
#   3. `tauri build --bundles …` → installers with the sidecar copied in.
#
# Prerequisites (mirrors the other two scripts' headers):
#   - Rust (rustup) + Node/npm, GUI deps installed (`npm ci` in surfaces/gui).
#   - A Python venv at .venv (repo root) with this package installed editable, plus the
#     build-only deps:
#       python3 -m venv .venv
#       .venv/bin/pip install -e '.[bedrock]' pyinstaller tzdata typer
#     `typer` is BUILD-time only: PyInstaller walks the `mcp` package and `mcp.cli` calls
#     sys.exit() at import if typer is absent, which aborts the freeze.
#   - System packages for Tauri v2 + the STT crate:
#       libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev
#       patchelf libasound2-dev    # cpal/ALSA (voice input)
#       cmake clang libclang-dev   # whisper-rs builds whisper.cpp via bindgen
#     Ubuntu 22.04 ships webkit2gtk-4.1 too; Debian 12 as well.
#
# ARCH: PyInstaller CANNOT cross-compile — the sidecar is a frozen CPython, so this script
# always builds for the host triple. Use a native arm64 machine (or GitHub's ubuntu-24.04-arm
# runner, see .github/workflows/linux-arm64.yml) to get an aarch64 build.
#
# Experimental (use-at-your-own-risk) connectors are EXCLUDED from this build by default —
# the spec strips coworker.connectors.experimental. Self-builders can opt in with:
#   COWORKER_EXPERIMENTAL=1 ./build_linux.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$HERE/.." && pwd)"
GUI="$PLATFORM/surfaces/gui"
APP="OpenWorker"
# Single source of truth for the version: tauri.conf.json (also stamps the bundle).
VERSION="$(node -p "require('$GUI/src-tauri/tauri.conf.json').version")"
TRIPLE="$(rustc -vV | sed -n 's/host: //p')"   # e.g. aarch64-unknown-linux-gnu
ARCH="${TRIPLE%%-*}"
# deb + AppImage by default. rpm needs `rpmbuild`; add it explicitly if you want it:
#   OCW_BUNDLES=deb,rpm,appimage ./build_linux.sh
BUNDLES="${OCW_BUNDLES:-deb,appimage}"
SIDECAR="$GUI/src-tauri/binaries/sidecar"

echo "==> target: $TRIPLE  architecture: $ARCH  version: $VERSION  bundles: $BUNDLES"

echo "==> [1/4] PyInstaller: bundling openworker-server ($TRIPLE)"
"$PLATFORM/.venv/bin/pyinstaller" --noconfirm --clean \
  --distpath "$HERE/dist" --workpath "$HERE/build" "$HERE/openworker-server.spec"

echo "==> [2/4] staging sidecar resources"
# Onedir bundle (exe + _internal/) ships via Tauri `resources` as `<resource-dir>/sidecar/`.
# rm -rf first: cp writes THROUGH a symlink at the destination, and stale onefile binaries
# from pre-onedir builds must not survive.
mkdir -p "$GUI/src-tauri/binaries"
rm -rf "$SIDECAR" "$GUI/src-tauri/binaries/openworker-server-$TRIPLE"
# -L (dereference): Tauri's resource bundler flattens symlinks into duplicate real files, so
# dereferencing at staging keeps what we stage identical to what ships.
cp -RL "$HERE/dist/openworker-server" "$SIDECAR"
chmod +x "$SIDECAR/openworker-server"
# macOS drops the flattened Python.framework here for notarization reasons; on Linux there is
# no such layout constraint, but keeping the tree framework-free keeps the two scripts aligned.
rm -rf "$SIDECAR/_internal/Python.framework"

echo "==> [3/4] tauri build (--bundles $BUNDLES)"
# No updater overlay: the minisign key is a release-only secret and Linux artifacts are not
# wired into the update manifest yet.
( cd "$GUI" && npm run tauri build -- --bundles "$BUNDLES" )

BUNDLE="$GUI/src-tauri/target/release/bundle"

echo "==> [4/4] portable tarball (sidecar next to the binary)"
# Why a tarball as well as deb/AppImage: it needs no package manager, no FUSE, and no root —
# unpack and run. The layout puts `sidecar/` NEXT TO the executable, which is the first place
# the Tauri shell looks (src-tauri/src/lib.rs `server_bin`), so it works out of the box.
STAGE="$HERE/dist-portable/openworker-$VERSION-linux-$ARCH"
rm -rf "$HERE/dist-portable"
mkdir -p "$STAGE"
# On Linux the release executable keeps the Cargo PACKAGE name (`openworker-desktop`) — the
# `productName` only names the bundle, unlike macOS/Windows where the executable itself is
# renamed to it. Read the package name out of Cargo.toml instead of hardcoding either value.
CARGO_NAME="$(sed -n 's/^name = "\(.*\)"/\1/p' "$GUI/src-tauri/Cargo.toml" | head -1)"
RELEASE_BIN="$GUI/src-tauri/target/release/$CARGO_NAME"
[ -x "$RELEASE_BIN" ] || { echo "ERROR: release binary not found at $RELEASE_BIN" >&2; exit 1; }
cp "$RELEASE_BIN" "$STAGE/$APP"
cp -RL "$SIDECAR" "$STAGE/sidecar"
cat > "$STAGE/README.txt" <<EOF
OpenWorker $VERSION — Linux $ARCH (portable)

Unpack anywhere and run ./OpenWorker (or ./run.sh).

Runtime requirements (install with your distro's package manager):
  libwebkit2gtk-4.1-0  libgtk-3-0  libayatana-appindicator3-1  librsvg2-2

  Debian/Ubuntu:  sudo apt install libwebkit2gtk-4.1-0 libgtk-3-0 \\
                    libayatana-appindicator3-1 librsvg2-2
  Fedora:         sudo dnf install webkit2gtk4.1 gtk3 libappindicator-gtk3 librsvg2
  Arch:           sudo pacman -S webkit2gtk-4.1 gtk3 libayatana-appindicator librsvg

The Python agent server (sidecar/) is bundled — no Python install required.
Keep the sidecar/ folder next to the OpenWorker executable.
EOF
cat > "$STAGE/run.sh" <<'EOF'
#!/usr/bin/env bash
# Launch OpenWorker from wherever this tarball was unpacked.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# WebKitGTK under some ARM64 Mesa drivers renders a black window without these.
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
exec "$HERE/OpenWorker" "$@"
EOF
chmod +x "$STAGE/run.sh"
# Assemble fully before writing the archive so a partial tree never ships.
tar -C "$HERE/dist-portable" -czf "$BUNDLE/openworker-$VERSION-linux-$ARCH.tar.gz" \
  "openworker-$VERSION-linux-$ARCH"

echo ""
echo "Done. Artifacts under: $BUNDLE"
ls -la "$BUNDLE" "$BUNDLE/deb" 2>/dev/null || true
