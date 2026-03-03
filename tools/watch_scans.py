"""
LiDAR Scan Watcher
==================
Polls scan-wizard.robo-wizard.com/scans/manifest.json for new scans.
When a new scan arrives, opens PointCloudLabeler.html in your browser
with the scan pre-loaded and auto-classified.

Usage:
    python watch_scans.py

No extra dependencies — uses only the Python standard library.
"""

import webbrowser
import urllib.request
import urllib.error
import json
import time
import sys

# ── Configuration ─────────────────────────────────────────────────────────────
SERVER_URL    = "https://scanwizard.robo-wizard.com"
MANIFEST_URL  = f"{SERVER_URL}/scans/manifest.json"
POLL_INTERVAL = 5   # seconds between manifest checks
# ──────────────────────────────────────────────────────────────────────────────


def fetch_manifest() -> list | None:
    """Fetch the manifest from the server. Returns list or None on error."""
    try:
        req = urllib.request.Request(MANIFEST_URL,
                                     headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []          # No scans yet — that's fine
        print(f"[Watcher] Server error: {e.code}")
        return None
    except Exception as e:
        print(f"[Watcher] Cannot reach server: {e}")
        return None


def main():
    print(f"[Watcher] Server : {SERVER_URL}")
    print(f"[Watcher] Polling every {POLL_INTERVAL}s. Press Ctrl+C to stop.\n")

    # Open the labeler now so it's ready
    webbrowser.open(SERVER_URL)

    # Seed 'seen' with whatever is already on the server
    seen: set[str] = set()
    manifest = fetch_manifest()
    if manifest is None:
        print("[Watcher] Warning: could not reach server on startup — will keep trying.")
    elif manifest:
        for entry in manifest:
            seen.add(entry["filename"])
        print(f"[Watcher] Tracking {len(seen)} existing scan(s).")
    else:
        print("[Watcher] No scans on server yet — waiting for the first one.")

    try:
        while True:
            time.sleep(POLL_INTERVAL)

            manifest = fetch_manifest()
            if not manifest:
                continue

            for entry in manifest:
                filename = entry["filename"]
                if filename not in seen:
                    seen.add(filename)
                    url = f"{SERVER_URL}/?scan={filename}"
                    print(f"\n[Watcher] New scan: {filename}")
                    print(f"[Watcher] Opening : {url}")
                    webbrowser.open(url)

    except KeyboardInterrupt:
        print("\n[Watcher] Stopped.")


if __name__ == "__main__":
    main()
