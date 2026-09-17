//! OpenWorker desktop shell, built on **Tauri v1**.
//!
//! This is a deliberate second shell next to `../src-tauri` (Tauri v2), and the only reason it
//! exists is the dependency floor. Tauri v2 hard-requires `webkit2gtk-4.1`; the whole RHEL 8
//! family — which is what Kylin V10 and UOS 20 are built on — ships `webkit2gtk-4.0` and has
//! no 4.1 in any repository. Measured, not assumed: Debian bullseye (the closest distro to
//! those machines' glibc 2.31) publishes `libwebkit2gtk-4.0-dev` and answers "no such package"
//! for `libwebkit2gtk-4.1-dev`. Tauri v1 links against 4.0, so it is the one desktop shell that
//! can build and run there. See README.md for the full evidence.
//!
//! What the SPA sees is identical to the v2 shell:
//!   1. picks a free localhost port and starts the Python `openworker-server` as a child on it
//!      (so it never clashes with a hand-run server on 8765);
//!   2. injects the sidecar HTTP/WS addresses, the per-launch token, and the platform string
//!      before the SPA loads — the frontend stays ONE build with no desktop/browser variant;
//!   3. lives in the system tray: closing the window hides it, tray → Quit stops the sidecar;
//!   4. exposes the same command names as the v2 shell, so `src/tauri.ts` needs no per-shell
//!      code path.
//!
//! Deliberate differences from the v2 shell — each is either a dependency we refused to take
//! or a feature that genuinely cannot exist on Linux:
//!
//!   * **No `ocw-stt` / whisper.** Voice input is macOS + Windows only. The dictation commands
//!     are stubs reporting `supported: false` with the same reason string upstream's own Linux
//!     branch of `voice_input_compatibility()` returns, so the UI looks and behaves the same —
//!     it just no longer drags whisper.cpp, bindgen/libclang, cmake and ALSA into the build.
//!   * **No updater.** Signing keys are release-only secrets and the Linux artifacts are not in
//!     the update manifest (the v2 Linux build says the same). `check_for_update` answers
//!     "up to date" instead of surfacing an error in the UI.
//!   * **No `tauri-plugin-*` crates at all.** They only exist from 2.x upwards — they target
//!     Tauri v2. v1's equivalent is either built in (dialog), or ~20 lines of XDG
//!     (`~/.config/autostart`), or a unix socket (single instance). Fewer crates is also fewer
//!     ways for a v1 build to fail in 2026.
//!   * **Keep-awake is a no-op that still reflects state.** Linux has no portable sleep
//!     inhibitor and upstream's v2 Linux branch already behaves this way.

#[cfg(not(unix))]
compile_error!(
    "src-tauri-v1 is the Linux shell (Tauri v1 + webkit2gtk-4.0 for old-glibc distros). \
     macOS and Windows are served by ../src-tauri (Tauri v2)."
);

use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{
    api::dialog::FileDialogBuilder, CustomMenuItem, Icon, Manager, RunEvent, SystemTray,
    SystemTrayEvent, SystemTrayMenu, WindowEvent, WindowUrl,
};
use uuid::Uuid;

/// The sidecar server child — killed on exit (orphaned servers have bitten us before).
struct ServerProcess(Mutex<Option<Child>>);
/// Whether keep-awake is on. On Linux the "hold" does not exist, so this is just the toggle's
/// state (the UI would otherwise snap back).
struct KeepAwake(Mutex<bool>);
/// Whether a tray icon was created. Drives close-to-tray: with no tray there would be no way to
/// get a hidden window back, so closing must really close.
struct TrayAvailable(Arc<AtomicBool>);

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .and_then(|l| l.local_addr())
        .map(|a| a.port())
        .unwrap_or(8765)
}

