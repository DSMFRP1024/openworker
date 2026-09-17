#!/usr/bin/env bash
# Build the browser-served ("service mode") Linux bundle for the HOST architecture.
#
# Why this exists next to build_linux.sh: the desktop build needs a Tauri GUI stack
# (webkit2gtk-4.1 + a recent glibc). Distros on the RHEL 8 base — Kylin V10 in particular —
# ship webkit2gtk-4.0 only and glibc 2.31, so the desktop shell cannot be built for them at
# all. Service mode drops the shell: the same FastAPI sidecar serves the prebuilt GUI on one
# port and any local browser is the client. Output is a self-contained tarball that needs no
# package manager, no FUSE, no root, and no system GUI libraries.
#
# Phases:
#   1. Build the GUI (`npm ci && npm run build`) → surfaces/gui/dist
#   2. PyInstaller-bundle the server (COWORKER_SERVICE=1 selects service_entry.py)
#   3. Stage `sidecar/` + `web/` + run.sh + README + a systemd unit template
#   4. Assert the glibc ceiling with packaging/check_glibc_ceiling.py, then tar it up
#
# Prerequisites:
#   - A Python with the project installed plus PyInstaller: `pip install -e '.[bedrock]'
#     pyinstaller typer` (typer is build-time only: PyInstaller walks `mcp`, whose CLI exits
#     at import without it). Point at it with OCW_PYTHON.
#   - Node/npm for the GUI build (skipped when OCW_SKIP_WEB=1 and surfaces/gui/dist exists).
#
# ARCH: PyInstaller cannot cross-compile — the frozen CPython decides the target. For a
# glibc-2.31 target, build INSIDE a glibc-2.31 image (`python:3.11-slim-bullseye`); GitHub's
# ubuntu-24.04-arm runner alone would stamp 2.39 on everything. See
# .github/workflows/kylin-arm64.yml.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$HERE/.." && pwd)"
GUI="$PLATFORM/surfaces/gui"

# Interpreter that has this project + PyInstaller installed. A container build uses system
# python3; a dev box uses the repo venv.
if [ -n "${OCW_PYTHON:-}" ]; then
  PY="$OCW_PYTHON"
elif [ -x "$PLATFORM/.venv/bin/python" ]; then
  PY="$PLATFORM/.venv/bin/python"
else
  PY="python3"
fi

# Version comes from tauri.conf.json (the project's single source of truth for it), read with
# the same interpreter so this script needs no Node just to learn its own version.
VERSION="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
  "$GUI/src-tauri/tauri.conf.json")"

TRIPLE="$(uname -m)-unknown-linux-gnu"
ARCH="$(uname -m)"
STAGE_NAME="openworker-$VERSION-linux-$ARCH-service"
OUT="$HERE/dist-service"
STAGE="$OUT/$STAGE_NAME"
# Oldest glibc we promise to run on. Kylin V10 (aarch64) is 2.31; Debian 11 is exactly 2.31,
# which is why it is the build base.
GLIBC_MAX="${OCW_GLIBC_MAX:-2.31}"

echo "==> target: $TRIPLE  version: $VERSION  glibc ceiling: $GLIBC_MAX"
echo "==> python: $PY ($("$PY" -c 'import platform,sys;print(sys.version.split()[0], platform.libc_ver())'))"

echo "==> [1/5] building the GUI (vite)"
if [ "${OCW_SKIP_WEB:-0}" = "1" ] && [ -f "$GUI/dist/index.html" ]; then
  echo "    OCW_SKIP_WEB=1 and surfaces/gui/dist exists — reusing it"
else
  ( cd "$GUI" && npm ci --no-audit --no-fund && npm run build )
fi
[ -f "$GUI/dist/index.html" ] || { echo "ERROR: GUI build produced no $GUI/dist/index.html" >&2; exit 1; }

echo "==> [2/5] PyInstaller: freezing the server (service entry point)"
COWORKER_SERVICE=1 "$PY" -m PyInstaller --noconfirm --clean \
  --distpath "$HERE/dist-service-build/dist" \
  --workpath "$HERE/dist-service-build/work" \
  "$HERE/openworker-server.spec"

echo "==> [3/5] staging the bundle"
rm -rf "$OUT"
mkdir -p "$STAGE/sidecar" "$STAGE/web"
cp -RL "$HERE/dist-service-build/dist/openworker-service/." "$STAGE/sidecar/"
chmod +x "$STAGE/sidecar/openworker-service"
# The GUI is plain static assets — copy, don't link, so the tarball is complete on its own.
cp -RL "$GUI/dist/." "$STAGE/web/"

