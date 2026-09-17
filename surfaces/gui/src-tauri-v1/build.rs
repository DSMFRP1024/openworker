fn main() {
    // No resource staging here, unlike ../src-tauri/build.rs — and that difference is deliberate.
    //
    // `bundle.resources` is intentionally absent from tauri.conf.json. On v1, `tauri-build` does
    // not merely *validate* resource paths: it copies them into `target/<profile>/` on every
    // build (`copy_resources` in tauri-build/src/lib.rs). Pointing it at the PyInstaller onedir
    // sidecar would therefore duplicate the entire ~200 MB bundle — tens of thousands of files —
    // into target/ on every single build, to populate a `resource_dir()` that nothing consumes:
    // `bundle.active` is false (see the header of packaging/build_desktop_v1.sh for why), so no
    // bundler ever runs. The tarball puts `sidecar/` *next to* the executable instead, which is
    // the first place `server_bin()` in src/lib.rs looks.
    //
    // If `resources` is ever added back here, restore the `create_dir_all("binaries/sidecar")`
    // placeholder too — otherwise a fresh checkout fails the build outright on the missing path.
    tauri_build::build()
}
