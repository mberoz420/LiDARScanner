"""
LiDAR Scan Watcher
==================
Watches G:\\My Drive\\LidarScans for new JSON files from the iOS app.
When a new scan arrives, opens PointCloudLabeler.html in your browser
with the scan pre-loaded and auto-classified.

Usage:
    python watch_scans.py

Requirements:
    pip install watchdog
"""

import http.server
import socketserver
import webbrowser
import threading
import time
import os
import sys

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# ── Configuration ─────────────────────────────────────────────────────────────
SCAN_FOLDER  = r"G:\My Drive\LidarScans\json"
TOOLS_FOLDER = os.path.dirname(os.path.abspath(__file__))
PREFERRED_PORTS = [5500, 5501, 7070, 9090, 9191, 9876]
# ──────────────────────────────────────────────────────────────────────────────


class ScanFileHandler(FileSystemEventHandler):
    """Opens the labeler whenever a new .json scan file is written.

    Google Drive syncs files by writing a temp file then renaming it,
    so we watch both on_created and on_moved (rename = final file ready).
    """

    def __init__(self, port):
        super().__init__()
        self.port = port
        self._opened = set()  # Avoid opening the same file twice

    def _open_scan(self, path):
        if path.lower().endswith('.gdoc'):
            return  # Skip Google Docs stubs
        if not path.lower().endswith('.json'):
            return
        if path in self._opened:
            return

        filename = os.path.basename(path)
        self._opened.add(path)

        print(f"\n[Watcher] New scan: {filename}")

        # Wait for Google Drive to finish writing
        time.sleep(2)

        url = f"http://localhost:{self.port}/?scan={filename}"
        print(f"[Watcher] Opening: {url}")
        webbrowser.open(url)

    def on_created(self, event):
        if not event.is_directory:
            self._open_scan(event.src_path)

    def on_moved(self, event):
        # Google Drive renames temp → final file
        if not event.is_directory:
            self._open_scan(event.dest_path)


class LabelerHTTPHandler(http.server.SimpleHTTPRequestHandler):
    """
    Serves PointCloudLabeler.html at / and scan JSON files at /scans/<filename>.
    """

    def do_GET(self):
        # Serve scan files from Google Drive folder
        if self.path.startswith('/scans/'):
            filename = self.path[len('/scans/'):]
            # Strip any query string
            filename = filename.split('?')[0]
            filepath = os.path.join(SCAN_FOLDER, filename)

            if not os.path.isfile(filepath):
                self.send_error(404, f"Scan file not found: {filename}")
                return

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            with open(filepath, 'rb') as f:
                data = f.read()
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # Serve the tools folder (HTML, JS, etc.)
        # Rewrite / → /PointCloudLabeler.html
        if self.path == '/' or self.path.startswith('/?'):
            query = ''
            if '?' in self.path:
                query = self.path[self.path.index('?'):]
            self.path = '/PointCloudLabeler.html' + query

        # Strip query string for file serving
        clean_path = self.path.split('?')[0]
        local_file = os.path.join(TOOLS_FOLDER, clean_path.lstrip('/'))

        if os.path.isfile(local_file):
            ext = os.path.splitext(local_file)[1].lower()
            mime = {'.html': 'text/html', '.js': 'application/javascript',
                    '.css': 'text/css', '.json': 'application/json'}.get(ext, 'text/plain')
            with open(local_file, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404, f"Not found: {clean_path}")

    def log_message(self, format, *args):
        # Suppress routine GET logs — only show scan loads
        first = str(args[0]) if args else ''
        if '/scans/' in first:
            print(f"[Server] Serving scan: {first}")


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True  # Must be class-level on Windows


def find_free_port():
    """Try preferred ports first, then let the OS pick one."""
    import socket
    for port in PREFERRED_PORTS:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.bind(('', port))
            return port
        except OSError:
            continue
    # Let OS assign any free port
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('', 0))
        return s.getsockname()[1]


def start_server(port):
    with ReusableTCPServer(('', port), LabelerHTTPHandler) as httpd:
        print(f"[Server] Serving labeler at http://localhost:{port}")
        httpd.serve_forever()


def main():
    # Check scan folder exists
    if not os.path.isdir(SCAN_FOLDER):
        print(f"[Error] Scan folder not found: {SCAN_FOLDER}")
        print("        Make sure Google Drive is running and the folder exists.")
        sys.exit(1)

    port = find_free_port()

    # Start HTTP server in background thread
    server_thread = threading.Thread(target=start_server, args=(port,), daemon=True)
    server_thread.start()

    # Give server a moment to bind
    time.sleep(0.5)

    # Start file watcher
    handler = ScanFileHandler(port)
    observer = Observer()
    observer.schedule(handler, SCAN_FOLDER, recursive=False)
    observer.start()

    print(f"[Watcher] Watching: {SCAN_FOLDER}")
    print(f"[Watcher] Open labeler manually: http://localhost:{port}")
    print(f"[Watcher] New scans will open automatically. Press Ctrl+C to stop.\n")

    # Open the labeler now so it's ready
    webbrowser.open(f"http://localhost:{port}")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n[Watcher] Stopped.")
        observer.stop()

    observer.join()


if __name__ == '__main__':
    main()