fn launch_token() -> String {
    format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

/// Mirror of `coworker.secrets.state_dir()` so the shell and the server agree on `desktop.json`.
/// POSIX: `~/.config/coworker`. `COWORKER_STATE_DIR` overrides.
fn state_dir() -> PathBuf {
    if let Ok(d) = std::env::var("COWORKER_STATE_DIR") {
        return PathBuf::from(d);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".config").join("coworker")
}

/// Same file and same shape the v2 shell uses for `keep_awake`, so running either shell (or
/// both, in turn) keeps one preference rather than two that disagree.
fn desktop_prefs_path() -> PathBuf {
    state_dir().join("desktop.json")
}

/// The sidecar's log file: `<state_dir>/logs/openworker-server.log`, fresh per launch with the
/// previous run kept as `.old`. None (→ /dev/null) only if the directory can't be created —
/// logging must never block startup.
fn server_log_file() -> Option<std::fs::File> {
    let dir = state_dir().join("logs");
    std::fs::create_dir_all(&dir).ok()?;
    let path = dir.join("openworker-server.log");
    if path.exists() {
        let _ = std::fs::rename(&path, dir.join("openworker-server.log.old"));
    }
    std::fs::File::create(&path).ok()
}

fn read_keep_awake_pref() -> bool {
    std::fs::read_to_string(desktop_prefs_path())
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get("keep_awake").and_then(|b| b.as_bool()))
        .unwrap_or(false)
}

fn write_keep_awake_pref(enabled: bool) {
    let path = desktop_prefs_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(
        &path,
        serde_json::json!({ "keep_awake": enabled }).to_string(),
    );
}

// -- single instance ------------------------------------------------------------------
// Tauri v1 has no single-instance plugin (they start at 2.x). This is the minimal equivalent,
// and it needs no dependency: a unix socket doubles as the mutex and as the wake-up channel.
//
// It matters more here than on macOS: a second launch would pick a different free port, spawn a
// second sidecar, and show a second window — and if the first one is hidden in the tray, the
// user sees a window that is not the app they already had running.

fn single_instance_socket() -> PathBuf {
    state_dir().join("openworker.sock")
}

/// `Some(listener)` = we are the first instance and own the socket. `None` = another instance is
/// running and has just been asked to surface its window, so this process must exit.
fn acquire_single_instance() -> Option<UnixListener> {
    let path = single_instance_socket();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(listener) = UnixListener::bind(&path) {
        return Some(listener);
    }
    // Bind failed. Either a live instance holds the socket, or we are looking at the stale file
    // a crashed run left behind — and the difference is simply whether anyone answers. A
    // *successful* connect is also the poke: the holder's accept loop surfaces its window.
    if UnixStream::connect(&path).is_ok() {
        return None;
    }
    let _ = std::fs::remove_file(&path);
    UnixListener::bind(&path).ok()
}

/// Path to the server entrypoint. Resolution order (identical to the v2 shell, so the same
/// bundle layouts work):
///   1. `COWORKER_SERVER_BIN` env override.
///   2. The bundled onedir sidecar shipped via Tauri `resources` (production).
///   3. Legacy onefile slot: `openworker-server` next to the app binary.
///   4. Dev fallback: the repo venv, relative to this crate (`src-tauri-v1` → repo root).
fn server_bin(resource_dir: Option<PathBuf>) -> PathBuf {
    if let Ok(p) = std::env::var("COWORKER_SERVER_BIN") {
        return PathBuf::from(p);
    }
    let exe_name = "openworker-server";
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            // A portable tarball puts `sidecar/` next to the executable; a deb installs it under
            // a per-product folder in `<prefix>/lib`, whose name is the bundler's to choose — so
            // the `lib/` children are scanned rather than guessed at.
            let mut candidates = vec![dir.join("sidecar").join(exe_name)];
            if let Some(prefix) = dir.parent() {
                if let Ok(entries) = std::fs::read_dir(prefix.join("lib")) {
                    for entry in entries.flatten() {
                        candidates.push(entry.path().join("sidecar").join(exe_name));
                    }
                }
            }
            if let Some(rd) = resource_dir {
                candidates.push(rd.join("sidecar").join(exe_name));
            }
            candidates.push(dir.join(exe_name)); // legacy onefile slot
            for c in candidates {
                if c.exists() {
                    return c;
                }
            }
        }
    }
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../../.venv/bin/openworker-server");
    p
}

