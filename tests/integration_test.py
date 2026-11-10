#!/usr/bin/env python3
"""End-to-end tests: mock OpenAI + mock 飞牛音乐 server, mico-agent in dry-run."""
import hashlib
import json
import re
import os
import subprocess
import sys
import tempfile
import threading
import time
import socket
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, unquote, quote
import base64

LLM_REQUESTS = []
COMPLETE_REQUESTS = []  # mico.complete (no tools): 边播边存 naming
FN_REQUESTS = []
TOKEN = "tok-123"
TRACKS = [
    ("g1", "晴天", "周杰伦", "叶惠美"),
    ("g2", "七里香", "周杰伦", "七里香"),
    ("g3", "青花瓷", "周杰伦", "我很忙"),
    ("g4", "十年", "陈奕迅", "黑白灰"),
    ("g5", "浮夸", "陈奕迅", "U87"),
    ("g6", "海阔天空", "Beyond", "乐与怒"),
    ("g7", "离骚吟", "古琴社", "古韵", "ape"),  # speaker can't decode APE -> skipped
]


def track_json(t):
    j = {"guid": t[0], "title": t[1], "artists": [{"guid": "a", "name": t[2]}],
         "album": {"guid": "al", "name": t[3]}, "duration": 240000}
    if len(t) > 4:
        j["format"] = t[4]
    return j


# Scripted LLM: keyword in the user message -> list of tool calls to make in
# order; after the last one the final answer quotes the last tool result.
SCRIPTS = {
    "几点": [("get_time", {})],
    "青花": [("music_search", {"query": "青花词"}), ("music_play", "@first_id")],
    "命令": [("run_shell", {"command": "echo hello-shell"})],
    "请求": [("http_request", {"url": "@ping"})],
    "罗翔的播客": [("music_search", {"query": "罗翔的访谈", "kind": "audio", "online": True}),
                   ("music_play", "@first_id")],
}


def sr(bvid, title, duration, author="UP主", play=0):
    return {"bvid": bvid, "title": title, "author": author, "duration": duration, "play": play}


# Online search scenarios by exact keyword (default: BV1test / BV2test).
BILI_SEARCH = {
    "七里香精选测试": [sr("BVc1", "周杰伦 七里香 合集", "3:30"), sr("BVc2", "七里香 十小时循环", "600:00"),
                 sr("BVc3", "七里香精选测试 原版", "4:20", play=5)],
    "晴天": [sr("BVm1", "周杰伦演唱会全集", "95:00")],
    "稻香": [sr("BVs1", "周杰伦 全部歌曲", "50:00")],
    "无单曲": [sr("BVn1", "无单曲 现场", "70:00"), sr("BVn2", "无单曲 片段", "0:20")],
    "阿杜 歌曲": [sr("BVa1", "阿杜 他一定很爱你", "4:10"), sr("BVa2", "阿杜 演唱会合集", "4:00"),
              sr("BVa3", "别人的歌", "3:00", author="X")],
    "夜曲分P测试": [sr("BVh1", "周杰伦 经典合集", "60:00")],
    "罗翔的访谈": [sr("BVr1", "罗翔 访谈 全集", "2:10:00", play=9), sr("BVr2", "罗翔 短片", "0:30")],
}
BILI_VIEW = {
    "BVm1": {"cid": 100, "title": "周杰伦演唱会全集", "owner": {"name": "UP主"}, "pages": [
        {"cid": 101, "part": "开场", "duration": 200}, {"cid": 102, "part": "晴天", "duration": 270},
        {"cid": 103, "part": "稻香 live", "duration": 230}]},
    "BVs1": {"cid": 200, "title": "周杰伦 全部歌曲", "owner": {"name": "UP主"}, "pages": [{"cid": 200, "part": "p1", "duration": 3000}],
             "ugc_season": {"title": "周杰伦歌曲", "sections": [{"episodes": [
                 {"title": "七里香", "bvid": "BVe1", "cid": 301, "arc": {"duration": 299}},
                 {"title": "稻香", "bvid": "BVe2", "cid": 302, "arc": {"duration": 223}}]}]}},
    "BVh1": {"cid": 500, "title": "周杰伦 经典合集", "owner": {"name": "UP主"}, "pages": [
        {"cid": 501, "part": "开场", "duration": 200}, {"cid": 502, "part": "夜曲分P测试", "duration": 226}]},
    "BVn1": {"cid": 400, "title": "无单曲 现场", "pages": [
        {"cid": 401, "part": "别的", "duration": 200}, {"cid": 402, "part": "无单曲", "duration": 2000}]},
}


BILI_REQUESTS = []
REMOTE_PLUGIN = ("return {name='remote', type='online', version='1', description='r',"
                 " search=function() return {} end, stream=function(id) return 'http://x/'..id end}")
AUDIO = bytes(range(256)) * 12000  # ~3 MB
# Distinct per-part audio so a save of the wrong part (e.g. page 1) is detectable.
AUDIO_BY_PATH = {"/audio/BVm1-102": bytes(range(255, -1, -1)) * 3000,
                 "/audio/BVh1-502": b"part-502-" * 50000}


# Knobs for the mock online source (边播边存 tests).
MOCK = {"nolen": False, "slow": False, "title": None, "duration": "3:05", "norm": "error"}

# ---------------------------------------------------------------- mock WebDAV
DAV = {"files": {}, "cols": set(["/"]), "log": [], "reject_chunked": False}


class DavHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, length=0):
        self.send_response(status)
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def path_(self):
        return unquote(urlparse(self.path).path)

    def authed(self):
        want = "Basic " + base64.b64encode(b"nas:pw").decode()
        if self.headers.get("Authorization") != want:
            self.reply(401)
            return False
        return True

    def read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while True:
                line = self.rfile.readline()
                if not line:
                    raise IOError("truncated chunked body")
                n = int(line.strip().split(b";")[0], 16)
                if n == 0:
                    self.rfile.readline()
                    return out, True
                data = self.rfile.read(n)
                if len(data) != n:
                    raise IOError("truncated chunk")
                out += data
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(n)
        if len(data) != n:
            raise IOError("truncated body")
        return data, False

    def handle_dav(self):
        p = self.path_()
        DAV["log"].append((self.command, p, dict(self.headers)))
        if not self.authed():
            return
        m = self.command
        parent = p.rstrip("/").rsplit("/", 1)[0] + "/"
        if m == "MKCOL":
            if p in DAV["cols"]:
                return self.reply(405)
            if parent not in DAV["cols"]:
                return self.reply(409)
            DAV["cols"].add(p)
            return self.reply(201)
        if m == "PROPFIND":
            return self.reply(207 if p in DAV["cols"] or p in DAV["files"] else 404)
        if m == "HEAD":
            if p in DAV["files"]:
                return self.reply(200, len(DAV["files"][p]))
            return self.reply(404)
        if m == "PUT":
            try:
                data, chunked = self.read_body()
            except (IOError, ValueError):
                DAV["log"].append(("PUT-ABORTED", p, {}))
                self.close_connection = True
                return
            if chunked and DAV["reject_chunked"]:
                return self.reply(411)
            DAV["files"][p] = data
            DAV["log"].append(("PUT-DONE", p, {"chunked": chunked, "len": len(data)}))
            return self.reply(201)
        if m == "MOVE":
            dest = unquote(urlparse(self.headers.get("Destination", "")).path)
            if p not in DAV["files"]:
                return self.reply(404)
            if dest in DAV["files"] and self.headers.get("Overwrite") == "F":
                return self.reply(412)
            DAV["files"][dest] = DAV["files"].pop(p)
            return self.reply(201)
        if m == "DELETE":
            if p in DAV["files"]:
                del DAV["files"][p]
                return self.reply(204)
            return self.reply(404)
        self.reply(405)

    do_MKCOL = do_PROPFIND = do_HEAD = do_PUT = do_MOVE = do_DELETE = handle_dav


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send_json(self, obj, status=200):
        out = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else {}

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/ping":
            return self.send_json({"pong": True})
        if u.path == "/remote_plugin.lua":
            out = REMOTE_PLUGIN.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        if u.path.startswith("/x/") or u.path.startswith("/audio/"):
            return self.bili(u, q)
        FN_REQUESTS.append(("GET", u.path, q, self.headers.get("Cookie")))
        if self.headers.get("Cookie") != "music-token=" + TOKEN:
            return self.send_json({"code": 401, "msg": "invalid token"}, 401)
        if u.path == "/music/api/v1/track/list":
            page, size = int(q["page"]), int(q["size"])
            items = TRACKS[(page - 1) * size: page * size]
            return self.send_json({"code": 0, "data": {"list": [track_json(t) for t in items], "total": len(TRACKS)}})
        self.send_json({"code": 404, "msg": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        body = self.body()
        if u.path == "/v1/chat/completions":
            return self.llm(body)
        FN_REQUESTS.append(("POST", u.path, body, self.headers.get("Cookie")))
        if u.path == "/music/api/v1/user/password-login":
            if body.get("password") != hashlib.sha256(b"secret").hexdigest() or body.get("username") != "andy":
                return self.send_json({"code": 120001, "msg": "bad password"})
            return self.send_json({"code": 0, "data": {"userToken": TOKEN, "user": {"name": "andy"}}})
        if u.path == "/music/api/v1/event/report":
            return self.send_json({"code": 0, "data": None})
        self.send_json({"code": 404, "msg": "not found"}, 404)

    def bili(self, u, q):
        BILI_REQUESTS.append((u.path, q, dict(self.headers)))
        if u.path == "/x/frontend/finger/spi":
            return self.send_json({"code": 0, "data": {"b_3": "BUVID-TEST", "b_4": "x"}})
        if self.headers.get("Referer") != "http://www.mock/" or "Mozilla" not in (self.headers.get("User-Agent") or ""):
            return self.send_json({"code": -412, "message": "blocked"}, 412)
        if u.path == "/x/web-interface/search/type":
            if "buvid3=BUVID-TEST" not in (self.headers.get("Cookie") or ""):
                return self.send_json({"code": -412, "message": "no cookie"}, 412)
            if q.get("keyword") in BILI_SEARCH:
                return self.send_json({"code": 0, "data": {"result": BILI_SEARCH[q["keyword"]]}})
            return self.send_json({"code": 0, "data": {"result": [
                {"bvid": "BV1test", "title": MOCK["title"] or '<em class="keyword">测试</em>视频 &amp; 歌', "author": "UP主",
                 "duration": MOCK["duration"]},
                {"bvid": "BV2test", "title": "另一个", "author": "B", "duration": "1:00"}]}})
        if u.path == "/x/web-interface/view":
            if q.get("bvid") in BILI_VIEW:
                return self.send_json({"code": 0, "data": BILI_VIEW[q["bvid"]]})
            return self.send_json({"code": 0, "data": {"cid": 42 if q.get("bvid") == "BV1test" else 7}})
        if u.path == "/x/player/playurl":
            base = "http://127.0.0.1:%d/audio/" % self.server.server_port
            return self.send_json({"code": 0, "data": {"dash": {"audio": [
                {"id": 30216, "codecs": "mp4a.40.2", "bandwidth": 1000, "baseUrl": base + "low"},
                {"id": 30280, "codecs": "mp4a.40.2", "bandwidth": 9000, "baseUrl": base + q["bvid"] + "-" + q["cid"]}],
                "dolby": {"audio": [{"id": 30250, "codecs": "ec-3", "bandwidth": 99999, "baseUrl": base + "dolby"}]},
                "flac": {"audio": {"id": 30251, "codecs": "fLaC", "bandwidth": 99999, "baseUrl": base + "flac"}}}}})
        if u.path.startswith("/audio/"):
            full = AUDIO_BY_PATH.get(u.path, AUDIO)
            data, status = full, 200
            rng = self.headers.get("Range")
            headers = {"Content-Type": "audio/mp4", "Accept-Ranges": "bytes", "X-Secret": "no"}
            if rng:
                a, b = rng.split("=")[1].split("-")
                a, b = int(a), int(b) if b else len(full) - 1
                data, status = full[a:b + 1], 206
                headers["Content-Range"] = "bytes %d-%d/%d" % (a, b, len(full))
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            if not MOCK["nolen"]:
                self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            for i in range(0, len(data), 65536):
                if MOCK["slow"]:
                    time.sleep(0.05)
                try:
                    self.wfile.write(data[i:i + 65536])
                except OSError:
                    return
            return
        self.send_json({"code": -404, "message": "nf"}, 404)

    def llm(self, body):
        if not body.get("tools"):
            # One-shot mico.complete (no tools): reply with MOCK["norm"] or fail.
            COMPLETE_REQUESTS.append(body)
            if MOCK["norm"] == "error":
                return self.send_json({"error": "mock failure"}, 500)
            return self.send_json({"choices": [{"message": {"role": "assistant", "content": MOCK["norm"]}}]})
        LLM_REQUESTS.append(body)
        msgs = body["messages"]
        # Messages of the current turn: everything after the last user message.
        last_user = max(i for i, m in enumerate(msgs) if m["role"] == "user")
        user = msgs[last_user]["content"]
        turn = msgs[last_user + 1:]
        tool_results = [m for m in turn if m["role"] == "tool"]
        script = next((s for k, s in SCRIPTS.items() if k in user), [])
        if len(tool_results) < len(script):
            name, args = script[len(tool_results)]
            if args == "@first_id":
                args = {"id": json.loads(tool_results[-1]["content"])["results"][0]["id"]}
            elif args == {"url": "@ping"}:
                args = {"url": "http://127.0.0.1:%d/ping" % self.server.server_port}
            msg = {"role": "assistant", "content": None, "tool_calls": [{
                "id": "call_%d" % len(tool_results), "type": "function",
                "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)}}]}
        elif tool_results:
            msg = {"role": "assistant", "content": "结果:" + tool_results[-1]["content"][:200]}
        else:
            msg = {"role": "assistant", "content": "你好，我是测试助手"}
        self.send_json({"choices": [{"message": msg}]})


SRV_PORT = 0


def srv_port():
    return SRV_PORT


def fail(msg, out=""):
    print("FAIL:", msg)
    if out:
        print(out)
    sys.exit(1)


def run_once(binary, script, env, text):
    p = subprocess.run([binary, "-s", script, "--once", text], env=env,
                       capture_output=True, text=True, errors="replace", timeout=30)
    out = p.stdout + p.stderr
    if p.returncode != 0:
        fail("--once %r exit %d" % (text, p.returncode), out)
    return out


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def web_tests(binary, script, env, cfg_path):
    port = free_port()
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "instruction.log")
        open(log, "w").close()
        pdir = os.path.join(d, "plugins")
        os.mkdir(pdir)
        root = os.path.dirname(script)
        for f in ("fnos.lua", "bili.lua"):
            with open(os.path.join(root, "plugins", f)) as src, open(os.path.join(pdir, f), "w") as dst:
                dst.write(src.read())
        tdir = os.path.join(d, "tools")
        os.mkdir(tdir)
        with open(os.path.join(root, "tools", "get_time.lua")) as src, open(os.path.join(tdir, "get_time.lua"), "w") as dst:
            dst.write(src.read())
        logfile = os.path.join(d, "agent.log")
        wenv = dict(env, MICO_LOG_FILE=logfile, MICO_INSTRUCTION_LOG=log, MICO_WEB_LISTEN="127.0.0.1:%d" % port,
                    MICO_WEB_TOKEN="tk", MICO_PLUGINS_DIR=pdir, MICO_TOOLS_DIR=tdir)
        proc = subprocess.Popen([binary, "-s", script], env=wenv, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")
        base = "http://127.0.0.1:%d" % port

        def call(method, path, body=None, token="tk", headers=None):
            h = dict(headers or {})
            if token:
                h["Authorization"] = "Bearer " + token
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(base + path, data=data, method=method, headers=h)
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    return r.status, dict(r.headers), r.read()
            except urllib.error.HTTPError as e:
                return e.code, dict(e.headers), e.read()

        def js(method, path, body=None, **kw):
            st, _, b = call(method, path, body, **kw)
            return st, json.loads(b)

        try:
            for _ in range(50):
                try:
                    socket.create_connection(("127.0.0.1", port), 0.2).close()
                    break
                except OSError:
                    time.sleep(0.1)
            st, _, html = call("GET", "/", token=None)
            if st != 200 or b"<html" not in html:
                fail("GET / %d" % st)
            # Startup sync runs on the first tick (web is already up).
            for _ in range(50):
                st, j = js("GET", "/api/status")
                if j["index"]["last_sync_time"]:
                    break
                time.sleep(0.1)
            ix = j["index"]
            if ix["last_reason"] != "startup" or ix["tracks"] < 6 or ix["last_error"] is not False \
                    or not isinstance(ix["last_sync_ms"], int) or not ix["next_sync_time"] or ix["syncing"]:
                fail("startup sync status %r" % ix)
            st, j = js("GET", "/api/conversations")
            if not any(t["source"] == "system" and t["steps"][0]["name"] == "index_sync" for t in j["conversations"]):
                fail("sync event not logged %r" % j)
            if call("GET", "/api/status", token=None)[0] != 401:
                fail("auth not enforced")
            if call("GET", "/api/status?token=tk", token=None)[0] != 200:
                fail("query token")

            st, j = js("GET", "/api/config")
            if st != 200 or j["config"]["llm"]["api_key"] != "******" or j["config"]["llm"]["model"] != "file-model":
                fail("GET config masks key: %r" % j)
            if "llm.api_key" not in j["env_overrides"]:
                fail("env_overrides: %r" % j)
            if j["effective"]["llm"]["api_key"] != "******" or j["defaults"]["agent"]["max_steps"] != 8 \
                    or j["defaults"]["fast_path"]["min_score"] != 0.6 or j["defaults"]["llm"]["timeout_ms"] != 60000:
                fail("GET config defaults/effective: %r" % j)
            keys = {f["key"]: f for f in j["schema"]}
            for k in ("llm.model", "llm.api_key", "agent.system_prompt", "fast_path.margin", "playback.mode",
                      "web.listen", "shell.enabled", "instruction_log", "dry_run", "poll_ms"):
                if k not in keys or not keys[k].get("label") or not keys[k].get("help"):
                    fail("schema missing %s" % k)
            if keys["playback.mode"]["options"] != ["proxy", "download"] or not keys["web.listen"].get("restart") \
                    or keys["llm.api_key"]["type"] != "secret":
                fail("schema fields %r" % keys)

            st, j = js("PUT", "/api/config", {"llm": {"model": "m2", "api_key": "******"},
                                              "playback": {"buffer_kb": 2048}})
            saved = json.load(open(cfg_path))
            if st != 200 or saved["llm"]["model"] != "m2" or saved["llm"]["api_key"] != "file-key" \
                    or saved["playback"]["buffer_kb"] != 2048:
                fail("PUT config persist: %r %r" % (j, saved))
            if js("PUT", "/api/config", {"playback": {"buffer_kb": 10}})[0] != 400:
                fail("buffer_kb validation")
            for bad, key in (({"playback": {"mode": "x"}}, "playback.mode"), ({"shell": {"enabled": "yes"}}, "shell.enabled"),
                             ({"agent": {"max_steps": "abc"}}, "agent.max_steps"), ({"llm": {"model": 3}}, "llm.model"),
                             ({"fast_path": {"margin": 2}}, "fast_path.margin")):
                st, j = js("PUT", "/api/config", bad)
                if st != 400 or j.get("key") != key or not j.get("error"):
                    fail("validation %r -> %d %r" % (bad, st, j))
            st, j = js("PUT", "/api/config", {"agent": {"system_prompt": "SP-TEST", "max_steps": 3}})
            if st != 200 or j["config"]["agent"]["system_prompt"] != "SP-TEST":
                fail("PUT prompt %r" % j)
            LLM_REQUESTS.clear()
            js("POST", "/api/ask", {"text": "你好"})
            if not LLM_REQUESTS or "SP-TEST" not in json.dumps(LLM_REQUESTS[0], ensure_ascii=False):
                fail("system_prompt live: %r" % LLM_REQUESTS[:1])
            st, j = js("PUT", "/api/config", {"agent": {"system_prompt": None, "max_steps": None}})
            saved = json.load(open(cfg_path))
            if st != 200 or "agent" in saved or j["config"]["agent"]["max_steps"] != 8 \
                    or j["config"]["agent"]["system_prompt"] != j["defaults"]["agent"]["system_prompt"]:
                fail("null reset %r %r" % (j, saved))
            LLM_REQUESTS.clear()
            st, j = js("POST", "/api/ask", {"text": "你好"})
            if st != 200 or j["reply"] != "你好，我是测试助手" or LLM_REQUESTS[0]["model"] != "m2":
                fail("ask / live config: %r" % j)
            st, j = js("GET", "/api/conversations")
            c0 = j["conversations"][0] if j["conversations"] else {}
            if c0.get("user") != "你好" or c0.get("source") != "web" or c0.get("route") != "llm" \
                    or c0.get("status") != "done" or not isinstance(c0.get("duration_ms"), int):
                fail("conversations %r" % j)
            if not any(s["kind"] == "llm" and s["name"] == "m2" for s in c0["steps"]):
                fail("llm step %r" % c0)
            first_id = c0["id"]
            st, j = js("POST", "/api/ask", {"text": "现在几点"})
            st, j = js("GET", "/api/conversations?since=%d" % first_id)
            if len(j["conversations"]) != 1 or j["last_id"] != first_id + 1:
                fail("since %r" % j)
            steps = j["conversations"][0]["steps"]
            kinds = [s["kind"] for s in steps]
            tool = next((s for s in steps if s["kind"] == "tool"), None)
            if kinds.count("llm") != 2 or not tool or tool["name"] != "get_time" or "now" not in tool["result"] \
                    or not isinstance(tool["ms"], int):
                fail("tool steps %r" % steps)
            st, j = js("GET", "/api/conversations?since=%d" % (first_id + 1))
            if j["conversations"] != []:
                fail("since empty %r" % j)

            st, j = js("GET", "/api/status")
            v = j.get("version", {})
            if not re.match(r"^\d+\.\d+\.\d+", v.get("app", "")) or not v.get("git") or not v.get("lua", "").startswith("Lua") \
                    or not v.get("curl") or not v.get("compiler") or not v.get("build_time"):
                fail("version %r" % v)

            st, j = js("GET", "/api/plugins")
            names = {p["name"]: p for p in j}
            if names.get("fnos", {}).get("type") != "local" or names.get("bili", {}).get("type") != "online" \
                    or names["fnos"].get("builtin") is not True:
                fail("plugins list %r" % j)
            st, j = js("POST", "/api/plugins", {"source": "return {name='bad'}"})
            if st != 400:
                fail("bad plugin accepted")
            good = ("return {name='dummy', type='local', version='0.1', description='d',\n"
                    " list_tracks=function() return {{id='1', title='假歌', artist='某人', album=''}} end,\n"
                    " stream=function(id) return 'http://x/'..id, {} end}")
            st, j = js("POST", "/api/plugins", {"source": good})
            if st != 200 or not os.path.exists(os.path.join(pdir, "dummy.lua")):
                fail("plugin upload %r" % j)
            if js("POST", "/api/plugins", {"source": good})[0] != 409:
                fail("duplicate should 409")
            if js("POST", "/api/plugins", {"source": good, "overwrite": True})[0] != 200:
                fail("overwrite")
            st, j = js("GET", "/api/plugins/dummy/source")
            if st != 200 or j != {"name": "dummy", "source": good}:
                fail("get source %r" % j)
            st, j = js("PUT", "/api/plugins/dummy/source", {"source": "return {\nname='dummy',\n type = = 1}"})
            if st != 400 or "dummy.lua:3:" not in j["error"] or open(os.path.join(pdir, "dummy.lua")).read() != good:
                fail("syntax error put %r" % j)
            if js("PUT", "/api/plugins/dummy/source", {"source": good.replace("'dummy'", "'other'")})[0] != 400:
                fail("name mismatch put")
            good2 = good.replace("假歌", "真歌")
            st, j = js("PUT", "/api/plugins/dummy/source", {"source": good2})
            if st != 200 or open(os.path.join(pdir, "dummy.lua")).read() != good2 \
                    or open(os.path.join(pdir, "dummy.lua.bak")).read() != good:
                fail("put source %r" % j)
            st, j = js("GET", "/api/plugin-template")
            if st != 200 or "M.config" not in j["source"] or 'type = "local"' not in j["source"]:
                fail("template %r" % j)
            st, j = js("POST", "/api/plugins", {"source": j["source"]})
            if st != 200 or j["name"] != "myplugin":
                fail("template installs %r" % j)
            js("DELETE", "/api/plugins/myplugin")
            st, j = js("POST", "/api/plugins", {"url": "http://127.0.0.1:%d/remote_plugin.lua" % srv_port()})
            if st != 200 or j["name"] != "remote" or not os.path.exists(os.path.join(pdir, "remote.lua")):
                fail("install from url %r" % j)
            st, j = js("DELETE", "/api/plugins/remote")
            if st != 200 or os.path.exists(os.path.join(pdir, "remote.lua")) or "remote" in {p["name"] for p in j["plugins"]}:
                fail("delete %r" % j)
            if js("DELETE", "/api/plugins/fnos")[0] != 400 or not os.path.exists(os.path.join(pdir, "fnos.lua")):
                fail("builtin delete must be refused")
            st, j = js("POST", "/api/plugins/dummy/disable")
            if st != 200 or json.load(open(cfg_path))["plugins"]["enabled"]["dummy"] is not False:
                fail("disable persist %r" % j)
            js("POST", "/api/plugins/dummy/enable")

            # Agent tools.
            st, j = js("GET", "/api/tools")
            tl = {t["name"]: t for t in j} if st == 200 else {}
            gt = tl.get("get_time", {})
            if gt.get("source") != "custom" or not gt.get("editable") or not gt.get("enabled") \
                    or gt["stats"]["calls"] < 1 or "avg_ms" not in gt["stats"] or "last_time" not in gt["stats"]:
                fail("tools list get_time %r" % gt)
            hr = tl.get("http_request", {})
            if hr.get("source") != "builtin" or hr.get("editable") or not hr.get("parameters", {}).get("properties"):
                fail("tools list builtin %r" % hr)
            if js("DELETE", "/api/tools/http_request")[0] != 400 or js("GET", "/api/tools/http_request/source")[0] != 400 \
                    or js("PUT", "/api/tools/http_request/source", {"source": "x"})[0] != 400:
                fail("builtin tool edit/delete must be refused")
            if js("GET", "/api/tools/nope/source")[0] != 404:
                fail("unknown tool 404")
            st, j = js("POST", "/api/tools/get_time/disable")
            saved = json.load(open(cfg_path))
            if st != 200 or j["tool"]["enabled"] or saved["tools"]["disabled"].get("get_time") is not True:
                fail("tool disable %r %r" % (j, saved))
            LLM_REQUESTS.clear()
            js("POST", "/api/ask", {"text": "你好"})
            names = [t["function"]["name"] for t in LLM_REQUESTS[0].get("tools", [])]
            if "get_time" in names or "http_request" not in names:
                fail("disabled tool sent to LLM: %r" % names)
            st, j = js("POST", "/api/tools/get_time/test", {"args": {}})
            if st != 200 or "now" not in j.get("result", {}) or not isinstance(j.get("ms"), int):
                fail("tool test while disabled %r" % j)
            js("POST", "/api/tools/get_time/enable")
            if "get_time" in json.load(open(cfg_path)).get("tools", {}).get("disabled", {}):
                fail("tool enable persist")
            st, j = js("PUT", "/api/tools/http_request", {"description": "DESC-OVR"})
            if st != 200 or j["tool"]["description"] != "DESC-OVR" or j["tool"]["default_description"] == "DESC-OVR":
                fail("description override %r" % j)
            LLM_REQUESTS.clear()
            js("POST", "/api/ask", {"text": "你好"})
            descs = {t["function"]["name"]: t["function"]["description"] for t in LLM_REQUESTS[0]["tools"]}
            if descs.get("http_request") != "DESC-OVR" or "get_time" not in descs:
                fail("override not sent %r" % descs)
            st, j = js("PUT", "/api/tools/http_request", {"description": None})
            if st != 200 or j["tool"]["description"] != j["tool"]["default_description"] \
                    or "http_request" in json.load(open(cfg_path)).get("tools", {}).get("descriptions", {}):
                fail("description reset %r" % j)
            st, j = js("GET", "/api/tool-template")
            tpl = j["source"]
            st, j = js("POST", "/api/tools", {"source": tpl})
            if st != 200 or j["name"] != "my_tool" or not os.path.exists(os.path.join(tdir, "my_tool.lua")):
                fail("tool upload %r" % j)
            if js("POST", "/api/tools", {"source": tpl})[0] != 409:
                fail("tool conflict")
            if js("POST", "/api/tools", {"source": tpl.replace('"my_tool"', '"http_request"'), "overwrite": True})[0] != 409:
                fail("builtin name clash")
            st, j = js("POST", "/api/tools/my_tool/test", {"args": {"text": "ab", "times": 3}})
            if j.get("result", {}).get("result") != "ababab":
                fail("custom tool test %r" % j)
            st, j = js("GET", "/api/tools/my_tool/source")
            if st != 200 or j["source"] != tpl:
                fail("tool source %r" % j)
            st, j = js("PUT", "/api/tools/my_tool/source", {"source": "return {\nname='my_tool',\n x = = 1}"})
            if st != 400 or ":3:" not in j.get("error", ""):
                fail("tool syntax error line %r" % j)
            if js("PUT", "/api/tools/my_tool/source", {"source": tpl.replace('"my_tool"', '"other"')})[0] != 400:
                fail("tool name mismatch")
            st, j = js("PUT", "/api/tools/my_tool/source", {"source": tpl.replace("string.rep(", "string.upper(string.rep(").replace("n)", "n))")})
            if st != 200 or not os.path.exists(os.path.join(tdir, "my_tool.lua.bak")):
                fail("tool source save %r" % j)
            st, j = js("POST", "/api/tools/my_tool/test", {"args": {"text": "ab"}})
            if j.get("result", {}).get("result") != "ABAB":
                fail("tool reload %r" % j)
            st, j = js("DELETE", "/api/tools/my_tool")
            if st != 200 or os.path.exists(os.path.join(tdir, "my_tool.lua")) or any(t["name"] == "my_tool" for t in j["tools"]):
                fail("tool delete %r" % j)

            # Stream proxy: full body + Range passthrough with plugin headers.
            BILI_REQUESTS.clear()
            st, h, data = call("GET", "/stream/bili/BV1test")
            if st != 200 or data != AUDIO or h.get("Content-Type") != "audio/mp4" or "X-Secret" in h:
                fail("proxy full: %d %r len=%d" % (st, h, len(data)))
            st, h, data = call("GET", "/stream/bili/BV1test", headers={"Range": "bytes=100-199"})
            if st != 206 or data != AUDIO[100:200] or not h.get("Content-Range", "").startswith("bytes 100-199/"):
                fail("proxy range: %d %r" % (st, h))
            audio_reqs = [r for r in BILI_REQUESTS if r[0].startswith("/audio/")]
            if not audio_reqs or audio_reqs[-1][2].get("Range") != "bytes=100-199" \
                    or audio_reqs[-1][2].get("Referer") != "http://www.mock/":
                fail("upstream headers %r" % audio_reqs)
            if call("GET", "/stream/nope/x")[0] != 502:
                fail("unknown plugin stream")

            save_tests(js, call)
            log_tests(js, logfile)

            # Voice play in server mode uses the local proxy URL.
            with open(log, "a") as f:
                f.write(json.dumps({"header": {"dialog_id": "w1", "name": "RecognizeResult",
                                               "namespace": "SpeechRecognizer"},
                                    "payload": {"is_final": True, "results": [{"text": "播放晴天"}]}},
                                   ensure_ascii=False) + "\n")
            time.sleep(1.5)
            st, j = js("GET", "/api/status")
            if not j["now_playing"] or j["now_playing"]["id"] != "fnos:g1" or j["index_size"] < 6:
                fail("status %r" % j)
            st, j = js("GET", "/api/conversations")
            t = j["conversations"][0]
            info = [s for s in t["steps"] if s["kind"] == "info" and s["name"] == "fast_path"]
            play = [s for s in t["steps"] if s["kind"] == "play"]
            tts = [s for s in t["steps"] if s["kind"] == "tts"]
            if t["source"] != "voice" or t["route"] != "fast" or not info or "快路径：匹配 晴天/周杰伦" not in info[0]["result"] \
                    or not play or "/stream/fnos/g1" not in play[0]["args"]["url"] or tts[0]["args"]["text"] != "为你播放周杰伦的晴天":
                fail("fast turn steps %r" % t)
            # Manual sync returns status.
            st, j = js("POST", "/api/index/sync")
            if st != 200 or j["tracks"] < 6 or j["index"]["last_reason"] != "manual":
                fail("manual sync %r" % j)
            # Miss resync: a track added on the server after the last sync is found
            # after one resync (miss_resync_min elapsed), not before.
            st, j = js("PUT", "/api/config", {"index": {"miss_resync_min": 0.01}})
            if st != 200:
                fail("put index cfg %r" % j)
            js("POST", "/api/ask", {"text": "播放晴天"})  # lazy re-sync after config change
            TRACKS.append(("g8", "蒲公英的约定", "周杰伦", "我很忙"))
            try:
                time.sleep(1.0)
                js("POST", "/api/ask", {"text": "播放蒲公英的约定"})
                st, j = js("GET", "/api/status")
                if not j["now_playing"] or j["now_playing"]["id"] != "fnos:g8" or j["index"]["last_reason"] != "miss" \
                        or j["index"]["tracks"] != j["index_size"]:
                    fail("miss resync %r" % j)
            finally:
                TRACKS.pop()
            st, j = js("PUT", "/api/config", {"index": {"miss_resync_min": 0}})
            # Interval sync driven by on_tick.
            js("PUT", "/api/config", {"index": {"sync_interval_min": 0.02}})
            time.sleep(2.5)
            st, j = js("GET", "/api/status")
            if j["index"]["last_reason"] != "interval" or j["index"]["tracks"] < 6 or not j["index"]["next_sync_time"]:
                fail("interval sync %r" % j["index"])
            st, j = js("PUT", "/api/config", {"index": {"sync_interval_min": 0}})
            time.sleep(1.2)
            if js("GET", "/api/status")[1]["index"]["next_sync_time"] is not False:
                fail("interval off")
            st, j = js("PUT", "/api/config", {"index": {"sync_interval_min": -1}})
            if st != 400:
                fail("interval validation %r" % j)
        finally:
            proc.terminate()
            out, _ = proc.communicate(timeout=5)
        if "player_play_url" not in out or "127.0.0.1:%d/stream/fnos/g1?token=tk" % port not in out:
            fail("proxy playback url", out)


def log_tests(js, logfile):
    st, j = js("GET", "/api/config")
    keys = {f["key"] for f in j["schema"]}
    if not {"log.file", "log.max_kb", "log.keep", "log.stderr"} <= keys:
        fail("log schema")
    st, j = js("GET", "/api/logs?lines=5")
    if st != 200 or j["file"] != logfile or len(j["lines"]) != 5 or j["size"] <= 0 \
            or not all(isinstance(l, str) for l in j["lines"]):
        fail("logs tail %r" % j)
    if "[save]" not in open(logfile, encoding="utf-8", errors="replace").read() + \
            "".join(open(logfile + ".1", encoding="utf-8", errors="replace").read() if os.path.exists(logfile + ".1") else ""):
        fail("[save] lines missing from log")
    if any("pw" in l.split() for l in js("GET", "/api/logs?lines=1000")[1]["lines"]):
        fail("password logged")
    if len(js("GET", "/api/logs?lines=5000")[1]["lines"]) > 1000:
        fail("logs cap")
    # Rotation: small cap, keep=2.
    js("PUT", "/api/config", {"log": {"max_kb": 64, "keep": 2, "stderr": False}})
    for i in range(800):
        js("POST", "/api/ask", {"text": "你好" + "x" * 250})
    sizes = [os.path.getsize(logfile + s) if os.path.exists(logfile + s) else -1 for s in ("", ".1", ".2", ".3")]
    if sizes[1] < 0 or sizes[2] < 0 or sizes[3] != -1 or max(sizes) > 64 * 1024:
        fail("rotation sizes %r" % sizes)
    js("PUT", "/api/config", {"log": {"keep": 0}})
    for i in range(400):
        js("POST", "/api/ask", {"text": "你好" + "x" * 200})
    if os.path.getsize(logfile) > 64 * 1024:
        fail("keep=0 size")
    st, j = js("GET", "/api/logs?lines=3")
    if len(j["lines"]) != 3 or "你好" not in "".join(js("GET", "/api/logs?lines=50")[1]["lines"]):
        fail("tail after rotation %r" % j)
    js("PUT", "/api/config", {"log": {"max_kb": None, "keep": None, "stderr": None}})


def save_tests(js, call):
    """边播边存: online track streamed into a mock WebDAV share."""
    dav = ThreadingHTTPServer(("127.0.0.1", 0), DavHandler)
    threading.Thread(target=dav.serve_forever, daemon=True).start()
    dport = dav.server_port
    base_url = "http://127.0.0.1:%d/音乐/在线 收藏/" % dport
    folder = "/音乐/在线 收藏/"
    final = folder + "测试视频.m4a"
    DAV["cols"].add("/音乐/")

    st, j = js("GET", "/api/config")
    keys = {f["key"]: f for f in j["schema"]}
    for k in ("save.enabled", "save.webdav_url", "save.username", "save.password", "save.filename",
              "save.min_duration_s", "save.max_duration_s", "save.max_size_mb", "save.queue_size",
              "save.skip_keywords", "save.require_match", "save.normalize", "save.normalize_timeout_ms",
              "save.require_artist"):
        if k not in keys or not keys[k].get("label") or not keys[k].get("help"):
            fail("save schema missing %s" % k)
    d = j["defaults"]["save"]
    if d["enabled"] is not False or d["queue_size"] != 3 or keys["save.password"]["type"] != "secret" \
            or d["max_size_mb"] != 200 or "合集" not in d["skip_keywords"] \
            or d["normalize"] is not True or d["require_artist"] is not True or d["normalize_timeout_ms"] != 8000:
        fail("save defaults %r" % d)
    if js("PUT", "/api/config", {"save": {"queue_size": 21}})[0] != 400 \
            or js("PUT", "/api/config", {"save": {"max_size_mb": 0}})[0] != 400:
        fail("save validation")

    def jobs():
        return js("GET", "/api/save/jobs")[1]

    def play_and_wait(n_before):
        js("POST", "/api/ask", {"text": "播放B站的测试视频"})
        for _ in range(150):
            jl = jobs()
            if len(jl) > n_before and jl[0]["status"] not in ("queued", "running"):
                return jl[0]
            time.sleep(0.1)
        fail("save job did not finish %r" % jobs())

    def setcfg(**kw):
        st, j = js("PUT", "/api/config", {"save": kw})
        if st != 200:
            fail("save cfg %r" % j)

    # Disabled (default): nothing uploaded, no jobs.
    DAV["log"].clear()
    js("POST", "/api/ask", {"text": "播放B站的测试视频"})
    time.sleep(1.2)
    if DAV["log"] or jobs() != []:
        fail("save disabled but uploaded %r" % DAV["log"])

    # Connectivity test.
    # Basic transfer tests use rule naming without an artist.
    setcfg(webdav_url="http://127.0.0.1:1/x/", username="nas", password="pw", normalize=False, require_artist=False)
    st, j = js("POST", "/api/save/test")
    if st != 200 or j.get("ok") is not False or not j.get("error"):
        fail("dav test unreachable %r" % j)
    setcfg(webdav_url=base_url, password="bad")
    st, j = js("POST", "/api/save/test")
    if j.get("ok") is not False or j.get("status") != 401:
        fail("dav test bad auth %r" % j)
    setcfg(password="pw")
    st, j = js("POST", "/api/save/test")
    if j.get("ok") is not True or folder not in DAV["cols"]:
        fail("dav test ok %r" % j)
    if js("GET", "/api/config")[1]["config"]["save"]["password"] != "******":
        fail("save password not masked")

    # Enabled: file arrives under the clean name via .part + MOVE.
    setcfg(enabled=True)
    DAV["log"].clear()
    job = play_and_wait(0)
    if job["status"] != "done" or DAV["files"].get(final) != AUDIO or job["bytes"] != len(AUDIO) \
            or job["total"] != len(AUDIO) or "测试视频" not in job["name"]:
        fail("save done %r %r" % (job, list(DAV["files"])))
    puts = [l for l in DAV["log"] if l[0] == "PUT"]
    if not puts or puts[0][1] != final + ".part" or puts[0][2].get("Content-Length") != str(len(AUDIO)) \
            or not any(l[0] == "MOVE" for l in DAV["log"]) or final + ".part" in DAV["files"]:
        fail("save .part/move %r" % [(l[0], l[1]) for l in DAV["log"]])
    st, conv = js("GET", "/api/conversations")
    steps = [s for s in conv["conversations"][0]["steps"] if s["name"] == "save"]
    if not steps or "开始保存" not in steps[0]["result"]:
        fail("save step %r" % conv["conversations"][0])

    # Already there -> skipped (no PUT).
    DAV["log"].clear()
    job = play_and_wait(1)
    if job["status"] != "skipped" or "已存在" not in job.get("reason", "") or any(l[0] == "PUT" for l in DAV["log"]):
        fail("dedupe %r" % job)

    # No upstream Content-Length -> chunked PUT.
    del DAV["files"][final]
    MOCK["nolen"] = True
    try:
        DAV["log"].clear()
        job = play_and_wait(2)
        done = [l for l in DAV["log"] if l[0] == "PUT-DONE"]
        if job["status"] != "done" or DAV["files"].get(final) != AUDIO or not done or not done[0][2]["chunked"]:
            fail("chunked save %r %r" % (job, done))
        del DAV["files"][final]
        # Server refuses chunked uploads -> failed, .part cleaned.
        DAV["reject_chunked"] = True
        job = play_and_wait(3)
        DAV["reject_chunked"] = False
        if job["status"] != "failed" or "411" not in job.get("reason", "") or DAV["files"]:
            fail("411 %r %r" % (job, list(DAV["files"])))
        # Size limit exceeded mid-transfer -> failed, .part deleted.
        setcfg(max_size_mb=1)
        DAV["log"].clear()
        job = play_and_wait(4)
        if job["status"] != "failed" or DAV["files"] or not any(l[0] == "DELETE" for l in DAV["log"]):
            fail("size limit stream %r %r" % (job, [(l[0], l[1]) for l in DAV["log"]]))
    finally:
        MOCK["nolen"] = False
        DAV["reject_chunked"] = False
    # Known size over the limit -> skipped before uploading.
    DAV["log"].clear()
    job = play_and_wait(5)
    if job["status"] != "skipped" or any(l[0] == "PUT" for l in DAV["log"]):
        fail("size limit known %r" % job)
    setcfg(max_size_mb=200)

    # Keyword / duration -> skipped without touching WebDAV.
    MOCK["title"] = "测试视频 LIVE 现场版"
    DAV["log"].clear()
    job = play_and_wait(6)
    MOCK["title"] = None
    if job["status"] != "skipped" or "关键词" not in job.get("reason", "") or DAV["log"]:
        fail("keyword skip %r" % job)
    setcfg(max_duration_s=120)
    job = play_and_wait(7)
    setcfg(max_duration_s=600)
    if job["status"] != "skipped" or "时长" not in job.get("reason", "") or DAV["log"]:
        fail("duration skip %r" % job)

    # queue_size = 0: a second request while one is saving is dropped.
    setcfg(queue_size=0)
    MOCK["slow"] = True
    try:
        js("POST", "/api/ask", {"text": "播放B站的测试视频"})
        js("POST", "/api/ask", {"text": "播放B站的测试视频"})
        st, conv = js("GET", "/api/conversations")
        steps = [s for s in conv["conversations"][0]["steps"] if s["name"] == "save"]
        if len(jobs()) != 9 or not steps or "队列已满" not in steps[0]["result"]:
            fail("queue_size 0 %r %r" % (jobs()[:2], steps))
        for _ in range(100):
            if jobs()[0]["status"] not in ("queued", "running"):
                break
            time.sleep(0.1)
        if jobs()[0]["status"] != "skipped":  # file exists from the earlier save? no: removed -> done
            pass
    finally:
        MOCK["slow"] = False
    setcfg(queue_size=3)
    for _ in range(100):
        if jobs()[0]["status"] not in ("queued", "running"):
            break
        time.sleep(0.1)
    naming_tests(js, jobs, setcfg, folder)
    part_save_tests(js, jobs, setcfg, folder)
    # kind=audio (fast path "访谈"): long item plays but is never saved.
    top = jobs()[0]["id"]
    st, j = js("POST", "/api/ask", {"text": "播放罗翔的访谈"})
    if j.get("reply") != "为你播放罗翔的访谈":
        fail("audio fast path reply %r" % j)
    jl = jobs()
    if jl[0]["id"] <= top or jl[0]["status"] != "skipped" or jl[0].get("reason") != "非歌曲内容不保存":
        fail("audio saved %r" % jl[:1])
    setcfg(enabled=False, queue_size=3)
    dav.shutdown()


def naming_tests(js, jobs, setcfg, folder):
    """边播边存 naming: LLM normalization, library spelling, rule fallback."""
    def play(text):
        top = jobs()[0]["id"] if jobs() else 0
        js("POST", "/api/ask", {"text": text})
        for _ in range(150):
            jl = jobs()
            if jl and jl[0]["id"] > top and jl[0]["status"] not in ("queued", "running"):
                st, conv = js("GET", "/api/conversations")
                notes = [s["result"] for s in conv["conversations"][0]["steps"] if s["name"] == "save"]
                return jl[0], " | ".join(notes)
            time.sleep(0.1)
        st, lg = js("GET", "/api/logs?lines=40")
        fail("naming job did not finish %r" % jobs()[:2], "\n".join(lg.get("lines", [])))

    setcfg(normalize=True, require_artist=True, require_match=True)
    # LLM fixes the homophone and strips decorations.
    MOCK["title"] = "【4K】周杰轮 七里香 MV"
    MOCK["norm"] = '```json\n{"artist": "周杰伦", "title": "七里香", "confident": true}\n```'
    n = len(COMPLETE_REQUESTS)
    job, notes = play("播放B站的周杰轮的七里香")
    f = folder + "周杰伦 - 七里香.m4a"
    if job["status"] != "done" or DAV["files"].get(f) != AUDIO or "命名来源 llm" not in notes or "LLM" not in notes:
        fail("llm naming %r %r %r" % (job, notes, list(DAV["files"])))
    req = COMPLETE_REQUESTS[n] if len(COMPLETE_REQUESTS) > n else {}
    prompt = json.dumps(req.get("messages"), ensure_ascii=False)
    if req.get("tools") or "周杰轮的七里香" not in prompt or "【4K】周杰轮 七里香 MV" not in prompt:
        fail("complete request %r" % req)
    if any("七里香" in json.dumps(r["messages"], ensure_ascii=False) and "confident" in json.dumps(r["messages"], ensure_ascii=False)
           for r in LLM_REQUESTS):
        fail("naming prompt leaked into agent history")
    del DAV["files"][f]

    # Not the original -> skipped.
    MOCK["norm"] = '{"artist": "周杰伦", "title": "七里香", "confident": false}'
    job, notes = play("播放B站的周杰轮的七里香")
    if job["status"] != "skipped" or "大模型判断不是原曲" not in job.get("reason", "") or f in DAV["files"]:
        fail("confident=false %r" % job)

    # LLM error -> rule fallback: "周杰轮" is a library artist -> split + library spelling.
    MOCK["norm"] = "error"
    job, notes = play("播放B站的周杰轮的七里香")
    if job["status"] != "done" or f not in DAV["files"] or "rule+library" not in notes or "LLM 失败" not in notes:
        fail("rule fallback %r %r %r" % (job, notes, list(DAV["files"])))
    del DAV["files"][f]

    # require_artist: no artist determined -> skipped.
    MOCK["title"] = None
    job, notes = play("播放B站的测试视频")
    if job["status"] != "skipped" or "未确定歌手" not in job.get("reason", ""):
        fail("require_artist %r" % job)

    # Library spelling wins over the LLM's.
    MOCK["title"] = "【Hi-Res】BEYOND 海阔天空"
    MOCK["norm"] = '好的：{"artist": "BEYOND", "title": "海阔天空", "confident": true}'
    job, notes = play("播放B站的beyond的海阔天空")
    f = folder + "Beyond - 海阔天空.m4a"
    if job["status"] != "done" or f not in DAV["files"] or "llm+library" not in notes:
        fail("library spelling %r %r %r" % (job, notes, list(DAV["files"])))

    # "我的歌声里" is not split into artist "我".
    MOCK["norm"] = "error"
    MOCK["title"] = "曲婉婷 歌声里 原唱"
    setcfg(require_artist=False, require_match=False)
    job, notes = play("播放B站的我的歌声里")
    f = folder + "我的歌声里.m4a"
    if job["status"] != "done" or f not in DAV["files"]:
        fail("no split %r %r %r" % (job, notes, list(DAV["files"])))
    MOCK["title"] = None
    setcfg(require_match=True)


def part_save_tests(js, jobs, setcfg, folder):
    """边播边存 of a part picked from a multi-part video, and artist-only requests."""
    def play(text):
        top = jobs()[0]["id"] if jobs() else 0
        BILI_REQUESTS.clear()
        js("POST", "/api/ask", {"text": text})
        for _ in range(150):
            jl = jobs()
            if jl and jl[0]["id"] > top and jl[0]["status"] not in ("queued", "running"):
                return jl[0]
            time.sleep(0.1)
        fail("part save job did not finish %r" % jobs()[:2])

    def cids(bvid):
        return [r[1].get("cid") for r in BILI_REQUESTS if r[0] == "/x/player/playurl" and r[1].get("bvid") == bvid]

    def audio_paths():
        return [r[0] for r in BILI_REQUESTS if r[0].startswith("/audio/")]

    setcfg(normalize=True, require_artist=True, require_match=True)
    # Part 2 of "周杰伦演唱会全集" (no single qualifies).
    MOCK["norm"] = '{"artist": "周杰伦", "title": "晴天", "confident": true}'
    job = play("在线播放晴天")
    f = folder + "周杰伦 - 晴天.m4a"
    if job["status"] != "done" or DAV["files"].get(f) != AUDIO_BY_PATH["/audio/BVm1-102"] \
            or job["bytes"] != len(AUDIO_BY_PATH["/audio/BVm1-102"]):
        fail("part save %r %r" % (job, list(DAV["files"])))
    if not cids("BVm1") or set(cids("BVm1")) != {"102"} or "/audio/BVm1-100" in audio_paths() \
            or "/audio/BVm1-101" in audio_paths():
        fail("part save used wrong cid %r %r" % (cids("BVm1"), audio_paths()))

    # Parent title has "合集", the part title is clean -> still saved.
    MOCK["norm"] = '{"artist": "周杰伦", "title": "夜曲", "confident": true}'
    job = play("在线播放夜曲分P测试")
    f = folder + "周杰伦 - 夜曲.m4a"
    if job["status"] != "done" or DAV["files"].get(f) != AUDIO_BY_PATH["/audio/BVh1-502"]:
        fail("collection part save %r %r" % (job, list(DAV["files"])))
    if set(cids("BVh1")) != {"502"}:
        fail("collection part wrong cid %r" % cids("BVh1"))

    # Artist-only online request -> named via the LLM.
    MOCK["norm"] = '{"artist": "阿杜", "title": "他一定很爱你", "confident": true}'
    n = len(COMPLETE_REQUESTS)
    job = play("在线播放阿杜的歌")
    f = folder + "阿杜 - 他一定很爱你.m4a"
    if job["status"] != "done" or DAV["files"].get(f) != AUDIO or len(COMPLETE_REQUESTS) <= n:
        fail("artist-only save %r %r" % (job, list(DAV["files"])))
    MOCK["norm"] = "error"


def online_filter_tests(binary, script, env):
    """Online song filtering: duration/keywords, multi-part, collections, artist-only, audio."""
    def play(text):
        LLM_REQUESTS.clear()
        BILI_REQUESTS.clear()
        return run_once(binary, script, env, text)

    def searches():
        return [r[1] for r in BILI_REQUESTS if r[0] == "/x/web-interface/search/type"]

    out = play("在线播放七里香精选测试")
    if "/audio/BVc3-7" not in out or LLM_REQUESTS:
        fail("compilation not excluded", out)
    s = searches()
    if not s or s[0].get("duration") != "1" or s[0].get("tids") != "3":
        fail("song search filters %r" % s)
    out = play("在线播放晴天")
    if "/audio/BVm1-102" not in out or "playurl" in out and "cid=102" not in str(BILI_REQUESTS):
        fail("multi-part pick", out)
    if not any(r[0] == "/x/player/playurl" and r[1].get("cid") == "102" for r in BILI_REQUESTS):
        fail("stream did not use part cid %r" % BILI_REQUESTS)
    out = play("在线播放稻香")
    if "/audio/BVe2-302" not in out:
        fail("ugc_season episode pick", out)
    out = play("在线播放无单曲")
    if "/audio/BVn" in out or not LLM_REQUESTS:
        fail("nothing qualifies should go to LLM", out)
    out = play("在线播放阿杜的歌")
    if "/audio/BVa1-7" not in out or LLM_REQUESTS or searches()[0].get("keyword") != "阿杜 歌曲":
        fail("artist-only online", out)
    out = play("播放罗翔的访谈")
    if "/audio/BVr1-7" not in out or LLM_REQUESTS or "为你播放罗翔的访谈" not in out:
        fail("audio fast path", out)
    if any("duration" in q or "tids" in q for q in searches()):
        fail("audio search must not filter %r" % searches())
    out = play("找个罗翔的播客")
    if "[tool] music_search" not in out or "/audio/BVr1-7" not in out:
        fail("music_search kind=audio", out)
    params = LLM_REQUESTS[0]["tools"]
    ms = next(t for t in params if t["function"]["name"] == "music_search")
    if "kind" not in ms["function"]["parameters"]["properties"]:
        fail("music_search kind param missing")


def main():
    binary = os.path.abspath(sys.argv[1])
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % srv.server_port
    tmp = tempfile.mkdtemp()
    cfg_path = os.path.join(tmp, "config.json")
    with open(cfg_path, "w") as f:
        json.dump({
            "llm": {"base_url": "http://127.0.0.1:1/unused", "api_key": "file-key", "model": "file-model",
                    "extra": {"enable_thinking": False}},
            "web": {"listen": ""},
        }, f)
    # Env overrides the file for base_url / api_key; model comes from the file.
    env = dict(os.environ, MICO_CONFIG=cfg_path, MICO_LLM_BASE_URL=base + "/v1", MICO_LLM_API_KEY="test",
               MICO_DRY_RUN="1", MICO_FN_URL=base, MICO_FN_USER="andy", MICO_FN_PASS="secret",
               MICO_BILI_API=base, MICO_BILI_WWW="http://www.mock")
    global SRV_PORT
    SRV_PORT = srv.server_port
    script = os.path.join(root, "scripts", "main.lua")

    # 1. Plain tool call round trip.
    out = run_once(binary, script, env, "现在几点")
    if "[tool] get_time" not in out or "tts_play.sh '结果:" not in out:
        fail("get_time round trip", out)
    req = LLM_REQUESTS[0]
    if req["model"] != "file-model" or req.get("enable_thinking") is not False:
        fail("config not applied: %r" % req)
    names = {t["function"]["name"] for t in req["tools"]}
    expected = {"run_shell", "http_request", "music_search", "music_play", "music_stop",
                "music_now_playing", "get_time"}
    if names != expected:
        fail("advertised tools mismatch: %r" % names)

    # 2. Fast path with an ASR homophone: no LLM call, login + sync + play g2.
    LLM_REQUESTS.clear()
    FN_REQUESTS.clear()
    out = run_once(binary, script, env, "播放周杰轮的七里香")
    if LLM_REQUESTS:
        fail("fast path should not call the LLM", out)
    if not any(r[1].endswith("/user/password-login") for r in FN_REQUESTS):
        fail("no login", out)
    if "track/stream?guid=g2" not in out or "Cookie: music-token=" + TOKEN not in out:
        fail("fast path did not play g2 with cookie", out)
    if "为你播放周杰伦的七里香" not in out:
        fail("fast path announcement", out)

    # 3. Artist-only request plays a random song by that artist.
    out = run_once(binary, script, env, "来点陈亦迅的歌")
    if "guid=g4" not in out and "guid=g5" not in out:
        fail("artist request", out)

    # 4. LLM-driven: music_search (fuzzy) then music_play with the returned id.
    LLM_REQUESTS.clear()
    out = run_once(binary, script, env, "帮我找一下青花词那首")
    if "[tool] music_search" not in out or "[tool] music_play" not in out or "guid=g3" not in out:
        fail("LLM music flow", out)

    # 5. Shell and HTTP tools.
    out = run_once(binary, script, env, "执行一个命令")
    if "hello-shell" not in out:
        fail("run_shell", out)
    out = run_once(binary, script, env, "发一个请求")
    if "pong" not in out:
        fail("http_request", out)

    # 5b. Online fallback (bili mock) via fast path; --once has no web server so
    # playback falls back to download with the plugin's headers.
    out = run_once(binary, script, env, "播放B站的测试视频")
    if "/audio/BV1test-42" not in out or "Referer: http://www.mock/" not in out:
        fail("bili online play", out)
    if "-> 测试视频 & 歌 UP主" not in out or "为你播放测试视频'" not in out:
        fail("bili title cleanup", out)
    if "/audio/dolby" in out or "/audio/flac" in out:
        fail("must never pick dolby/flac", out)
    # "在B站播放X" / "在线播放X" prefixes (fast path, no LLM).
    for text in ("在B站播放测试视频", "在线播放测试视频"):
        LLM_REQUESTS.clear()
        out = run_once(binary, script, env, text)
        if LLM_REQUESTS or "/audio/BV1test-42" not in out:
            fail("online prefix %r" % text, out)
    # APE tracks are not indexed (speaker ffmpeg can't decode them).
    out = run_once(binary, script, env, "播放离骚吟")
    if "guid=g7" in out:
        fail("ape track played", out)

    online_filter_tests(binary, script, env)

    # 5c. Shell can be disabled from the config file.
    with open(cfg_path) as f:
        c = json.load(f)
    c["shell"] = {"enabled": False}
    with open(cfg_path, "w") as f:
        json.dump(c, f)
    LLM_REQUESTS.clear()
    run_once(binary, script, env, "你好")
    if "run_shell" in {t["function"]["name"] for t in LLM_REQUESTS[0]["tools"]}:
        fail("shell.enabled=false not applied")
    del c["shell"]
    with open(cfg_path, "w") as f:
        json.dump(c, f)

    web_tests(binary, script, env, cfg_path)

    # 6. Follow instruction.log; duplicate final results are handled once.
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "instruction.log")
        open(log, "w").write("history line\n")
        proc = subprocess.Popen([binary, "-s", script], env=dict(env, MICO_INSTRUCTION_LOG=log),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        time.sleep(0.5)

        def line(text, final, dialog):
            return json.dumps({
                "header": {"dialog_id": dialog, "name": "RecognizeResult", "namespace": "SpeechRecognizer"},
                "payload": {"is_final": final, "results": [{"text": text}]},
            }, ensure_ascii=False) + "\n"

        with open(log, "a") as f:
            f.write(line("你", False, "d1"))
            f.write(line("你好", True, "d1"))
            f.write(line("你好", True, "d1"))
        time.sleep(1.5)
        proc.terminate()
        out, _ = proc.communicate(timeout=5)
        if out.count("user: 你好") != 1 or "tts_play.sh '你好，我是测试助手'" not in out:
            fail("log follow", out)
    srv.shutdown()
    print("integration tests: ok")


if __name__ == "__main__":
    main()
