// Minimal unit tests without a framework.
#include <unistd.h>

#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "instruction.h"
#include "runtime.h"
#include "saver.h"
#include "tail.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
}

static int failures = 0;
#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

static void test_parse_recognition() {
    mico::Recognition r;
    std::string ok =
        R"(prefix {"header":{"dialog_id":"d1","name":"RecognizeResult","namespace":"SpeechRecognizer"},)"
        R"("payload":{"is_final":true,"results":[{"text":" 播放晴天 "}]}})";
    CHECK(mico::parse_recognition(ok, r));
    CHECK(r.text == "播放晴天");
    CHECK(r.final);
    CHECK(r.dialog_id == "d1");

    std::string other = R"({"header":{"name":"Speak","namespace":"SpeechSynthesizer"},"payload":{}})";
    CHECK(!mico::parse_recognition(other, r));
    CHECK(!mico::parse_recognition("not json", r));
    std::string empty =
        R"({"header":{"name":"RecognizeResult","namespace":"SpeechRecognizer"},"payload":{"results":[{"text":""}]}})";
    CHECK(!mico::parse_recognition(empty, r));
    std::string bad_types =
        R"({"header":{"name":1,"namespace":"SpeechRecognizer"},"payload":{"results":[{"text":"x"}]}})";
    CHECK(!mico::parse_recognition(bad_types, r));
}

static void test_ring_buffer() {
    mico::RingBuffer r(8);
    char out[16];
    CHECK(r.write("abcdef", 6) == 6);
    CHECK(r.read(out, 4) == 4 && std::string(out, 4) == "abcd");
    CHECK(r.write("123456789", 9) == 6);  // wraps, capped at free space
    CHECK(r.size() == 8 && r.free_space() == 0);
    CHECK(r.read(out, 16) == 8 && std::string(out, 8) == "ef123456");
    CHECK(r.size() == 0);
    r.write("xyz", 3);
    r.reserve(32);
    CHECK(r.capacity() == 32 && r.read(out, 16) == 3 && std::string(out, 3) == "xyz");
    CHECK(mico::ext_for_content_type("audio/mpeg") == "mp3");
    CHECK(mico::ext_for_content_type("Audio/MP4; codecs=x") == "m4a");
    CHECK(mico::ext_for_content_type("audio/x-flac") == "flac");
    CHECK(mico::ext_for_content_type("") == "m4a");
}

static void test_json_roundtrip() {
    mico::Runtime rt;
    lua_State* L = rt.L();
    CHECK(luaL_dostring(L, "return {a=1, b={1,2,'x'}, c=true, d=1.5, e={}}") == 0);
    mico::json j = mico::lua_to_json(L, -1);
    lua_pop(L, 1);
    CHECK(j["a"] == 1);
    CHECK(j["b"].is_array() && j["b"].size() == 3 && j["b"][2] == "x");
    CHECK(j["c"] == true);
    CHECK(j["d"] == 1.5);
    CHECK(j["e"].is_object());

    mico::push_json(L, mico::json::parse(R"({"k":[10,{"z":"w"}]})"));
    lua_setglobal(L, "t");
    CHECK(luaL_dostring(L, "assert(t.k[1] == 10 and t.k[2].z == 'w')") == 0);

    // Optional null sentinel for json_decode.
    CHECK(luaL_dostring(L, "local N = {}; local d = mico.json_decode('{\"a\":null,\"b\":[1,null]}', N);"
                           "assert(d.a == N and d.b[2] == N); assert(mico.json_decode('{\"a\":null}').a == nil)") == 0);

    // Invalid UTF-8 (e.g. binary shell output) must not throw.
    CHECK(luaL_dostring(L, "s = mico.json_encode({out = 'ab\\xff\\xfe'}); assert(#s > 0)") == 0);
}

static void test_tailer() {
    char tmpl[] = "/tmp/mico_tail_XXXXXX";
    int fd = mkstemp(tmpl);
    CHECK(fd >= 0);
    close(fd);
    std::string path = tmpl;
    std::vector<std::string> got;
    auto emit = [&](const std::string& l) { got.push_back(l); };

    { std::ofstream(path) << "old line\n"; }
    mico::Tailer t(path, false);
    t.poll(emit);  // starts at end: skips history
    CHECK(got.empty());

    { std::ofstream(path, std::ios::app) << "one\ntw"; }
    t.poll(emit);
    CHECK(got.size() == 1 && got[0] == "one");
    { std::ofstream(path, std::ios::app) << "o\n"; }
    t.poll(emit);
    CHECK(got.size() == 2 && got[1] == "two");

    { std::ofstream(path, std::ios::trunc) << "after truncate\n"; }
    t.poll(emit);
    CHECK(got.size() == 3 && got[2] == "after truncate");

    unlink(path.c_str());
    { std::ofstream(path) << "new file\n"; }  // replaced
    t.poll(emit);
    t.poll(emit);
    CHECK(got.size() == 4 && got.back() == "new file");
    unlink(path.c_str());
}