/// The environment the sidecar should run with.
///
/// Empty on purpose. The v2 shell runs a login-shell probe on macOS because a Finder/Dock
/// launch inherits launchd's minimal PATH and every Homebrew/nvm/pyenv tool becomes invisible.
/// Linux sessions have no equivalent: an app started from the desktop inherits the user session
/// environment (systemd user manager / display manager), which carries the real PATH. Probing a
/// login shell here would add startup latency for nothing — and on a locked-down enterprise
/// image the extra shell could itself be the thing that hangs.
fn sidecar_env() -> std::collections::HashMap<String, String> {
    std::collections::HashMap::new()
}

/// Path to the sidecar's state dir for the *user-visible* case: an autostart entry must be
/// started from the same place the launcher is, so the tarball's `run.sh` (which sets the
/// WebKitGTK workaround variables) wins over the bare executable when it is present.
fn launch_target() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    let run = dir.join("run.sh");
    Some(if run.is_file() { run } else { exe })
}

fn autostart_desktop_file() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".config")
        });
    base.join("autostart").join("openworker.desktop")
}

fn autostart_enabled() -> bool {
    autostart_desktop_file().is_file()
}

/// Open-at-login, implemented directly against the freedesktop spec instead of pulling the
/// autostart plugin (see the module docstring: no v1 plugins exist).
fn set_autostart_enabled(enabled: bool) -> bool {
    let path = autostart_desktop_file();
    if !enabled {
        let _ = std::fs::remove_file(&path);
        return autostart_enabled();
    }
    let Some(target) = launch_target() else {
        return false;
    };
    if let Some(dir) = path.parent() {
        if std::fs::create_dir_all(dir).is_err() {
            return false;
        }
    }
    // Quoted: an unpacked tarball can live under a path with spaces.
    let body = format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=OpenWorker\n\
         Comment=Local-first AI coworker\n\
         Exec=\"{}\"\n\
         Terminal=false\n\
         X-GNOME-Autostart-enabled=true\n",
        target.display()
    );
    std::fs::write(&path, body).is_ok() && autostart_enabled()
}

// -- local dictation -------------------------------------------------------------------
// Stubs. See the module docstring: the whisper engine is macOS + Windows only, so the whole
// `ocw-stt` crate is absent from this build. The shape of the answer is upstream's own Linux
// shape — `supported: false` with a reason — which is what makes the UI hide the feature rather
// than offer a button that cannot work.

#[derive(Clone, Serialize)]
struct VoiceInputStatus {
    recording: bool,
    model_installed: bool,
    model_verified: bool,
    test_passed: bool,
    download_in_progress: bool,
    model_name: &'static str,
    model_bytes: u64,
    supported: bool,
    device_summary: String,
    compatibility_reason: Option<String>,
}

const DICTATION_UNSUPPORTED: &str = "Voice Input is currently supported on macOS and Windows.";

fn voice_input_status() -> VoiceInputStatus {
    VoiceInputStatus {
        recording: false,
        model_installed: false,
        model_verified: false,
        test_passed: false,
        download_in_progress: false,
        model_name: "",
        model_bytes: 0,
        supported: false,
        device_summary: format!("{} · {}", std::env::consts::OS, std::env::consts::ARCH),
        compatibility_reason: Some(DICTATION_UNSUPPORTED.to_owned()),
    }
}

// -- native commands (invoked from the SPA via window.__TAURI__.tauri.invoke) ------------
// Names and signatures match the v2 shell exactly; only the implementation differs.

