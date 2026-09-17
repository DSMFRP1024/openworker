"""Browser-served entry point ("service mode") for Linux targets the desktop shell can't reach.

The desktop app is a Tauri webview wrapping this same FastAPI sidecar. That shell needs
webkit2gtk-4.1 *and* a recent glibc, and the RHEL 8-derived distros (Kylin V10 and friends)
have neither: their repos stop at webkit2gtk-4.0, and glibc there is 2.31. So this entry
serves the prebuilt GUI over HTTP from the sidecar itself and any local browser becomes the
shell.

Deliberate properties:
  - ONE process, ONE port, ONE origin: the GUI is mounted on the same FastAPI app that
    answers /v1/*, so there is no cross-origin surface at all. (The Tauri shell has the same
    shape — the webview loads from the bundled assets and talks to the loopback sidecar.)
  - The page gets the API base, the WS base and the launch token injected into <head>. Those
    are exactly the three globals the desktop shell injects into its webview at runtime, so
    the frontend keeps shipping as a single build with no variant (see surfaces/gui/src/api.ts).
  - API base is `location.origin`, not a hardcoded host/port: reached through an SSH tunnel
    (`ssh -L 8765:127.0.0.1:8765 host`) the page still talks to the origin it was loaded from,
    and that Origin stays `http://127.0.0.1:PORT`, which the sidecar's origin gate allows
    (coworker/server/app.py `_ALLOWED_ORIGIN_RE`).

Usage:  openworker-service [--host 127.0.0.1] [--port 8765] [--web DIR] [--cwd DIR]
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import sys
from pathlib import Path

from coworker.config import load_config
from coworker.secrets import state_dir, write_private_text
from coworker.server.app import _WS_MAX_FRAME_BYTES
from coworker.server.run import _ensure_ca_bundle, build_app

MODES = ["discuss", "plan", "interactive", "auto", "bypass-approvals", "auto-approve"]

# Marks the injected block so a second call cannot double-inject (matters when the served
# directory is a user's own build output they also open directly in a browser).
INJECT_MARK = "<!-- openworker-service -->"


def find_web_dir(explicit: str | None) -> Path:
    """Locate the built GUI. Explicit flag → env → next to the binary (and one level up).

    The tarball ships `web/` as a SIBLING of `sidecar/`, and the binary lives inside
    `sidecar/`, so both spellings are checked before giving up.
    """
    if explicit:
        return Path(explicit).expanduser().resolve()
    from_env = os.environ.get("COWORKER_WEB_DIR")
    if from_env:
        return Path(from_env).expanduser().resolve()
    exe_dir = Path(sys.executable).resolve().parent
    for cand in (exe_dir / "web", exe_dir.parent / "web"):
        if (cand / "index.html").is_file():
            return cand
    raise SystemExit(
        "openworker-service: could not find the built GUI.\n"
        "Pass --web DIR (or set COWORKER_WEB_DIR) to the folder containing index.html.\n"
        "Looked in: %s" % ", ".join(str(d) for d in (exe_dir / "web", exe_dir.parent / "web"))
    )


def index_with_boot(web: Path, token: str) -> str:
    """index.html with the three runtime globals injected before </head>."""
    html = (web / "index.html").read_text(encoding="utf-8")
    if INJECT_MARK in html:
        return html
    boot = (
        "\n    "
        + INJECT_MARK
        + "\n    <script>\n"
        # Token first: the frontend reads all three at module load (api.ts).
        + "      window.__COWORKER_API_TOKEN__ = %s;\n" % json.dumps(token)
        + "      window.__COWORKER_HTTP__ = location.origin;\n"
        + "      window.__COWORKER_WS__ =\n"
        + "        (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host;\n"
        + "    </script>\n  "
    )
    return html.replace("</head>", boot + "</head>", 1)


def wire_web(app, web: Path, token: str) -> None:
    """Serve the GUI from the app itself: `/` + `/index.html` from memory, assets from disk.

    Registered AFTER the app's own routes, so /v1/* and the websockets keep priority — the
    static mount only ever sees what nothing else claimed.
    """
    from fastapi.responses import HTMLResponse
    from starlette.staticfiles import StaticFiles

    page = index_with_boot(web, token)

    @app.get("/", include_in_schema=False)
    async def _root() -> HTMLResponse:  # noqa: ANN202 — FastAPI route
        return HTMLResponse(page)

    @app.get("/index.html", include_in_schema=False)
    async def _index() -> HTMLResponse:  # noqa: ANN202 — FastAPI route
        return HTMLResponse(page)

    # html=False: `/` is already handled above with the injected copy, and the GUI has no
    # client-side routing (single view), so there is no SPA fallback to provide.
    app.mount("/", StaticFiles(directory=str(web), html=False), name="web")


def main(argv=None) -> None:
    _ensure_ca_bundle()
    cfg = load_config()
    parser = argparse.ArgumentParser(prog="openworker-service")
    parser.add_argument("--host", default=cfg.host, help="bind address (default: %(default)s)")
    parser.add_argument("--port", type=int, default=cfg.port, help="port (default: %(default)s)")
    parser.add_argument("--web", default=None, help="folder holding the built GUI (index.html)")
    parser.add_argument("--cwd", default=None, help="optional seed/default workspace")
    parser.add_argument("--model", default=cfg.model)
    parser.add_argument("--mode", default=cfg.mode, choices=MODES)
    parser.add_argument(
        "--token",
        default=os.environ.get("COWORKER_API_TOKEN") or None,
        help="launch token; generated and saved under the state dir when omitted",
    )
    args = parser.parse_args(argv)

    web = find_web_dir(args.web)

    # Generate before building the app: create_app() reads COWORKER_API_TOKEN from the
    # environment and installs the auth middleware from it.
    token = args.token or secrets.token_hex(32)
    os.environ["COWORKER_API_TOKEN"] = token
    # Publish the bound port: loopback URLs built by the server (managed-OAuth callback) must
    # follow the real port rather than config.port (same reason as coworker/server/run.py).
    os.environ["COWORKER_PORT"] = str(args.port)

    token_path = write_private_text(state_dir() / f"sidecar-{args.port}.token", token + "\n")

    app = build_app(args.cwd, args.model, args.mode)
    wire_web(app, web, token)

    shown = args.host if args.host not in ("0.0.0.0", "::") else "<this-host>"
    print("OpenWorker service mode", flush=True)
    print("  open      http://%s:%d/" % (shown, args.port), flush=True)
    print("  gui       %s" % web, flush=True)
    print("  token     %s" % token_path, flush=True)
    if args.host in ("127.0.0.1", "localhost") and not os.environ.get("DISPLAY"):
        print(
            "  tip       no DISPLAY here — from another machine: "
            "ssh -L %d:127.0.0.1:%d <user>@<this-host>" % (args.port, args.port),
            flush=True,
        )

    try:
        import uvicorn

        uvicorn.run(app, host=args.host, port=args.port, ws_max_size=_WS_MAX_FRAME_BYTES)
    finally:
        if token_path is not None:
            token_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
