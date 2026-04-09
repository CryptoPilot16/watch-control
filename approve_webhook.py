from http.server import BaseHTTPRequestHandler, HTTPServer
import os
import subprocess
import fcntl
from urllib.parse import parse_qs, urlparse


def getenv_required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


SECRET = getenv_required("APPROVE_SECRET")
SESSION = os.environ.get("TMUX_SESSION", "codex:0.0").strip() or "codex:0.0"
HOST = os.environ.get("APPROVE_HOST", "127.0.0.1").strip() or "127.0.0.1"
PORT = int(os.environ.get("APPROVE_PORT", "8787"))
QUEUE_FILE = os.environ.get("APPROVAL_QUEUE_FILE", "/tmp/codex_approval_queue.tsv").strip() or "/tmp/codex_approval_queue.tsv"
QUEUE_LOCK = os.environ.get("APPROVAL_QUEUE_LOCK", "/tmp/codex_approval_queue.lock").strip() or "/tmp/codex_approval_queue.lock"


def tmux_send(target: str, key_spec: str):
    key_spec = (key_spec or "").strip()
    if not key_spec:
        key_spec = "y"

    tokens = [token.strip() for token in key_spec.replace("+", ",").split(",") if token.strip()]
    if not tokens:
        tokens = ["y"]

    if len(tokens) == 1 and tokens[0] not in {"Enter", "Escape", "Esc"}:
        tokens.append("Enter")

    subprocess.check_call(["tmux", "send-keys", "-t", target, *tokens])


def pop_queue_item():
    os.makedirs(os.path.dirname(QUEUE_FILE) or ".", exist_ok=True)
    os.makedirs(os.path.dirname(QUEUE_LOCK) or ".", exist_ok=True)

    with open(QUEUE_LOCK, "a+", encoding="utf-8") as lock_fp:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)
        try:
            try:
                with open(QUEUE_FILE, "r", encoding="utf-8") as queue_fp:
                    lines = [line for line in queue_fp.readlines() if line.strip()]
            except FileNotFoundError:
                lines = []

            if not lines:
                return None

            first = lines[0].rstrip("\n")
            rest = lines[1:]

            with open(QUEUE_FILE, "w", encoding="utf-8") as queue_fp:
                queue_fp.writelines(rest)

            parts = first.split("\t", 3)
            if len(parts) < 4:
                return None

            return {
                "timestamp": parts[0],
                "seq": parts[1],
                "target": parts[2],
                "key_spec": parts[3],
            }
        finally:
            fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)


def queue_depth() -> int:
    os.makedirs(os.path.dirname(QUEUE_LOCK) or ".", exist_ok=True)
    with open(QUEUE_LOCK, "a+", encoding="utf-8") as lock_fp:
        fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)
        try:
            try:
                with open(QUEUE_FILE, "r", encoding="utf-8") as queue_fp:
                    return sum(1 for line in queue_fp if line.strip())
            except FileNotFoundError:
                return 0
        finally:
            fcntl.flock(lock_fp.fileno(), fcntl.LOCK_UN)


def approve_next() -> str:
    item = pop_queue_item()
    if item is None:
        tmux_send(SESSION, "y")
        return f"Approved fallback target {SESSION}"

    tmux_send(item["target"], item["key_spec"])
    return f"Approved {item['target']} (queued seq {item['seq']})"


def deny_next() -> str:
    item = pop_queue_item()
    if item is None:
        tmux_send(SESSION, "Escape")
        return f"Denied fallback target {SESSION}"

    tmux_send(item["target"], "Escape")
    return f"Denied {item['target']} (queued seq {item['seq']})"


def has_valid_secret(handler: BaseHTTPRequestHandler) -> bool:
    header_secret = (handler.headers.get("X-Secret") or "").strip()
    query = parse_qs(urlparse(handler.path).query)
    query_secret = (query.get("secret", [""])[0] or "").strip()
    return SECRET in {header_secret, query_secret}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        path = urlparse(self.path).path

        if not has_valid_secret(self):
            self.send_response(401)
            self.end_headers()
            return

        if path == "/approve":
            approve_next()
            self.send_response(200)
            self.end_headers()
            return

        if path == "/approve2":
            approve_next()
            self.send_response(200)
            self.end_headers()
            return

        if path == "/deny":
            deny_next()
            self.send_response(200)
            self.end_headers()
            return

        if path == "/status":
            depth = queue_depth()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(f"queue_depth={depth}".encode("utf-8"))
            return

        self.send_response(404)
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path

        if not has_valid_secret(self):
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b"Unauthorized")
            return

        if path == "/approve":
            msg = approve_next()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))
            return

        if path == "/approve2":
            msg = approve_next()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))
            return

        if path == "/deny":
            msg = deny_next()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))
            return

        if path == "/status":
            depth = queue_depth()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(f"queue_depth={depth}".encode("utf-8"))
            return

        self.send_response(404)
        self.end_headers()


print(f"Webhook listening on {HOST}:{PORT}")
HTTPServer((HOST, PORT), Handler).serve_forever()