#[tauri::command]
async fn pick_folder() -> Result<Option<String>, String> {
    // The callback form, not the blocking one: a sync command runs on the GTK main thread and
    // would deadlock the dialog against the event loop. Awaiting the channel on an async
    // command blocks a worker thread instead, which is harmless. (Async commands in v1 are
    // required to return a Result — hence the wrapping, which the UI cannot tell apart.)
    let (tx, rx) = std::sync::mpsc::channel();
    FileDialogBuilder::new().pick_folder(move |p| {
        let _ = tx.send(p);
    });
    Ok(rx
        .recv()
        .ok()
        .flatten()
        .map(|p| p.to_string_lossy().into_owned()))
}

#[tauri::command]
fn get_autostart() -> bool {
    autostart_enabled()
}

#[tauri::command]
fn set_autostart(enabled: bool) -> bool {
    set_autostart_enabled(enabled)
}

#[tauri::command]
fn get_keep_awake(state: tauri::State<'_, KeepAwake>) -> bool {
    *state.0.lock().unwrap()
}

#[tauri::command]
fn set_keep_awake(state: tauri::State<'_, KeepAwake>, enabled: bool) -> bool {
    *state.0.lock().unwrap() = enabled;
    write_keep_awake_pref(enabled);
    enabled
}

#[tauri::command]
fn start_window_drag(window: tauri::Window) -> bool {
    window.start_dragging().is_ok()
}

fn unsupported<T>() -> Result<T, String> {
    Err(DICTATION_UNSUPPORTED.to_owned())
}

#[tauri::command]
fn get_dictation_status() -> VoiceInputStatus {
    voice_input_status()
}

#[tauri::command]
async fn start_dictation() -> Result<VoiceInputStatus, String> {
    unsupported()
}

#[tauri::command]
async fn stop_dictation() -> Result<String, String> {
    unsupported()
}

#[tauri::command]
fn cancel_dictation() {}

#[tauri::command]
async fn download_dictation_model() -> Result<VoiceInputStatus, String> {
    unsupported()
}

#[tauri::command]
fn cancel_dictation_model_download() {}

#[tauri::command]
async fn verify_dictation_model() -> Result<VoiceInputStatus, String> {
    unsupported()
}

#[tauri::command]
fn mark_dictation_test_passed() -> Result<VoiceInputStatus, String> {
    unsupported()
}

#[tauri::command]
fn delete_dictation_model() -> VoiceInputStatus {
    voice_input_status()
}

#[tauri::command]
fn dictation_level() -> f32 {
    0.0
}

#[derive(Serialize)]
struct UpdateInfo {
    version: String,
    notes: String,
}

/// Linux artifacts are not wired into the update manifest and the signing key is a release-only
/// secret, so there is nothing to check against. Answering "up to date" (null) keeps the UI
/// quiet; erroring here would just surface a scary toast for a limitation the user cannot act
/// on. README.txt says plainly that this build does not self-update.
#[tauri::command]
async fn check_for_update() -> Result<Option<UpdateInfo>, String> {
    Ok(None)
}

#[tauri::command]
async fn download_update() -> Result<(), String> {
    Err("This build does not self-update; install a newer tarball instead.".into())
}

#[tauri::command]
fn clear_pending_update() {}

#[tauri::command]
async fn install_update() -> Result<(), String> {
    Err("This build does not self-update; install a newer tarball instead.".into())
}