cat > "$STAGE/run.sh" <<'EOF'
#!/bin/sh
# Start OpenWorker and open the printed URL in a browser.
#
#   ./run.sh                         # 127.0.0.1:8765
#   ./run.sh --port 8899             # different port
#   COWORKER_HOST=0.0.0.0 ./run.sh   # reachable from other machines (see README security note)
#
# POSIX sh, not bash: a minimal Debian/Ubuntu container has no bash, and this launcher has to
# work wherever the tarball is unpacked.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
export COWORKER_WEB_DIR="${COWORKER_WEB_DIR:-$HERE/web}"
exec "$HERE/sidecar/openworker-service" \
  --host "${COWORKER_HOST:-127.0.0.1}" \
  --port "${COWORKER_PORT:-8765}" \
  --web "$COWORKER_WEB_DIR" ${@+"$@"}   # idiom: pass "$@" verbatim under `set -u`
EOF
chmod +x "$STAGE/run.sh"

cat > "$STAGE/openworker.service" <<'EOF'
# systemd unit template — edit User= and the paths, then:
#   sudo cp openworker.service /etc/systemd/system/ && sudo systemctl enable --now openworker
# Leave --host at 127.0.0.1 unless you intend the API to be reachable from the network: the
# token in the URL is the only thing standing between the caller and shell/file tools.
[Unit]
Description=OpenWorker (browser-served)
After=network-online.target

[Service]
Type=simple
User=REPLACE_ME
WorkingDirectory=REPLACE_ME_ABSOLUTE_PATH
ExecStart=REPLACE_ME_ABSOLUTE_PATH/run.sh
Restart=on-failure
# The token and workspace state live under ~/.config/coworker.
Environment=COWORKER_HOST=127.0.0.1
Environment=COWORKER_PORT=8765

[Install]
WantedBy=multi-user.target
EOF

cat > "$STAGE/README.txt" <<EOF
OpenWorker $VERSION — Linux $ARCH, browser-served ("service mode")
=================================================================

Built against glibc $GLIBC_MAX, so it runs on Kylin V10 / Debian 11 / Ubuntu 20.04 and newer.
No package manager, no root, no FUSE, and no system GUI libraries are needed: everything
(CPython, the agent runtime, and the GUI) is inside this folder.

Start it
--------
    ./run.sh                     # serves http://127.0.0.1:8765/
    ./run.sh --port 8899         # pick another port

Then open the printed URL in a browser on this machine. The startup banner also prints the
path of the launch-token file (~/.config/coworker/sidecar-<port>.token); that token is already
wired into the page, so the browser needs nothing else.

Headless box? Tunnel to it from the machine with the browser:
    ssh -L 8765:127.0.0.1:8765 <user>@<this-host>
and open http://127.0.0.1:8765/ locally.

Layout
------
    sidecar/     the Python agent server (frozen CPython; no Python install required)
    web/         the built GUI served by the sidecar
    run.sh       launcher
    openworker.service   systemd unit template

Why not the desktop app
-----------------------
The desktop build needs Tauri's GUI stack: webkit2gtk-4.1 and a newer glibc (>= 2.39 as built).
Kylin V10 has neither (RHEL 8 base: webkit2gtk-4.0 only, glibc 2.31), so this variant serves
the identical GUI over HTTP instead. Same server, same frontend, same features minus the
desktop-only voice input.

Security
--------
The server listens on 127.0.0.1 by default and every request needs the launch token. Setting
COWORKER_HOST=0.0.0.0 exposes shell and file tools to anyone who can reach the port: only do
it on a trusted network.
EOF

echo "==> [4/5] asserting the glibc ceiling ($GLIBC_MAX)"
"$PY" "$HERE/check_glibc_ceiling.py" --max "$GLIBC_MAX" "$STAGE"

echo "==> [5/5] packaging"
TAR="$OUT/$STAGE_NAME.tar.gz"
tar -C "$OUT" -czf "$TAR" "$STAGE_NAME"
( cd "$OUT" && "$PY" -c '
import hashlib,sys
p=sys.argv[1]
h=hashlib.sha256()
with open(p,"rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print("%s  %s" % (h.hexdigest(), p))' "$STAGE_NAME.tar.gz" ) | tee "$OUT/SHA256SUMS"

echo ""
echo "Done. $(du -h "$TAR" | cut -f1) -> $TAR"
