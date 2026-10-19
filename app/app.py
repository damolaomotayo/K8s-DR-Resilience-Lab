"""Tiny HTTP app used by the lab. Standard library only.

MODE=stateful  -> notes API backed by SQLite on a volume (the thing we must not lose)
MODE=stateless -> returns which pod answered (the thing we must keep available)

  python app.py               run the server
  python app.py --checkpoint  flush the SQLite write-ahead log into the main file (used as the Velero pre-backup hook)
"""
import json
import os
import socket
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "stateless")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
PORT = int(os.environ.get("PORT", "8080"))
LOCK = threading.Lock()


def db_path():
    return os.path.join(DATA_DIR, "notes.db")


def connect():
    conn = sqlite3.connect(db_path(), timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, created TEXT DEFAULT CURRENT_TIMESTAMP)")
    return conn


def checkpoint():
    conn = connect()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "drlab"

    def log_message(self, fmt, *args):  # quiet access log
        pass

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/healthz":
            return self.send_json(200, {"ok": True})
        if path == "/readyz":
            if MODE == "stateful":
                try:
                    connect().close()
                except Exception as err:
                    return self.send_json(503, {"ready": False, "error": type(err).__name__})
            return self.send_json(200, {"ready": True})
        if path == "/info":
            return self.send_json(200, {"pod": socket.gethostname(), "mode": MODE})
        if MODE == "stateless" and path == "/work":
            return self.send_json(200, {"pod": socket.gethostname()})
        if MODE == "stateful" and path == "/notes":
            with LOCK:
                conn = connect()
                count = conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0]
                rows = conn.execute("SELECT id, text FROM notes ORDER BY id DESC LIMIT 50").fetchall()
                conn.close()
            return self.send_json(200, {"count": count, "notes": [{"id": r[0], "text": r[1]} for r in rows], "pod": socket.gethostname()})
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if MODE == "stateful" and self.path.split("?")[0] == "/notes":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                text = str(json.loads(self.rfile.read(length) or b"{}").get("text", "")).strip()
            except (ValueError, json.JSONDecodeError):
                return self.send_json(400, {"error": "invalid JSON"})
            if not text or len(text) > 500:
                return self.send_json(400, {"error": "text must be 1-500 characters"})
            with LOCK:
                conn = connect()
                with conn:
                    cur = conn.execute("INSERT INTO notes (text) VALUES (?)", (text,))
                conn.close()
            return self.send_json(201, {"id": cur.lastrowid})
        return self.send_json(404, {"error": "not found"})


def make_server(port=PORT):
    if MODE == "stateful":
        os.makedirs(DATA_DIR, exist_ok=True)
        connect().close()
    return ThreadingHTTPServer(("0.0.0.0", port), Handler)


if __name__ == "__main__":
    if "--checkpoint" in sys.argv:
        checkpoint()
        sys.exit(0)
    make_server().serve_forever()