static void test_fuzzy() {
    mico::FuzzyIndex ix;
    struct S { const char *t, *a, *al; } songs[] = {
        {"晴天", "周杰伦", "叶惠美"},         {"七里香", "周杰伦", "七里香"},
        {"稻香", "周杰伦", "魔杰座"},         {"十年", "陈奕迅", "黑白灰"},
        {"爱情转移", "陈奕迅", "认了吧"},     {"海阔天空", "Beyond", "乐与怒"},
        {"天空之城", "久石让", ""},           {"Iselin", "Iselin Solheim", ""},
        {"青花瓷", "周杰伦", "我很忙"},       {"蓝莲花", "许巍/张三", "时光漫步"},
        {"南山南", "马頔", "孤岛"},           {"晴天 (Live)", "周杰伦", "无与伦比演唱会"},
    };
    for (const auto& s : songs) ix.add(s.t, s.a, s.al, mico::json{{"title", s.t}});
    auto top = [&](const char* q) -> std::string {
        auto hits = ix.search(q, 3);
        return hits.empty() ? "" : ix.payload(hits[0].index)["title"].get<std::string>();
    };
    CHECK(top("晴天") == "晴天");
    CHECK(top("周杰轮的七里香") == "七里香");  // homophone in artist
    CHECK(top("青花词") == "青花瓷");          // homophone in title
    CHECK(top("兰莲花") == "蓝莲花");          // fuzzy pinyin l/n
    CHECK(top("南三南") == "南山南");          // fuzzy pinyin s/sh
    CHECK(top("陈亦迅的十年") == "十年");
    CHECK(top("ISELIN") == "Iselin");
    CHECK(top("张三") == "蓝莲花");            // second artist of "许巍/张三"
    CHECK(top("完全无关的句子") == "");

    // Artist-only query: every hit is by the artist; no single-character noise.
    auto hits = ix.search("陈奕迅", 10);
    CHECK(hits.size() == 2);
    for (const auto& h : hits) CHECK(h.artist > 0.9 && h.title < 0.1);

    CHECK(mico::to_pinyin("周杰伦 Live") == "zhou jie lun live");
}

static void test_exec_and_hash() {
    mico::ExecResult r = mico::exec_command("echo out; echo err 1>&2; exit 3", 2000, 1024);
    CHECK(r.code == 3 && !r.timed_out);
    CHECK(r.output.find("out") != std::string::npos && r.output.find("err") != std::string::npos);

    r = mico::exec_command("echo start; sleep 5", 200, 1024);
    CHECK(r.timed_out && r.output == "start\n");

    r = mico::exec_command("yes | head -c 10000", 2000, 100);
    CHECK(r.output.size() == 100 && r.truncated);

    CHECK(mico::md5_hex("abc") == "900150983cd24fb0d6963f7d28e17f72");
    CHECK(mico::sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

static void test_runtime_extras() {
    mico::Runtime rt;
    lua_State* L = rt.L();
    CHECK(luaL_dostring(L, "config = {web = {listen = '1.2.3.4:9'}, poll_ms = 7, flag = true}") == 0);
    CHECK(rt.config_string("web.listen", "") == "1.2.3.4:9");
    CHECK(rt.config_string("web.missing", "d") == "d");
    CHECK(rt.config_string("nope.deeper", "d") == "d");
    CHECK(rt.config_number("poll_ms", 0) == 7);
    CHECK(rt.config_number("flag", 0) == 1);
    CHECK(luaL_dostring(L, "local t = mico.listdir('/'); assert(#t > 0); assert(mico.listdir('/nonexistent') == nil)") == 0);
    CHECK(luaL_dostring(L, "assert(mico.json_encode({a=1}, true):find('\\n'))") == 0);
    CHECK(luaL_dostring(L, "assert(mico.json_encode(setmetatable({}, {__jsontype='array'})) == '[]')") == 0);
    CHECK(luaL_dostring(L, "assert(mico.json_encode({}) == '{}')") == 0);
    CHECK(luaL_dostring(L, "local v = mico.version(); assert(v.app and v.git and v.build_time and v.curl and v.compiler);"
                           "assert(v.lua:find('^Lua 5'))") == 0);
    CHECK(luaL_dostring(L, "local a = mico.now_ms(); mico.sleep(20); assert(mico.now_ms() - a >= 15)") == 0);
    CHECK(luaL_dostring(L, "assert(mico.web_port() == nil and mico.config_path() == nil)") == 0);

    // on_http routing through the Lua hook.
    CHECK(luaL_dostring(L, "function on_http(m, p, q, h, b) return {status = 201, headers = {['X-A'] = h['x-in']},"
                           " body = m .. p .. q .. b} end") == 0);
    mico::WebRequest req;
    req.method = "POST";
    req.path = "/p";
    req.query = "a=1";
    req.headers["x-in"] = "v";
    req.body = "B";
    mico::WebResponse resp = rt.handle_http(req);
    CHECK(resp.status == 201 && resp.body == "POST/pa=1B");
    CHECK(resp.headers.size() == 1 && resp.headers[0].second == "v");
    CHECK(luaL_dostring(L, "function on_http() return {proxy = {url = 'http://u', headers = {R = 'x'}, buffer_kb = 64}} end") == 0);
    resp = rt.handle_http(req);
    CHECK(resp.proxy && resp.proxy_url == "http://u" && resp.proxy_headers["R"] == "x" && resp.proxy_buffer == 65536);
    CHECK(luaL_dostring(L, "function on_http() error('boom') end") == 0);
    CHECK(rt.handle_http(req).status == 500);
}

int main() {
    test_runtime_extras();
    test_parse_recognition();
    test_ring_buffer();
    test_json_roundtrip();
    test_tailer();
    test_fuzzy();
    test_exec_and_hash();
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("unit tests: ok\n");
    return 0;
}
