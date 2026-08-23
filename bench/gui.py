#!/usr/bin/env python3
"""slimebench -- a launcher, served locally.

    bench/gui.py [--port 8777] [--no-open]

Then open http://localhost:8777.

## Why a browser and not a window

Nothing here may add a dependency: the whole project builds from a toolchain
list and a Makefile, and a launcher that needed Qt would be the largest
dependency in the repository. This is `http.server` and one HTML file, both in
the standard library's reach.

It also puts the page on the right side of the WSL boundary. Run it in the WSL
shell that has the toolchains, open localhost:8777 in the Windows browser, and
the commands execute where the builds are -- which is the arrangement this
project is actually developed in, and the one a Windows-side launcher could
not have.

## Why it generates itself

bench/targets.toml already describes every target: its language, its class,
its compilers, its profiles, whether it can run headless. The page is built
from that file at request time, so a target added there appears here without
anyone editing a list. A launcher with its own copy of the target set would be
wrong within a week.

## The command is the record

Every action shows the exact command line before it runs it, and the log keeps
it. Anything done here can be done in a shell, and a result someone reports
from this page can be reproduced without it. A GUI that hid the command would
make the project less reproducible, which is the one thing it exists to be.
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import pathlib
import shlex
import shutil
import socketserver
import subprocess
import sys
import threading
import tomllib
import urllib.parse
import webbrowser

ROOT = pathlib.Path(__file__).resolve().parent.parent
HERE = pathlib.Path(__file__).resolve().parent
PROFILES = HERE / "gui-profiles.json"

# Grid, agent count and tick budget move together -- see apply_preset() in
# impl/c/sb_cli.c. The page offers the triple rather than three numbers,
# because two of the three combinations a free form allows are wrong: the
# grid has to be a power of two (sb_init rejects anything else, SPEC-1 2.2)
# and an agent count that does not match the grid is a different benchmark.
PRESETS = [
    ("tiny",   "tiny  --  512 x 512, 65k agents"),
    ("small",  "small  --  1024 x 1024, 262k agents"),
    ("medium", "medium  --  2048 x 2048, 1.0M agents"),
    ("large",  "large  --  4096 x 4096, 4.2M agents"),
    ("huge",   "huge  --  8192 x 8192, 16.8M agents"),
]

# The interpreter as a reader would type it. sys.executable is correct and
# unreadable -- an absolute path into a Python installation, which is exactly
# what a command line meant to be copied must not contain.
PY = "python3" if shutil.which("python3") else (sys.executable or "python")


def cmdline(argv: list[str]) -> str:
    """The command as it would be typed from the repository root.

    Paths inside the repository are shown relative to it, because that is the
    form that survives being pasted into someone else's shell.
    """
    out = []
    for a in argv:
        # Absolute only: "--preset" is a path relative to the root as far as
        # the filesystem is concerned, and rewriting it would be nonsense.
        if os.path.isabs(a):
            try:
                r = pathlib.Path(a).resolve().relative_to(ROOT)
                a = "./" + r.as_posix()
            except (ValueError, OSError):
                pass
        out.append(shlex.quote(a))
    return " ".join(out)


# ---------------------------------------------------------------------------
# jobs

class Job:
    """One running command, its output kept for polling."""

    _next_id = 1
    _lock = threading.Lock()
    all: dict[int, "Job"] = {}

    def __init__(self, argv: list[str], cwd: pathlib.Path):
        with Job._lock:
            self.id = Job._next_id
            Job._next_id += 1
            Job.all[self.id] = self
        self.argv = argv
        self.lines: list[str] = ["$ " + cmdline(argv), ""]
        self.done = False
        self.code: int | None = None
        # A window needs a display; a benchmark does not care. Passing the
        # environment through unchanged is what makes DISPLAY, PATH and the
        # toolchain locations work the same here as in the shell that started
        # this server.
        self.proc = subprocess.Popen(
            argv, cwd=str(cwd), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
            env=os.environ.copy())
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.lines.append(line.rstrip("\n"))
            # A run can print for an hour; keeping every line of a full-run.sh
            # would be a slow memory leak in a page nobody reloads.
            if len(self.lines) > 20000:
                del self.lines[:5000]
                self.lines.insert(0, "... earlier output dropped ...")
        self.code = self.proc.wait()
        self.done = True
        self.lines.append("")
        self.lines.append(f"[exit {self.code}]")

    def stop(self) -> None:
        if not self.done:
            self.proc.terminate()


# ---------------------------------------------------------------------------
# what the page is built from

def load_targets() -> list[dict]:
    t = tomllib.loads((HERE / "targets.toml").read_text(encoding="utf-8"))
    out = []
    for x in t["target"]:
        out.append({
            "id": x["id"],
            "lang": x["lang"],
            "cls": x.get("class", "S"),
            "backend": x.get("backend", ""),
            "compilers": x.get("compilers", []),
            "profiles": x.get("profiles", []),
            "updates": x.get("updates", ["serial", "deferred"]),
            "headless": x.get("headless_capable", True),
            "windowed": not x.get("headless_capable", True),
        })
    # S P V G R -- the order the spec and the results document use, which is
    # roughly increasing distance from "one thread, no tricks". Alphabetical
    # would put the GPU targets first, which is nobody's mental model.
    rank = {"S": 0, "P": 1, "V": 2, "G": 3, "R": 4}
    out.sort(key=lambda r: (rank.get(r["cls"], 9), r["lang"].lower(), r["id"]))
    return out


def load_profiles() -> dict:
    if PROFILES.exists():
        try:
            return json.loads(PROFILES.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}
    return {}


def save_profiles(d: dict) -> None:
    PROFILES.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8", newline="\n")


# ---------------------------------------------------------------------------
# building the command

def build_argv(req: dict) -> tuple[list[str], pathlib.Path]:
    """The command a request means. Raises ValueError with a readable reason."""
    kind = req.get("kind", "bench")
    py = PY

    if kind == "bench":
        targets = req.get("targets") or []
        if not targets:
            raise ValueError("pick at least one target")
        argv = [py, "bench/run.py", "bench",
                "--preset", req.get("preset", "small"),
                "--ticks", str(int(req.get("ticks", 100))),
                "--warmup", str(int(req.get("warmup", 20))),
                "--reps", str(int(req.get("reps", 3))),
                "--update", req.get("update", "deferred"),
                "--targets", ",".join(targets)]
        if req.get("threads"):
            argv += ["--threads", str(int(req["threads"]))]
        if req.get("out"):
            argv += ["--out", req["out"]]
        return argv, ROOT

    if kind == "conformance":
        argv = [py, "bench/run.py", "conformance"]
        if req.get("targets"):
            argv += ["--targets", ",".join(req["targets"])]
        return argv, ROOT

    if kind == "machine":
        argv = ["bash", "bench/machine.sh"]
        if not req.get("verify", True):
            argv.append("--no-verify")
        return argv, ROOT

    if kind == "record":
        return ["bash", "bench/machine.sh", "--record"], ROOT

    if kind == "full":
        argv = ["bash", "bench/full-run.sh", "--profile",
                req.get("runprofile", "standard")]
        if req.get("dry"):
            argv.append("--dry-run")
        return argv, ROOT

    if kind == "window":
        binary = req.get("binary")
        if not binary:
            raise ValueError("pick a windowed build")
        p = ROOT / binary
        if not p.exists():
            raise ValueError(f"{binary} is not built")
        # --ticks 0 is "until the window is closed"; the preset's own tick
        # budget is a benchmark's answer to a question nobody asked here.
        argv = [str(p),
                "--preset", req.get("preset", "small"),
                "--update", req.get("update", "deferred"),
                "--ticks", "0"]
        if req.get("fullscreen"):
            argv.append("--fullscreen")
        if req.get("hud") is False:
            argv.append("--no-hud")
        return argv, ROOT

    raise ValueError(f"unknown kind '{kind}'")


def windowed_builds() -> list[dict]:
    """Windowed binaries that exist right now.

    Listed by looking rather than by assuming: a build directory that has not
    been made yet is the normal state for most of these, and offering a button
    that cannot work is worse than a short list.
    """
    found = []
    for pat, label in [
        ("impl/c/build/*/slimebench-sdl2", "C / SDL2"),
        ("impl/c/build/*/slimebench-raylib", "C / raylib"),
        ("impl/cpp/build/*/slimebench-sdl2", "C++ / SDL2"),
        ("impl/cpp/build/*/slimebench-raylib", "C++ / raylib"),
        ("impl/rust/target/release/slimebench-sdl2", "Rust / SDL2"),
        ("impl/rust/target/release/slimebench-raylib", "Rust / raylib"),
        ("impl/haskell/build/*/slimebench-sdl2", "Haskell / SDL2"),
        ("impl/haskell/build/*/slimebench-raylib", "Haskell / raylib"),
    ]:
        for p in sorted(ROOT.glob(pat)):
            if os.access(p, os.X_OK):
                found.append({"path": p.relative_to(ROOT).as_posix(),
                              "label": label})
    return found


# ---------------------------------------------------------------------------
# server

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet: the page is the log
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code: int = 200) -> None:
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self) -> None:
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/index.html"):
            page = (HERE / "gui.html").read_bytes()
            return self._send(200, page, "text/html; charset=utf-8")
        if u.path == "/api/meta":
            return self._json({
                "targets": load_targets(),
                "presets": [{"id": i, "label": l} for i, l in PRESETS],
                "profiles": load_profiles(),
                "windowed": windowed_builds(),
                "root": str(ROOT),
            })
        if u.path == "/api/log":
            q = urllib.parse.parse_qs(u.query)
            jid = int(q.get("id", ["0"])[0])
            frm = int(q.get("from", ["0"])[0])
            job = Job.all.get(jid)
            if not job:
                return self._json({"error": "no such job"}, 404)
            return self._json({"lines": job.lines[frm:], "next": len(job.lines),
                               "done": job.done, "code": job.code})
        return self._send(404, b"not found", "text/plain")

    def do_POST(self) -> None:
        u = urllib.parse.urlparse(self.path)
        n = int(self.headers.get("Content-Length", "0"))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._json({"error": "bad json"}, 400)

        if u.path == "/api/run":
            try:
                argv, cwd = build_argv(req)
            except ValueError as e:
                return self._json({"error": str(e)}, 400)
            job = Job(argv, cwd)
            return self._json({"id": job.id,
                               "cmd": cmdline(argv)})

        if u.path == "/api/stop":
            job = Job.all.get(int(req.get("id", 0)))
            if job:
                job.stop()
            return self._json({"ok": True})

        if u.path == "/api/profiles":
            save_profiles(req.get("profiles", {}))
            return self._json({"ok": True})

        if u.path == "/api/preview":
            # 200 with a reason, not 400: a half-filled form is the normal
            # state of a form, and the console should stay clean enough that
            # a real error in it means something.
            try:
                argv, _ = build_argv(req)
            except ValueError as e:
                return self._json({"error": str(e)})
            return self._json({"cmd": cmdline(argv)})

        return self._json({"error": "not found"}, 404)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--no-open", action="store_true")
    a = ap.parse_args()

    if not (HERE / "gui.html").exists():
        sys.exit("bench/gui.html is missing")

    url = f"http://localhost:{a.port}"
    with Server(("127.0.0.1", a.port), Handler) as srv:
        print(f"slimebench launcher on {url}")
        print("  the page shows every command before it runs it; nothing here")
        print("  can be done that could not be done in a shell.")
        if not a.no_open:
            try:
                webbrowser.open(url)
            except Exception:
                pass
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\nstopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
