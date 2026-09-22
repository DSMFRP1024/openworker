#!/bin/bash
# ==============================================================================
# diagnose-linux-gui.sh — field forensics for the Tauri v1 desktop build running
# on a machine whose graphics driver has no working 3D.
#
# Two field reports, each with a candidate root cause to be proven or killed:
#
#   1. the WHOLE MACHINE stutters while OpenWorker is running
#   2. the WHOLE APP EXITS the instant the user right-clicks anywhere
#
# Report 2 is the sharp one, and it narrows itself. "The whole app exits" is NOT
# a renderer fault: when a WebKitWebProcess dies, the window survives and goes
# blank. A process that vanishes entirely died in the UI process (the GTK/WebKit
# main process) — and on this stack there are exactly three ways that happens:
#
#   CLASS 1  X11 protocol error -> GDK's X error handler calls g_error() -> abort()
#            signature: "received an X Window System error."
#                       "X Error of failed request: BadMatch|BadWindow|BadDrawable"
#            The leading candidate for "dies the moment a menu appears": the popup
#            menu is a brand-new X window, and an X error is fatal by default.
#   CLASS 2  GLib/GTK fatal critical (g_error / g_assert) -> abort()
#            signature: "Gtk-CRITICAL **:", "Gdk-Message: ...", "ERROR:..."
#   CLASS 3  SIGSEGV inside the UI process (the bundled 2.44 GBM/EGL path)
#            signature: nothing useful on stderr; only a backtrace shows it.
#
# The exit status alone already splits them: 134 = SIGABRT (class 1 or 2),
# 139 = SIGSEGV (class 3). Every launch below records it.
#
# READ-ONLY BY CONSTRUCTION. No system setting is changed, nothing is installed,
# and nothing outside ./diagnose-report-<time>/ is written. Each experiment is an
# environment variable handed to one short-lived launch.
#
# Usage:
#   ./diagnose-linux-gui.sh /path/to/openworker-0.2.1-linux-aarch64-desktop.AppImage
#   ./diagnose-linux-gui.sh --env-only /path/to/anything    # skip every launch
#
# Exit codes: 0 = report written, 1 = the app could not start at all, 2 = bad usage.
# ==============================================================================

set -u

APP="${1:-}"
MODE="full"
case "${1:-}" in
  --env-only) MODE="env"; APP="${2:-}" ;;
  -h|--help)  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
esac

if [ -z "$APP" ]; then
  echo "usage: $0 [--env-only] /path/to/openworker-*-desktop.AppImage" >&2
  exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
[ -e "$APP" ] || { echo "no such file: $APP" >&2; exit 2; }
WORKDIR="$(dirname "$APP")"

# A FUSE-less host (containers, hardened images, a missing libfuse2) cannot mount the
# AppImage, so every launch below would just report "never came up" and the report would
# be useless. The runtime's own extraction path runs the SAME AppDir through the SAME
# AppRun, so the evidence is still about the artifact rather than about the test rig.
EXTRACT=""
case "$APP" in
  *.AppImage)
    if [ ! -r /dev/fuse ] \
       || { ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; }; then
      EXTRACT="APPIMAGE_EXTRACT_AND_RUN=1"
    fi
    ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="diagnose-report-$STAMP"
mkdir -p "$OUT"
LOG="$OUT/report.txt"

# Tee everything to the terminal and to the report. Deliberately no `set -e`:
# a diagnostic has to survive its own failed probes and keep collecting.
say()   { printf '%s\n' "$*" | tee -a "$LOG"; }
head1() { say ""; say "==================================================================="; say "== $*"; say "==================================================================="; }
have()  { command -v "$1" >/dev/null 2>&1; }

say "OpenWorker desktop — field diagnostic"
say "app  : $APP"
say "when : $(date)"
say "host : $(uname -srm)"
say "report dir: $(pwd)/$OUT"

