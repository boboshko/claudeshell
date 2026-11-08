#!/usr/bin/env python3

import argparse
import os
import re
import selectors
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()

ALLOWED = {
    "xcodebuild": {
        "actions": {
            "build", "test", "clean", "-list",
            "-showBuildSettings", "-version",
        },
        "flags": {
            "-project", "-workspace", "-scheme", "-target",
            "-configuration", "-sdk", "-destination",
            "-derivedDataPath", "-resultBundlePath", "-quiet", "-json",
        },
    },
    "xcrun": {
        "tools": {
            "simctl": {
                "list", "boot", "shutdown", "install", "uninstall",
                "launch", "terminate", "getenv",
            },
        },
    },
}

PATH_FLAGS = {"-project", "-workspace", "-derivedDataPath", "-resultBundlePath"}

SIMCTL_TOKEN_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
SIMCTL_LIST_FILTERS = {
    "devices", "runtimes", "devicetypes", "pairs",
    "available", "booted", "-j", "--json",
}
SIMCTL_LAUNCH_MAX_EXTRA_ARGS = 8
SIMCTL_LAUNCH_ARG_MAX_LEN = 1024

MAX_REQUEST_BODY_BYTES = 65536
DEFAULT_OPERATION_TIMEOUT_SECONDS = 300

SCRIPT_ROOT = None
MOUNTS_CONF = None
_mounts_cache = {"mtime": None, "mapping": None}
_mounts_lock = threading.Lock()


class PathError(Exception):
    pass


def sanitize(name):
    return re.sub(r"[^a-zA-Z0-9_-]", "-", name)


def load_mounts():
    with _mounts_lock:
        try:
            mtime = os.stat(MOUNTS_CONF).st_mtime
        except OSError:
            mtime = None

        if _mounts_cache["mtime"] == mtime and _mounts_cache["mapping"] is not None:
            return _mounts_cache["mapping"]

        mapping = {"/workspace": os.path.join(SCRIPT_ROOT, "workspace")}
        lines = []
        try:
            with open(MOUNTS_CONF, "r", encoding="utf-8") as f:
                lines = [line.rstrip("\n") for line in f if line.strip()]
        except OSError:
            lines = []

        for i, host_path in enumerate(lines, start=1):
            base = sanitize(os.path.basename(host_path.rstrip("/")))
            target = "/workspace/%d-%s" % (i, base)
            mapping[target] = host_path

        _mounts_cache["mtime"] = mtime
        _mounts_cache["mapping"] = mapping
        return mapping


def translate_path(raw_path):
    if not raw_path or not raw_path.startswith("/workspace"):
        raise PathError(
            "path '%s' is not under any currently mounted folder; "
            "mount it first via ClaudeShell -> Manage mounted folders" % raw_path
        )

    mapping = load_mounts()
    candidates = []
    for prefix, host_path in mapping.items():
        if raw_path == prefix or raw_path.startswith(prefix + "/"):
            candidates.append((prefix, host_path))

    if not candidates:
        raise PathError(
            "path '%s' is not under any currently mounted folder; "
            "mount it first via ClaudeShell -> Manage mounted folders" % raw_path
        )

    prefix, host_path = max(candidates, key=lambda c: len(c[0]))
    remainder = raw_path[len(prefix):].lstrip("/")
    full_host = os.path.join(host_path, remainder) if remainder else host_path

    canonical = os.path.realpath(full_host)
    canonical_root = os.path.realpath(host_path)

    if canonical != canonical_root and not canonical.startswith(canonical_root + os.sep):
        raise PathError(
            "path '%s' is not under any currently mounted folder; "
            "mount it first via ClaudeShell -> Manage mounted folders" % raw_path
        )

    return canonical


