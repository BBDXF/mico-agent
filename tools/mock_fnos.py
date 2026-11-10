#!/usr/bin/env python3
"""Fake 飞牛音乐 (/music/api/v1) server backed by a local music folder.

For local end-to-end tests of the fnos plugin without a NAS. File names are
parsed as "Artist - Title.ext" (artists split on _ 、 & ,). Supports login,
track list/search, playlists (one per artist with >=3 songs), favorites,
event report and /track/stream with Range.

  python3 tools/mock_fnos.py "/mnt/c/mycode/570首自听-FLAC" --port 5666
  # user: test / pass: test
"""
import argparse
import hashlib
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER, PASS, TOKEN = "test", "test", "mock-token"
MIME = {".flac": "audio/flac", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".ogg": "audio/ogg", ".wav": "audio/wav"}
TRACKS, BY_ID, PLAYLISTS, FAVS = [], {}, [], set()


def scan(root):
    for name in sorted(os.listdir(root)):
        base, ext = os.path.splitext(name)
        if ext.lower() not in MIME:
            continue
        artist, title = (base.split(" - ", 1) + [""])[:2] if " - " in base else ("", base)
        artists = [a.strip() for a in re.split(r"[_、&,，]", artist) if a.strip()]
        gid = hashlib.md5(name.encode()).hexdigest()[:16]
        t = {"guid": gid, "title": title.strip() or base, "artists": [{"guid": a, "name": a} for a in artists],
             "album": {"guid": "", "name": ""}, "duration": 0, "format": ext[1:].lower(),
             "path": os.path.join(root, name)}
        TRACKS.append(t)
        BY_ID[gid] = t
    count = {}
    for t in TRACKS:
        for a in t["artists"]:
            count.setdefault(a["name"], []).append(t)
    for a, ts in sorted(count.items()):
        if len(ts) >= 3:
            PLAYLISTS.append({"guid": "pl-" + hashlib.md5(a.encode()).hexdigest()[:8], "name": a + "精选",
                              "trackCount": len(ts), "tracks": ts})


def public(t):
    d = dict(t)
    d.pop("path")
    d["isFavorite"] = t["guid"] in FAVS
    return d


def page(items, q):
    p, s = int(q.get("page", 1)), int(q.get("size", 50))
    return {"list": [public(t) for t in items[(p - 1) * s: p * s]], "total": len(items)}


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        print("[mock-fnos]", self.command, self.path[:120])

    def send_json(self, data, code=0, status=200, msg="ok"):
        out = json.dumps({"code": code, "msg": msg, "data": data}, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def authed(self):
        if self.headers.get("Cookie", "").find("music-token=" + TOKEN) < 0:
            self.send_json(None, 401, 401, "invalid token")
            return False
        return True

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        p = u.path.replace("/music/api/v1", "")
        if not self.authed():
            return
        if p == "/track/list":
            return self.send_json(page(TRACKS, q))
        if p == "/search/track":
            kw = q.get("q", "").lower()
            hits = [t for t in TRACKS if kw in t["title"].lower() or any(kw in a["name"].lower() for a in t["artists"])]
            return self.send_json(page(hits, q))
        if p == "/playlist/list":
            return self.send_json({"list": [{k: v for k, v in pl.items() if k != "tracks"} for pl in PLAYLISTS],
                                   "total": len(PLAYLISTS)})
        if p == "/track/playlist-detail/list":
            pl = next((x for x in PLAYLISTS if x["guid"] == q.get("playlistGUID")), None)
            return self.send_json(page(pl["tracks"] if pl else [], q))
        if p == "/favorite-track/list":
            return self.send_json(page([BY_ID[g] for g in sorted(FAVS)], q))
        if p == "/lyric/list":
            return self.send_json({"list": [], "preferred": ""})
        if p == "/track/stream":
            return self.stream(BY_ID.get(q.get("guid", "")))
        self.send_json(None, 404, 404, "not found")

    def stream(self, t):
        if not t:
            return self.send_json(None, 404, 404, "no track")
        size = os.path.getsize(t["path"])
        start, end, status = 0, size - 1, 200
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                end = int(m.group(2)) if m.group(2) else size - 1
            else:
                start = size - int(m.group(2))
            end, status = min(end, size - 1), 206
        self.send_response(status)
        self.send_header("Content-Type", MIME[os.path.splitext(t["path"])[1].lower()])
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        with open(t["path"], "rb") as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        p = urlparse(self.path).path.replace("/music/api/v1", "")
        if p == "/user/password-login":
            if body.get("username") != USER or body.get("password") != hashlib.sha256(PASS.encode()).hexdigest():
                return self.send_json(None, 120001, 200, "bad password")
            return self.send_json({"userToken": TOKEN, "user": {"name": USER}})
        if not self.authed():
            return
        if p in ("/favorite-track/create", "/favorite-track/delete"):
            (FAVS.add if p.endswith("create") else FAVS.discard)(body.get("trackGUID"))
            return self.send_json(None)
        if p == "/event/report":
            return self.send_json(None)
        self.send_json(None, 404, 404, "not found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("music_dir")
    ap.add_argument("--port", type=int, default=5666)
    a = ap.parse_args()
    scan(a.music_dir)
    print("[mock-fnos] %d tracks, %d playlists, http://127.0.0.1:%d (user %s / pass %s)"
          % (len(TRACKS), len(PLAYLISTS), a.port, USER, PASS))
    ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