# ------------------------------------------------------------------------------
head1 "1. HOST"
# ------------------------------------------------------------------------------
if [ -r /etc/os-release ]; then . /etc/os-release; say "distro    : ${PRETTY_NAME:-unknown}"; fi
say "kernel    : $(uname -r)"
say "arch      : $(uname -m)"
say "glibc     : $(ldd --version 2>/dev/null | head -1)"
have nproc && say "cpus      : $(nproc)"
if [ -r /proc/meminfo ]; then
  say "memory    : $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
  say "swap      : $(awk '/SwapTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
fi

# ------------------------------------------------------------------------------
head1 "2. SESSION (X11 vs Wayland decides which GDK/WebKit path is taken)"
# ------------------------------------------------------------------------------
say "XDG_SESSION_TYPE    = ${XDG_SESSION_TYPE:-<unset>}"
say "DISPLAY             = ${DISPLAY:-<unset>}"
say "WAYLAND_DISPLAY     = ${WAYLAND_DISPLAY:-<unset>}"
say "XDG_CURRENT_DESKTOP = ${XDG_CURRENT_DESKTOP:-<unset>}"
say "GDK_BACKEND         = ${GDK_BACKEND:-<unset>}   (linuxdeploy's GTK hook forces x11)"
say "XDG_RUNTIME_DIR     = ${XDG_RUNTIME_DIR:-<unset>}"
case "${XDG_SESSION_TYPE:-}" in
  x11)     say "  -> X11 session: the CLASS 1 (X protocol error) reading applies directly." ;;
  wayland) say "  -> Wayland session: the app forces GDK_BACKEND=x11, so an X server"
           say "     (XWayland) is still in the path and CLASS 1 is still possible." ;;
esac

# ------------------------------------------------------------------------------
head1 "3. GPU / DRM — the 'no 3D' claim, checked rather than assumed"
# ------------------------------------------------------------------------------
say "-- /dev/dri (absent or unreadable => no GPU node at all) --"
ls -l /dev/dri 2>/dev/null | tee -a "$LOG" || say "  /dev/dri: ABSENT"
say ""
say "-- display adapters --"
if have lspci; then
  lspci 2>/dev/null | grep -iE 'vga|3d|display' | tee -a "$LOG" || say "  none matched"
else
  say "  lspci not installed"
fi
say ""
say "-- kernel graphics modules loaded --"
ls /sys/module 2>/dev/null | grep -iE 'nvidia|amdgpu|radeon|i915|virtio_gpu|qxl|vmwgfx|mgag200|v3d|etnaviv|panfrost|lima|zx|loongson|hibmc|ast' | tee -a "$LOG" || say "  none matched"
say ""
say "-- Mesa DRI drivers present (llvmpipe/swrast = software rasteriser) --"
ls /usr/lib/*/dri/ 2>/dev/null | tee -a "$LOG" || say "  no /usr/lib/*/dri directory"
say ""
say "-- render nodes usable by a plain EGL/GBM client? --"
for n in /dev/dri/renderD*; do
  [ -e "$n" ] || continue
  say "  $n  perms=$(stat -c '%A %U:%G' "$n" 2>/dev/null)"
done

# ------------------------------------------------------------------------------
head1 "4. OPENGL CAPABILITY"
# ------------------------------------------------------------------------------
if have glxinfo; then
  glxinfo -B 2>&1 | tee -a "$LOG" | head -20
else
  say "glxinfo not installed (mesa-utils). Skipping; the launches below are the real test."
fi

