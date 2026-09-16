#!/usr/bin/env bash
# Package the AppImage's AppDir as a plain tarball — "nothing to install, nothing to FUSE-mount".
#
# Why reuse the AppImage instead of assembling our own bundle: Tauri's AppImage step already
# runs linuxdeploy + linuxdeploy-plugin-gtk, which copies the GTK/WebKitGTK stack into the
# AppDir (usr/lib/libgtk-3.so.0, libwebkit2gtk-4.1.so.0, libjavascriptcoregtk-4.1.so.0, the
# gdk-pixbuf loaders, the GTK immodules cache …) and wires the matching env vars into AppRun.
# Re-doing that by hand is precisely the part that goes subtly wrong, and extracting the
# AppImage costs nothing and needs no FUSE (--appimage-extract is a runtime built-in).
#
# The result still cannot bundle glibc: the binary needs the glibc of the machine it was
# built on, which is why the CI builds on the oldest runner it can.
#
# Used by .github/workflows/linux-arm64.yml; runnable locally after an AppImage build.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$HERE/.." && pwd)"
GUI="$PLATFORM/surfaces/gui"
VERSION="$(node -p "require('$GUI/src-tauri/tauri.conf.json').version")"
TRIPLE="$(rustc -vV | sed -n 's/host: //p')"
ARCH="${TRIPLE%%-*}"
BUNDLE="$GUI/src-tauri/target/release/bundle"
NAME="openworker-$VERSION-linux-$ARCH-full"

APPIMAGE="$(find "$BUNDLE/appimage" -maxdepth 1 -name '*.AppImage' 2>/dev/null | head -1 || true)"
if [ -z "$APPIMAGE" ]; then
  echo "SKIPPED: no .AppImage in $BUNDLE/appimage — nothing to repack (AppImage build failed?)"
  exit 0
fi

echo "==> extracting $(basename "$APPIMAGE")"
STAGE="$HERE/dist-full"
rm -rf "$STAGE"
mkdir -p "$STAGE"
( cd "$STAGE" && "$APPIMAGE" --appimage-extract >/dev/null )
[ -e "$STAGE/squashfs-root/AppRun" ] || { echo "ERROR: extracted AppDir has no AppRun" >&2; exit 1; }
mv "$STAGE/squashfs-root" "$STAGE/$NAME"

cat > "$STAGE/$NAME/run.sh" <<'EOF'
#!/usr/bin/env bash
# Launch the bundled AppDir from wherever this tarball was unpacked.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# WebKitGTK under some ARM64 Mesa drivers renders a black window without these.
export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
exec "$HERE/AppRun" "$@"
EOF
chmod +x "$STAGE/$NAME/run.sh"

cat > "$STAGE/$NAME/README.txt" <<EOF
OpenWorker $VERSION — Linux $ARCH (self-contained)
=================================================

Unpack anywhere and run ./run.sh  (or ./AppRun directly).

Unlike the plain tarball and the .deb, this build ships its own GUI stack, so it does
NOT need libwebkit2gtk-4.1-0 / libgtk-3-0 / libayatana-appindicator3-1 / librsvg2-2
installed. What it still needs is a C library new enough for the builder's glibc —
this was built on Ubuntu ($(ldd --version | head -1 | sed 's/.* //')) .
EOF

echo "==> writing $BUNDLE/$NAME.tar.gz"
tar -C "$STAGE" -czf "$BUNDLE/$NAME.tar.gz" "$NAME"

echo ""
echo "Bundled GUI libraries (evidence the stack really is inside):"
find "$STAGE/$NAME" -name 'libwebkit2gtk*' -o -name 'libgtk-3.so*' \
     -o -name 'libjavascriptcoregtk*' -o -name 'libayatana-appindicator3*' \
  | sed "s|^$STAGE/$NAME/||" | sort | sed -n '1,20p'
echo "  .so files total: $(find "$STAGE/$NAME" -name '*.so*' | wc -l)"
ls -la "$BUNDLE/$NAME.tar.gz"