fn show_main<R: tauri::Runtime>(app: &tauri::AppHandle<R>) {
    if let Some(w) = app.get_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// Whether a tray can exist on this machine at all.
///
/// This probe is not a nicety, it is load-bearing. On Linux the tray goes through appindicator,
/// and the Rust binding resolves it with `dlopen` at *runtime* — in a `Lazy<Library>` that
/// **panics** when none of its four sonames load. So "just try to build the tray and handle the
/// error" would not lose a tray icon on a machine without the library; it would take the whole
/// app down before the window ever appeared. Probe the same four names, in the same order, first.
fn appindicator_available() -> bool {
    const SONAMES: [&str; 4] = [
        "libayatana-appindicator3.so.1",
        "libappindicator3.so.1",
        "libayatana-appindicator3.so",
        "libappindicator3.so",
    ];
    SONAMES.iter().any(|name| {
        // SAFETY: the handle is used for nothing and dropped immediately; the only question being
        // asked is whether the loader can resolve the name.
        unsafe { libloading::Library::new(name) }.is_ok()
    })
}

pub fn run() {
    // Before anything else: if another instance owns the socket we are done, and we must not
    // reach the point of spawning a second sidecar.
    let Some(wake_listener) = acquire_single_instance() else {
        eprintln!("[openworker] another instance is already running — asked it to show its window");
        return;
    };

    let port = free_port();
    let api_token = launch_token();
    let http = format!("http://127.0.0.1:{port}");
    let ws = format!("ws://127.0.0.1:{port}");
    // Debug-format yields a quoted JS string literal.
    let inject = format!(
        "window.__COWORKER_HTTP__={http:?};window.__COWORKER_WS__={ws:?};window.__COWORKER_API_TOKEN__={api_token:?};window.__OCW_PLATFORM__={:?};",
        std::env::consts::OS
    );

    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            pick_folder,
            get_autostart,
            set_autostart,
            get_keep_awake,
            set_keep_awake,
            start_window_drag,
            get_dictation_status,
            start_dictation,
            stop_dictation,
            cancel_dictation,
            download_dictation_model,
            cancel_dictation_model_download,
            verify_dictation_model,
            mark_dictation_test_passed,
            delete_dictation_model,
            dictation_level,
            check_for_update,
            download_update,
            clear_pending_update,
            install_update
        ])
        .setup(move |app| {
            // Another instance asking us to come to the front: a connection on the instance
            // socket IS the message, so there is nothing to parse.
            let app_for_wake = app.handle();
            std::thread::spawn(move || {
                for stream in wake_listener.incoming() {
                    if stream.is_err() {
                        break;
                    }
                    show_main(&app_for_wake);
                }
            });

            // 1. Start the Python server sidecar on the chosen port (inherits our env).
            // Where the bundled `sidecar/` lives is bundle-dependent — ask Tauri for the
            // resource dir and fall back to what `server_bin` knows.
            let resource_dir = app.path_resolver().resource_dir();
            let mut server_cmd = Command::new(server_bin(resource_dir));
            server_cmd
                .args(["--host", "127.0.0.1", "--port", &port.to_string()])
                .envs(sidecar_env())
                // The sidecar self-exits if we die abruptly, so a crash cannot leave an orphan.
                // The explicit PID matters: under PyInstaller onefile the python process is a
                // *grandchild* (bootloader in between), so getppid() never points at us and a
                // reparenting check alone would leak both processes on quit.
                .env("COWORKER_EXIT_WITH_PARENT", "1")
                .env("COWORKER_PARENT_PID", std::process::id().to_string())
                .env("COWORKER_API_TOKEN", &api_token)
                .stdin(Stdio::null());
            // The server's output goes to a log file so field issues are debuggable at all.
            // One file per launch, previous run kept as .old.
            match server_log_file() {
                Some(log) => {
                    if let Ok(err_clone) = log.try_clone() {
                        server_cmd
                            .stdout(Stdio::from(log))
                            .stderr(Stdio::from(err_clone));
                    } else {
                        server_cmd.stdout(Stdio::from(log)).stderr(Stdio::null());
                    }
                }
                None => {
                    server_cmd.stdout(Stdio::null()).stderr(Stdio::null());
                }
            }
            let child = match server_cmd.spawn() {
                Ok(child) => Some(child),
                Err(e) => {
                    eprintln!("[openworker] failed to start server sidecar: {e}");
                    None
                }
            };
            app.manage(ServerProcess(Mutex::new(child)));

            // Restore keep-awake from the last session.
            app.manage(KeepAwake(Mutex::new(read_keep_awake_pref())));

            // 2. Build the window, injecting the sidecar endpoints before the SPA loads.
            let win = tauri::WindowBuilder::new(app, "main", WindowUrl::App("index.html".into()))
                .title("OpenWorker")
                .inner_size(1360.0, 900.0)
                .min_inner_size(980.0, 640.0)
                // Let the WEBVIEW receive OS file drags: Tauri's own drag-drop handler otherwise
                // intercepts them, so the composer's HTML5 onDrop (attach by dragging a file in)
                // never fired. main.tsx guards against drops outside the composer navigating
                // the page.
                .disable_file_drop_handler()
                .initialization_script(&inject)
                .build()?;

            // 3. System tray: Open / Settings / Quit. Best-effort, because the tray is also the
            // only way back to a hidden window: if the tray cannot be created (no
            // libayatana-appindicator3 on this machine, no StatusNotifier host) the app must
            // still start, and close must then really close.
            let tray_up = Arc::new(AtomicBool::new(false));
            app.manage(TrayAvailable(tray_up.clone()));

            if !appindicator_available() {
                eprintln!(
                    "[openworker] system tray unavailable (no libayatana-appindicator3 / \
                     libappindicator3 found) — close-to-tray disabled, closing the window will quit"
                );
            } else {
                let app_for_tray = app.handle();
                let tray = SystemTray::new()
                    .with_tooltip("OpenWorker")
                    .with_icon(Icon::Raw(include_bytes!("../icons/tray.png").to_vec()))
                    .with_menu(
                        SystemTrayMenu::new()
                            .add_item(CustomMenuItem::new("open", "Open OpenWorker"))
                            .add_item(CustomMenuItem::new("settings", "Settings"))
                            .add_item(CustomMenuItem::new("quit", "Quit")),
                    )
                    .on_event(move |event| {
                        if let SystemTrayEvent::MenuItemClick { id, .. } = event {
                            match id.as_str() {
                                "open" => show_main(&app_for_tray),
                                "settings" => {
                                    show_main(&app_for_tray);
                                    if let Some(w) = app_for_tray.get_window("main") {
                                        let _ = w.eval(
                                            "window.dispatchEvent(new CustomEvent('coworker:open-settings'))",
                                        );
                                    }
                                }
                                "quit" => app_for_tray.exit(0),
                                _ => {}
                            }
                        }
                    });
                // Belt-and-braces on top of the probe: a tray can also fail for reasons only GTK
                // knows, and losing a tray icon must never cost the user the app.
                let app_for_build = app.handle();
                let built = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
                    tray.build(&app_for_build)
                }));
                match built {
                    Ok(Ok(_)) => tray_up.store(true, Ordering::SeqCst),
                    Ok(Err(e)) => eprintln!(
                        "[openworker] system tray unavailable ({e}) — close-to-tray disabled, \
                         closing the window will quit"
                    ),
                    Err(_) => eprintln!(
                        "[openworker] system tray panicked during creation — close-to-tray \
                         disabled, closing the window will quit"
                    ),
                }
            }

            // Close-to-tray, but only when there IS a tray to restore from.
            let w = win.clone();
            let tray_flag = app.state::<TrayAvailable>().0.clone();
            win.on_window_event(move |event| {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    if tray_flag.load(Ordering::SeqCst) {
                        let _ = w.hide();
                        api.prevent_close();
                    }
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building the OpenWorker desktop app (Tauri v1)")
        .run(|app, event| {
            // Belt-and-suspenders: a quit path can reach teardown without a preceding
            // ExitRequested.
            if matches!(event, RunEvent::ExitRequested { .. } | RunEvent::Exit) {
                if let Some(state) = app.try_state::<ServerProcess>() {
                    if let Some(mut child) = state.0.lock().unwrap().take() {
                        let _ = child.kill();
                    }
                }
                // Drop the instance socket so the next launch is a first launch.
                let _ = std::fs::remove_file(single_instance_socket());
            }
        });
}