# ------------------------------------------------------------------------------
head1 "5. WHICH WebKitGTK THIS APP WILL ACTUALLY USE"
# ------------------------------------------------------------------------------
# The single most important fact in the report. WebKitGTK's rendering semantics
# changed at 2.42/2.43/2.44, so WEBKIT_DISABLE_* does not mean the same thing on
# every version. 2.44's own release notes: "The X11 and WPE renderers have been
# removed in favor of the DMA-BUF one." So on 2.44 the DMA-BUF renderer is the
# ONLY accelerated one — disabling it does not reroute, it removes acceleration.
case "$APP" in
  *.AppImage)
    say "AppImage => carries its OWN WebKitGTK; the host's version is irrelevant."
    say "FUSE     : $([ -n "$EXTRACT" ] && echo 'unavailable -> probes will self-extract' || echo 'available')"
    EX="$(mktemp -d)"
    if ( cd "$EX" && "$APP" --appimage-extract 'usr/lib/*/libwebkit2gtk-4.0.so.37*' >/dev/null 2>&1 ); then
      LIB="$(find "$EX" -name 'libwebkit2gtk-4.0.so.37' 2>/dev/null | head -1)"
      if [ -n "$LIB" ]; then
        VER="$(grep -a -o -m1 -E '2\.(3[0-9]|4[0-9]|5[0-9])\.[0-9]+' "$LIB" 2>/dev/null)"
        say "bundled libwebkit2gtk-4.0.so.37 : $LIB"
        say "bundled WebKitGTK version       : ${VER:-<not extractable — read it from the CI log>}"
        case "${VER:-}" in
          2.4[4-9]*|2.5[0-9]*)
            say "  -> 2.44+ : X11/Wayland accel backing stores were removed in the 2.43.x"
            say "     cycle. WEBKIT_DISABLE_DMABUF_RENDERER=1 therefore does not change the"
            say "     transport — it removes accelerated compositing entirely and drops the"
            say "     view to CPU rasterisation. That is the stutter in report 1."
            ;;
          2.4[0-3]*) say "  -> 2.40-2.43 : the DMA-BUF renderer exists; the 2.44 fallout does not apply yet." ;;
          2.3*)      say "  -> 2.3x : predates the DMA-BUF renderer entirely." ;;
        esac
      else
        say "could not extract libwebkit2gtk-4.0.so.37 from the AppImage"
      fi
    else
      say "AppImage --appimage-extract failed (no FUSE is fine; this path does not use it)"
      say "workaround: APPIMAGE_EXTRACT_AND_RUN=1 ./$(basename "$APP") --appimage-extract"
    fi
    rm -rf "$EX" 2>/dev/null || true
    ;;
  *)
    say "tarball / script => uses the SYSTEM WebKitGTK."
    if have dpkg; then
      dpkg -l 2>/dev/null | grep -E 'libwebkit2gtk-4\.0|libjavascriptcoregtk-4\.0' | tee -a "$LOG"
    elif have rpm; then
      rpm -qa 2>/dev/null | grep -E 'webkit2gtk3|javascriptcoregtk' | tee -a "$LOG"
    fi
    have pkg-config && say "pkg-config webkit2gtk-4.0 : $(pkg-config --modversion webkit2gtk-4.0 2>/dev/null || echo '<absent>')"
    BIN="$(dirname "$APP")/openworker-desktop"
    if [ -x "$BIN" ] && have ldd; then
      say "-- the shell's own WebKit linkage --"
      ldd "$BIN" 2>/dev/null | grep -iE 'webkit|javascriptcore|gtk-3|soup' | tee -a "$LOG"
    fi
    ;;
esac

# ------------------------------------------------------------------------------
head1 "6. ACCESSIBILITY BUS + WHO OWNS THE MENU WIDGETS"
# ------------------------------------------------------------------------------
# A GTK popup menu is the first interaction that emits AT-SPI state-change events
# AND builds widgets from the bundled theme/icon modules. Both are bundled in this
# AppImage, so both are suspect when the death is exactly at menu time.
say "AT_SPI_BUS_ADDRESS = ${AT_SPI_BUS_ADDRESS:-<unset>}"
say "NO_AT_BRIDGE       = ${NO_AT_BRIDGE:-<unset>}"
say "GTK_MODULES        = ${GTK_MODULES:-<unset>}"
if have dbus-send; then
  say "-- is there a session accessibility bus to talk to? --"
  dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus \
    org.freedesktop.DBus.Peer.Ping 2>&1 | head -4 | tee -a "$LOG"
