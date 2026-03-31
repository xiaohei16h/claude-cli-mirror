#!/usr/bin/env python3
"""Caching reverse proxy for GCS storage downloads."""

import os
import shutil
import socketserver
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError


class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True

GCS_BUCKET = os.environ.get(
    "GCS_BUCKET", "claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819"
)
CACHE_DIR = Path(os.environ.get("CACHE_DIR", "/data/cache"))
CACHE_ENABLED = os.environ.get("CACHE_ENABLED", "true").lower() == "true"
MAX_VERSIONS = int(os.environ.get("MAX_VERSIONS", "3"))
PORT = int(os.environ.get("CACHE_PORT", "9000"))

lock = threading.Lock()


def gcs_url(path: str) -> str:
    return f"https://storage.googleapis.com/{GCS_BUCKET}/claude-code-releases{path}"


def cleanup_old_versions():
    """Keep only the latest MAX_VERSIONS versions in cache."""
    if not CACHE_DIR.exists():
        return
    versions = sorted(
        [d for d in CACHE_DIR.iterdir() if d.is_dir()],
        key=lambda d: list(map(int, d.name.split("."))),
        reverse=True,
    )
    for old in versions[MAX_VERSIONS:]:
        print(f"[cache] Removing old version: {old.name}")
        shutil.rmtree(old, ignore_errors=True)


class CacheHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        """Handle HEAD requests for Content-Length checks."""
        path = self.path
        cache_path = CACHE_DIR / path.lstrip("/")

        if CACHE_ENABLED and cache_path.exists() and cache_path.is_file():
            size = cache_path.stat().st_size
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            return

        # Proxy HEAD to GCS
        upstream = gcs_url(path)
        try:
            req = Request(upstream, method="HEAD")
            resp = urlopen(req, timeout=10)
            self.send_response(200)
            cl = resp.headers.get("Content-Length")
            if cl:
                self.send_header("Content-Length", cl)
            self.send_header("Content-Type", resp.headers.get("Content-Type", "application/octet-stream"))
            self.end_headers()
        except URLError as e:
            self.send_error(502, f"Upstream error: {e}")

    def do_GET(self):
        path = self.path
        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return

        cache_path = CACHE_DIR / path.lstrip("/")

        # Serve from cache if available
        if CACHE_ENABLED and cache_path.exists() and cache_path.is_file():
            print(f"[cache] HIT  {path}")
            self._serve_file(cache_path)
            return

        # Fetch from GCS
        upstream = gcs_url(path)
        print(f"[cache] MISS {path} -> {upstream}")
        try:
            req = Request(upstream)
            resp = urlopen(req, timeout=300)
        except URLError as e:
            print(f"[cache] ERROR {path}: {e}")
            self.send_error(502, f"Upstream error: {e}")
            return

        content_type = resp.headers.get("Content-Type", "application/octet-stream")
        content_length = resp.headers.get("Content-Length")

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        if content_length:
            self.send_header("Content-Length", content_length)
        self.end_headers()

        if CACHE_ENABLED:
            # Stream to client and save to cache simultaneously
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            tmp_path = cache_path.with_suffix(".tmp")
            client_disconnected = False
            try:
                with open(tmp_path, "wb") as f:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        f.write(chunk)
                        if not client_disconnected:
                            try:
                                self.wfile.write(chunk)
                            except (BrokenPipeError, ConnectionResetError):
                                client_disconnected = True
                                print(f"[cache] Client disconnected, continuing cache save: {path}")
                # Always save to cache even if client disconnected
                tmp_path.rename(cache_path)
                print(f"[cache] SAVED {path}")
                threading.Thread(target=cleanup_old_versions, daemon=True).start()
            except Exception as e:
                print(f"[cache] SAVE ERROR {path}: {e}")
                tmp_path.unlink(missing_ok=True)
        else:
            # Pass-through without caching
            try:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                print(f"[cache] Client disconnected: {path}")

    def _serve_file(self, path: Path):
        size = path.stat().st_size
        suffix = path.suffix.lower()
        ct = {".json": "application/json"}.get(suffix, "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        # Suppress default access log (we log manually)
        pass


def main():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cleanup_old_versions()
    mode = "cache" if CACHE_ENABLED else "pass-through"
    print(f"[cache] Starting on :{PORT} mode={mode} max_versions={MAX_VERSIONS}")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), CacheHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