def open_confined_cwd(raw_path):
    host_path = translate_path(raw_path)
    try:
        fd = os.open(host_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
    except OSError as e:
        raise PathError(
            "path '%s' could not be safely opened on the host (%s)" % (raw_path, e)
        )
    return fd


def _probe_not_symlinked_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
    except OSError as e:
        raise PathError(
            "path '%s' failed a final on-host safety check (%s)" % (path, e)
        )
    os.close(fd)


def confine_for_argv(raw_path):
    host_path = translate_path(raw_path)
    candidate = host_path
    for _ in range(16):
        if os.path.lexists(candidate):
            break
        parent = os.path.dirname(candidate)
        if not parent or parent == candidate:
            candidate = None
            break
        candidate = parent
    if candidate and os.path.lexists(candidate):
        _probe_not_symlinked_dir(candidate)
    return host_path


def check_clt():
    for cmd in (["xcode-select", "-p"], ["xcodebuild", "-version"]):
        try:
            result = subprocess.run(cmd, capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return False
        if result.returncode != 0:
            return False
    return True


def _validate_simctl(argv):
    subcommand = argv[1]
    rest = argv[2:]

    if subcommand in ("boot", "shutdown"):
        if len(rest) != 1 or not SIMCTL_TOKEN_RE.match(rest[0]):
            return None
        return list(argv)

    if subcommand in ("uninstall", "terminate", "getenv"):
        if len(rest) != 2 or not all(SIMCTL_TOKEN_RE.match(v) for v in rest):
            return None
        return list(argv)

    if subcommand == "install":
        if len(rest) != 2 or not SIMCTL_TOKEN_RE.match(rest[0]):
            return None
        return list(argv)

    if subcommand == "launch":
        if len(rest) < 2:
            return None
        device, bundle_id = rest[0], rest[1]
        if not SIMCTL_TOKEN_RE.match(device) or not SIMCTL_TOKEN_RE.match(bundle_id):
            return None
        extra = rest[2:]
        if len(extra) > SIMCTL_LAUNCH_MAX_EXTRA_ARGS:
            return None
        for v in extra:
            if not v or len(v) > SIMCTL_LAUNCH_ARG_MAX_LEN:
                return None
        return list(argv)

    if subcommand == "list":
        for v in rest:
            if v not in SIMCTL_LIST_FILTERS:
                return None
        return list(argv)

    return None


def validate_allowlist(op, argv):
    if op == "xcodebuild":
        if not argv:
            return None
        spec = ALLOWED["xcodebuild"]
        result = []
        expect_value = False
        for a in argv:
            if expect_value:
                result.append(a)
                expect_value = False
                continue
            if a in spec["actions"]:
                result.append(a)
                continue
            if a in spec["flags"]:
                result.append(a)
                expect_value = True
                continue
            return None
        return result

    if op == "xcrun":
        if len(argv) < 2:
            return None
        tool = argv[0]
        tools = ALLOWED["xcrun"]["tools"]
        if tool not in tools:
            return None
        if argv[1] not in tools[tool]:
            return None
        if tool == "simctl":
            return _validate_simctl(argv)
        return None

    return None


def apply_path_translation(op, validated_argv):
    if op == "xcodebuild":
        final_args = []
        expect_path = False
        for a in validated_argv:
            if expect_path:
                final_args.append(confine_for_argv(a))
                expect_path = False
                continue
            final_args.append(a)
            if a in PATH_FLAGS:
                expect_path = True
        return final_args

    if op == "xcrun":
        final_args = list(validated_argv)
        if (
            len(final_args) == 4
            and final_args[0] == "simctl"
            and final_args[1] == "install"
        ):
            final_args[3] = confine_for_argv(final_args[3])
        return final_args

    return list(validated_argv)


class Handler(BaseHTTPRequestHandler):
    server_version = "ClaudeShellXcodeBridge/1"
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[xcode-bridge] " + (fmt % args) + "\n")

    def _start_response(self):
        self.send_response(200, "OK")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()

    def _write_line(self, text):
        try:
            self.wfile.write((text + "\n").encode("utf-8", "surrogateescape"))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _reject(self, message, code):
        self._start_response()
        self._write_line("2|" + message)
        self._write_line("0|" + str(code))

    def do_POST(self):
        if self.path != "/invoke":
            self.send_error(404, "not found")
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            length = 0

        if length < 0 or length > MAX_REQUEST_BODY_BYTES:
            self._reject("request body too large", 65)
            return

        body = self.rfile.read(length) if length > 0 else b""

        fields = body.split(b"\0")
        if fields and fields[-1] == b"":
            fields = fields[:-1]

        if len(fields) < 2:
            self._reject("malformed bridge request", 65)
            return

        op = fields[0].decode("utf-8", "surrogateescape")
        cwd_raw = fields[1].decode("utf-8", "surrogateescape")
        argv = [f.decode("utf-8", "surrogateescape") for f in fields[2:]]

        acquired = LOCK.acquire(blocking=False)
        if not acquired:
            self._reject("the Xcode bridge is already handling another request", 75)
            return
        try:
            self._handle_invoke(op, cwd_raw, argv)
        finally:
            LOCK.release()

    def _handle_invoke(self, op, cwd_raw, argv):
        if not check_clt():
            self._reject("Xcode Command Line Tools are not installed on this host.", 69)
            return

        validated = validate_allowlist(op, argv)
        if validated is None:
            self._reject(
                "operation '%s %s' is not on the Xcode bridge allow-list" % (op, " ".join(argv)),
                65,
            )
            return

        try:
            cwd_fd = open_confined_cwd(cwd_raw)
        except PathError as e:
            self._reject(str(e), 65)
            return

        try:
            final_args = apply_path_translation(op, validated)
        except PathError as e:
            os.close(cwd_fd)
            self._reject(str(e), 65)
            return

        self._start_response()
        try:
            proc = subprocess.Popen(
                [op] + final_args,
                cwd=cwd_fd,
                shell=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=1,
                universal_newlines=True,
            )
        except OSError as e:
            self._write_line("2|failed to start %s: %s" % (op, e))
            self._write_line("0|69")
            return
        finally:
            os.close(cwd_fd)

        self._stream_process(proc)

    def _stream_process(self, proc, timeout=DEFAULT_OPERATION_TIMEOUT_SECONDS):
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ, "1")
        sel.register(proc.stderr, selectors.EVENT_READ, "2")
        open_streams = 2
        deadline = time.monotonic() + timeout

        while open_streams > 0:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._kill_on_timeout(proc, timeout)
                return

            events = sel.select(timeout=remaining)
            if not events:
                self._kill_on_timeout(proc, timeout)
                return

            for key, _ in events:
                line = key.fileobj.readline()
                if line == "":
                    sel.unregister(key.fileobj)
                    open_streams -= 1
                    continue
                self._write_line(key.data + "|" + line.rstrip("\n"))

        proc.wait()
        self._write_line("0|" + str(proc.returncode))

    def _kill_on_timeout(self, proc, timeout):
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            pass
        self._write_line("2|operation timed out after %ds and was killed" % timeout)
        self._write_line("0|124")


def main():
    global SCRIPT_ROOT, MOUNTS_CONF

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=47870)
    args = parser.parse_args()

    SCRIPT_ROOT = os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
    )
    MOUNTS_CONF = os.path.join(SCRIPT_ROOT, "scripts", "mounts.conf")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write("[xcode-bridge] listening on 127.0.0.1:%d\n" % args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