fi
say ""
say "-- menu-relevant resources the AppImage carries (not the host's) --"
if [ -n "$(command -v unsquashfs || true)" ] && case "$APP" in *.AppImage) true;; *) false;; esac; then
  say "  unsquashfs is available: you can inspect the payload with"
  say "    unsquashfs -l $(basename "$APP") | grep -E 'gtk-3.0|immodules|loaders.cache|themes|atk-bridge'"
fi

[ "$MODE" = "env" ] && { say ""; say "(--env-only: skipping every launch)"; say "report: $(pwd)/$LOG"; exit 0; }

# ------------------------------------------------------------------------------
# PROBE MACHINERY
# ------------------------------------------------------------------------------
# pgrep pattern note: "openworker-desktop" cannot match this script's own cmdline
# (that ends in ...-aarch64-desktop.AppImage), so there is no self-match.
app_up() { pgrep -f openworker-desktop >/dev/null 2>&1; }
uipid()  { pgrep -f openworker-desktop 2>/dev/null | head -1; }
wppid()  { pgrep -f WebKitWebProcess 2>/dev/null | head -1; }

# Right-click the window centre with XTEST. Returns 0 if the click was sent.
send_right_click() {
  have xdotool || return 1
  local xw
  xw="$(xdotool search --name 'OpenWorker' 2>/dev/null | head -1)"
  [ -n "$xw" ] || return 1
  local WIDTH=0 HEIGHT=0
  eval "$(xdotool getwindowgeometry --shell "$xw" 2>/dev/null)"
  [ "${WIDTH:-0}" -gt 10 ] 2>/dev/null || return 1
  say "    right-clicking window $xw at $((WIDTH/2)),$((HEIGHT/2))"
  xdotool mousemove --window "$xw" $((WIDTH/2)) $((HEIGHT/2)) 2>/dev/null
  xdotool click 3 2>/dev/null
}

# Turn an exit status into the abort class it implies.
explain_status() {
  case "${1:-}" in
    134) say "    status 134 = SIGABRT  -> g_error()/g_assert()/abort().  CLASS 1 or CLASS 2:" ;;
    139) say "    status 139 = SIGSEGV  -> memory fault.  CLASS 3 — a backtrace is required." ;;
    133) say "    status 133 = SIGTRAP  -> a fatal critical stopped it (G_DEBUG=fatal-criticals)." ;;
    0)   say "    status 0   -> clean exit (something asked the app to quit)." ;;
    *)   say "    status $1  (128+n => signal n)" ;;
  esac
}

# Scan one captured stderr log and name the class it shows.
classify_log() {
  local f="$1"
  [ -f "$f" ] || { say "    (no stderr captured)"; return 0; }
  say ""
  say "    -- class detection in $(basename "$f") --"
  if grep -qE 'received an X Window System error|X Error of failed request' "$f" 2>/dev/null; then
    say "    CLASS 1 CONFIRMED: X11 protocol error. GDK's X error handler calls g_error(),"
    say "    which aborts the process outright — matching a death exactly at popup time."
    grep -nE 'X Error|failed request|Major opcode|Minor opcode|BadWindow|BadMatch|BadDrawable|BadAlloc|BadLength|received an X' "$f" | head -12 | tee -a "$LOG"
  fi
  if grep -qE 'Gtk-CRITICAL|Gdk-CRITICAL|GLib-GObject-CRITICAL|GLib-CRITICAL|Gdk-Message|Gtk-Message|^\*\*|ERROR:' "$f" 2>/dev/null; then
    say "    CLASS 2 CANDIDATE: GLib/GTK critical or a fatal Gdk-Message."
    grep -nE 'CRITICAL|Gdk-Message|Gtk-Message|WARNING|ERROR:' "$f" | tail -15 | tee -a "$LOG"
  fi
  if grep -qiE 'segmentation fault|SIGSEGV|core dumped' "$f" 2>/dev/null; then
    say "    CLASS 3 CANDIDATE: SIGSEGV."
  fi
  say ""
  say "    -- last 40 lines of stderr --"
  tail -n 40 "$f" | tee -a "$LOG"
}

