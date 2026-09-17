# `src-tauri-v1` — the Tauri v1 shell (for old-glibc distros)

A second, Linux-only desktop shell for OpenWorker. It exists for one reason, and it is worth
stating precisely, because it is not a packaging preference.

## Why Tauri v1

Tauri v2 hard-requires **`webkit2gtk-4.1`**. The entire RHEL 8 family — which is what
**Kylin V10** and **UOS 20** are built on — ships `webkit2gtk-4.0` and has **no 4.1 package in
any repository**. That is a hard stop: no bundler trick, no bundled copy of WebKit, and no
`apt install` can produce it there.

Measured on Debian bullseye, the closest published distro to those machines (`glibc 2.31`):

| Package | bullseye |
|---|---|
| `libwebkit2gtk-4.0-dev` | **present** (2.50.6-1~deb11u1) |
| `libwebkit2gtk-4.1-dev` | **`no such package`** |

Tauri v1 links against **4.0**, so it is the one desktop shell that can be built and run
against those machines' WebKitGTK — and building it on bullseye also pins the artifact's glibc
floor to 2.31, matching the target exactly.

## What is (deliberately) different from the v2 shell

The SPA cannot tell the two apart: same command names, same injected globals, so
`src/tauri.ts` has no per-shell branch beyond accepting both `__TAURI__.tauri` (v1) and
`__TAURI__.core` (v2).

| | v2 shell (`../src-tauri`) | this shell |
|---|---|---|
| WebKitGTK | 4.1 | **4.0** |
| Plugins | `tauri-plugin-dialog/autostart/single-instance/updater` | **none** |
| Folder picker | `tauri-plugin-dialog` | built-in `tauri::api::dialog` |
| Open at login | `tauri-plugin-autostart` | writes `~/.config/autostart/openworker.desktop` |
| Single instance | `tauri-plugin-single-instance` | a unix socket in the state dir |
| Auto-update | `tauri-plugin-updater` | stubbed — "up to date" |
| Voice input | `ocw-stt` (whisper.cpp) | stubbed — `supported: false` |
| Platforms | macOS, Windows, Linux | **Linux only** (`compile_error!` elsewhere) |

The plugin crates start at 2.x — they target Tauri v2 — so there is no v1 build of any of them
to depend on. The three that were genuinely needed are a built-in, ~20 lines of XDG, and ~30
lines of unix socket, which is also fewer things that can break in an old toolchain.

Dropping `ocw-stt` is not a loss: its whisper engine supports macOS and Windows only, so the
dictation commands here return the same `supported: false` answer upstream's own Linux branch
of `voice_input_compatibility()` returns — and the build no longer needs bindgen/libclang,
cmake, or ALSA.

## One trap worth knowing about

On Linux the tray goes through appindicator, and the Rust binding (`libappindicator-sys`,
reached via `tao/tray`) resolves it with `dlopen` **at runtime** — inside a `Lazy<Library>`
that **panics** when none of its four sonames load. So "create the tray and handle the error"
would not cost a tray icon on a machine without that library; it would take the whole app down
before the window ever appeared.

`lib.rs` therefore probes the same four sonames first (`appindicator_available()`) and wraps
creation in `catch_unwind` as a second line of defence. Without the library the app starts
normally, loses only the tray icon, and closing the window quits instead of hiding to the tray
— which is the other half of the fix: a hidden window with no tray is an unreachable window.

## Building it

Not with the Tauri CLI: `@tauri-apps/cli` v2 cannot build a v1 app, and installing the v1 CLI
just to compile is an extra moving part. `packaging/build_desktop_v1.sh` runs the frontend
build, then plain `cargo build --release --features custom-protocol` (that feature is what
embeds `../dist` into the binary), then asserts the glibc ceiling and assembles the tarball.

Requires `libwebkit2gtk-4.0-dev`, `libgtk-3-dev`, `libsoup2.4-dev`,
`libayatana-appindicator3-dev`, `librsvg2-dev`, `pkg-config` and a Rust toolchain.