# One launch, wait for the window, right-click it, and report what happened.
# usage: probe <label> [VAR=VAL ...]
probe() {
  local label="$1"; shift
  local log="$OUT/run-$label.log"
  local rc=0 ui_before wp_before ui_after wp_after clicked=0

  say ""
  say "-- probe [$label]  env: ${*:-<none — the shipped default>} --"
  (
    cd "$WORKDIR" || exit 3
    ulimit -c unlimited 2>/dev/null || true
    if [ "$#" -gt 0 ]; then env "$@" "$APP" >"$log" 2>&1; else "$APP" >"$log" 2>&1; fi
  ) &
  local pid=$!
  local i=0
  while [ "$i" -lt 45 ]; do
    app_up && break
    kill -0 "$pid" 2>/dev/null || break
    i=$((i + 1)); sleep 1
  done

  if ! app_up; then
    wait "$pid" 2>/dev/null; rc=$?
    say "    the app never came up (exit=$rc)."
    tail -n 20 "$log" 2>/dev/null | tee -a "$LOG"
    return 1
  fi

  ui_before="$(uipid)"; wp_before="$(wppid)"
  say "    before  UIProcess pid=${ui_before:-<none>}  WebProcess pid=${wp_before:-<none>}"
  sleep 4

  send_right_click && clicked=1 || say "    (could not drive xdotool — right-click MANUALLY now, 20 s)"
  [ "$clicked" -eq 1 ] || sleep 20
  sleep 6

  if kill -0 "$pid" 2>/dev/null; then
    ui_after="$(uipid)"; wp_after="$(wppid)"
    say "    after   UIProcess pid=${ui_after:-<none>}  WebProcess pid=${wp_after:-<none>}"
    if [ -n "$ui_after" ]; then
      say "    VERDICT[$label]: SURVIVED the right-click."
      if [ -z "$wp_after" ] && [ -n "$wp_before" ]; then
        say "      (but WebKitWebProcess is gone — the renderer died: window would be blank)"
      fi
    else
      say "    VERDICT[$label]: UI process gone while the launcher still lives."
    fi
    return 0
  fi

  wait "$pid" 2>/dev/null; rc=$?
  say "    VERDICT[$label]: THE WHOLE APP EXITED on the right-click."
  explain_status "$rc"
  classify_log "$log"
  return 1
}

# ------------------------------------------------------------------------------
head1 "7. LIVE PROBES — reproduce, then bisect the two overrides"
# ------------------------------------------------------------------------------
say "Each probe launches the app, waits for its window, right-clicks the centre,"
say "and records the exit status. Nothing is left running: each probe is waited on."
say ""
say "Reminder of what the shipped launcher does (packaging/build_desktop_v1*.sh):"
say "  WEBKIT_DISABLE_COMPOSITING_MODE=\${...:-1}"
say "  WEBKIT_DISABLE_DMABUF_RENDERER=\${...:-1}"
say "Both are \${VAR:-1}, so an explicit value from this shell wins — which is what"
say "makes the bisect below possible without rebuilding anything."

if app_up; then
  say ""
  say "!! an OpenWorker is already running; close it first for a clean report."
fi

DEAD=0
probe "A-shipped-default" || DEAD=1
probe "B-let-webkit-choose" WEBKIT_DISABLE_COMPOSITING_MODE=0 WEBKIT_DISABLE_DMABUF_RENDERER=0 || true
probe "C-compositing-off-only" WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=0 || true
probe "D-x-errors-synchronous" GDK_SYNCHRONIZE=1 || true
probe "E-no-a11y-bridge" NO_AT_BRIDGE=1 || true

# ------------------------------------------------------------------------------
head1 "8. BACKTRACE — only relevant if a probe died with SIGSEGV"
# ------------------------------------------------------------------------------
# Nothing on stderr identifies a SIGSEGV; a stack is the only way to place it.
# Optional: skipped silently when gdb is not installed.
if [ "$DEAD" = "1" ] && have gdb; then
  say "gdb found — re-running the shipped default under it and right-clicking again."
  say "This takes ~30 s. The backtrace lands in $OUT/gdb-backtrace.log"
  (
    cd "$WORKDIR" || exit 3
    gdb -q -batch \
      -ex 'set pagination off' \
      -ex 'set confirm off' \
      -ex 'handle SIG33 nostop noprint pass' \
      -ex run \
      -ex 'printf "\n===== BACKTRACE (all threads) =====\n"' \
      -ex 'thread apply all bt' \
      --args "$APP" >"$OUT/gdb-backtrace.log" 2>&1
  ) &
  local_gdb_pid=$!
  i=0
  while [ "$i" -lt 45 ]; do app_up && break; sleep 1; i=$((i + 1)); done
  sleep 4
  send_right_click || say "  (no xdotool window — right-click MANUALLY now, 20 s)"
  sleep 20
  kill "$local_gdb_pid" 2>/dev/null || true
  say ""
  say "-- backtrace tail --"
  tail -n 60 "$OUT/gdb-backtrace.log" 2>/dev/null | tee -a "$LOG"
elif [ "$DEAD" = "1" ]; then
  say "gdb is not installed, so no backtrace was taken."
  say "If the status above was 139 (SIGSEGV), install it and re-run just this part:"
  say "  sudo apt install gdb        # or: sudo yum install gdb"
  if have coredumpctl; then
    say ""
    say "-- recent core dumps (a SIGSEGV from the app appears here) --"
    coredumpctl list 2>/dev/null | tail -10 | tee -a "$LOG"
    say "  then:  coredumpctl debug openworker-desktop   (then: bt)"
  fi
  say ""
  say "-- kernel's own record of the signal --"
  if have dmesg; then
    dmesg 2>/dev/null | grep -iE 'segfault|trap|openworker' | tail -10 | tee -a "$LOG" \
      || say "  (dmesg not readable without root — that is fine, coredumpctl above is better)"
  fi
fi

# ------------------------------------------------------------------------------
head1 "9. READ THIS BACK — how to interpret the grid, and what to send"
# ------------------------------------------------------------------------------
say "The five probes form a decision table:"
say ""
say "  If A-SHIPPED-DEFAULT died and D-X-ERRORS-SYNCHRONOUS prints an 'X Error of"
say "  failed request' with a Bad* code  ->  CLASS 1 confirmed, and the Bad* code"
say "  names the exact X call. Send that line."
say ""
say "  If B-LET-WEBKIT-CHOOSE survives the right-click AND stops the stutter"
say "  ->  the two unconditional overrides are the whole story; the fix is to stop"
say "      forcing them (make them opt-in) rather than to patch anything else."
say ""
say "  If every probe dies the same way with status 134 and no X error on stderr"
say "  ->  CLASS 2: read the Gtk-CRITICAL / Gdk-Message line right above the death."
say ""
say "  If every probe dies with status 139 (SIGSEGV)  ->  CLASS 3: the backtrace in"
say "      step 8 is the deliverable; without it the next step is guesswork."
say ""
say "  If F-PURE-SOFTWARE-GL survives while A-SHIPPED-DEFAULT dies  ->  the driver is"
say "  in the loop and the crash needs the GPU path to be reached; F is then a usable"
say "  stop-gap for users on such machines, not just a bisect step."
say ""
say "Send back:"
say "  $OUT/report.txt"
say "  $OUT/run-A-shipped-default.log   (and the other run-*.log that died)"
say "  $OUT/gdb-backtrace.log           (if step 8 ran)"
say ""
say "report written to: $(pwd)/$LOG"
