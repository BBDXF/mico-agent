#include "runtime.h"

#include <dirent.h>
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <ctime>

#include "http.h"
#include "saver.h"
#include "logger.h"

#include <curl/curl.h>

#ifndef MICO_VERSION
#define MICO_VERSION "dev"
#endif
#ifndef MICO_GIT
#define MICO_GIT "unknown"
#endif
#ifndef MICO_BUILD_TIME
#define MICO_BUILD_TIME __DATE__ " " __TIME__
#endif

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

namespace mico {

// ---------------------------------------------------------------- JSON <-> Lua

json lua_to_json(lua_State* L, int idx, int depth) {
    if (depth > 32) return nullptr;
    if (idx < 0) idx = lua_gettop(L) + idx + 1;
    switch (lua_type(L, idx)) {
    case LUA_TBOOLEAN:
        return lua_toboolean(L, idx) != 0;
    case LUA_TNUMBER: {
        double d = lua_tonumber(L, idx);
        if (std::floor(d) == d && std::fabs(d) < 9e15) return static_cast<long long>(d);
        return d;
    }
    case LUA_TSTRING: {
        size_t n;
        const char* s = lua_tolstring(L, idx, &n);
        return std::string(s, n);
    }
    case LUA_TTABLE: {
        // Array if keys are exactly 1..n with n > 0; otherwise object.
        size_t n = lua_objlen(L, idx);
        size_t count = 0;
        bool only_string_or_int = true;
        lua_pushnil(L);
        while (lua_next(L, idx) != 0) {
            ++count;
            if (lua_type(L, -2) != LUA_TSTRING && lua_type(L, -2) != LUA_TNUMBER) only_string_or_int = false;
            lua_pop(L, 1);
        }
        if (n == 0 && count == 0 && lua_getmetatable(L, idx)) {
            lua_getfield(L, -1, "__jsontype");
            bool arr = lua_isstring(L, -1) && std::strcmp(lua_tostring(L, -1), "array") == 0;
            lua_pop(L, 2);
            if (arr) return json::array();
        }
        if (n > 0 && count == n) {
            json arr = json::array();
            for (size_t i = 1; i <= n; ++i) {
                lua_rawgeti(L, idx, static_cast<int>(i));
                arr.push_back(lua_to_json(L, -1, depth + 1));
                lua_pop(L, 1);
            }
            return arr;
        }
        json obj = json::object();
        if (!only_string_or_int) return obj;
        lua_pushnil(L);
        while (lua_next(L, idx) != 0) {
            std::string key;
            if (lua_type(L, -2) == LUA_TSTRING) {
                key = lua_tostring(L, -2);
            } else {
                lua_pushvalue(L, -2);  // tostring on a copy, keep the key intact for lua_next
                key = lua_tostring(L, -1);
                lua_pop(L, 1);
            }
            obj[key] = lua_to_json(L, -1, depth + 1);
            lua_pop(L, 1);
        }
        return obj;
    }
    default:
        return nullptr;
    }
}

void push_json(lua_State* L, const json& j, int null_idx) {
    switch (j.type()) {
    case json::value_t::null:
        if (null_idx) lua_pushvalue(L, null_idx);
        else lua_pushnil(L);
        break;
    case json::value_t::boolean:
        lua_pushboolean(L, j.get<bool>());
        break;
    case json::value_t::number_integer:
    case json::value_t::number_unsigned:
    case json::value_t::number_float:
        lua_pushnumber(L, j.get<double>());
        break;
    case json::value_t::string: {
        const std::string& s = j.get_ref<const std::string&>();
        lua_pushlstring(L, s.data(), s.size());
        break;
    }
    case json::value_t::array: {
        lua_createtable(L, static_cast<int>(j.size()), 0);
        int i = 1;
        for (const auto& v : j) {
            push_json(L, v, null_idx);
            lua_rawseti(L, -2, i++);
        }
        break;
    }
    case json::value_t::object: {
        lua_createtable(L, 0, static_cast<int>(j.size()));
        for (auto it = j.begin(); it != j.end(); ++it) {
            push_json(L, it.value(), null_idx);
            lua_setfield(L, -2, it.key().c_str());
        }
        break;
    }
    default:
        lua_pushnil(L);
    }
}

// ---------------------------------------------------------------- Lua bindings

static Runtime* rt(lua_State* L) {
    return static_cast<Runtime*>(lua_touserdata(L, lua_upvalueindex(1)));
}

static std::string opt_field(lua_State* L, int idx, const char* key, const std::string& def) {
    lua_getfield(L, idx, key);
    std::string v = lua_isstring(L, -1) ? lua_tostring(L, -1) : def;
    lua_pop(L, 1);
    return v;
}

static int l_log(lua_State* L) {
    int n = lua_gettop(L);
    std::string line;
    for (int i = 1; i <= n; ++i) {
        lua_getglobal(L, "tostring");
        lua_pushvalue(L, i);
        lua_call(L, 1, 1);
        if (i > 1) line += ' ';
        const char* s = lua_tostring(L, -1);
        line += s ? s : "";
        lua_pop(L, 1);
    }
    log_line(line);
    return 0;
}

// mico.log_config{file, max_kb, keep, stderr}
static int l_log_config(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    LogConfig c = log_config();
    c.file = opt_field(L, 1, "file", c.file);
    lua_getfield(L, 1, "max_kb");
    if (lua_isnumber(L, -1)) c.max_bytes = static_cast<long long>(lua_tonumber(L, -1) * 1024);
    lua_pop(L, 1);
    lua_getfield(L, 1, "keep");
    if (lua_isnumber(L, -1)) c.keep = static_cast<int>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "stderr");
    if (lua_isboolean(L, -1)) c.echo_stderr = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    log_configure(c);
    return 0;
}

// mico.log_tail(n) -> {file, size, lines}
static int l_log_tail(lua_State* L) {
    size_t n = static_cast<size_t>(luaL_optnumber(L, 1, 200));
    std::vector<std::string> lines = log_tail(n);
    lua_createtable(L, 0, 3);
    lua_pushstring(L, log_config().file.c_str());
    lua_setfield(L, -2, "file");
    lua_pushnumber(L, static_cast<double>(log_size()));
    lua_setfield(L, -2, "size");
    lua_createtable(L, static_cast<int>(lines.size()), 0);
    for (size_t i = 0; i < lines.size(); ++i) {
        lua_pushlstring(L, lines[i].data(), lines[i].size());
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "lines");
    return 1;
}

static int l_json_encode(lua_State* L) {
    luaL_checkany(L, 1);
    std::string s = lua_to_json(L, 1).dump(lua_toboolean(L, 2) ? 2 : -1, ' ', false, json::error_handler_t::replace);
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

static int l_json_decode(lua_State* L) {
    size_t n;
    const char* s = luaL_checklstring(L, 1, &n);
    json j = json::parse(s, s + n, nullptr, false);
    if (j.is_discarded()) {
        lua_pushnil(L);
        lua_pushstring(L, "invalid json");
        return 2;
    }
    // Optional 2nd arg: value pushed for JSON null (default nil).
    push_json(L, j, lua_isnoneornil(L, 2) ? 0 : 2);
    return 1;
}

// mico.http{method=, url=, headers={}, body=, timeout_ms=} -> {status, body, error}
static int l_http(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    HttpRequest req;
    req.method = opt_field(L, 1, "method", "GET");
    req.url = opt_field(L, 1, "url", "");
    req.body = opt_field(L, 1, "body", "");
    lua_getfield(L, 1, "timeout_ms");
    if (lua_isnumber(L, -1)) req.timeout_ms = static_cast<long>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "headers");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) {
                req.headers[lua_tostring(L, -2)] = lua_tostring(L, -1);
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
    if (req.url.empty()) return luaL_error(L, "mico.http: url required");
    HttpResponse resp = http_do(req);
    lua_createtable(L, 0, 3);
    lua_pushnumber(L, static_cast<lua_Number>(resp.status));
    lua_setfield(L, -2, "status");
    lua_pushlstring(L, resp.body.data(), resp.body.size());
    lua_setfield(L, -2, "body");
    if (!resp.error.empty()) {
        lua_pushstring(L, resp.error.c_str());
        lua_setfield(L, -2, "error");
    }
    return 1;
}

// mico.exec(cmd [, {timeout_ms=10000, max_bytes=65536}]) -> output, code, timed_out
static int l_exec(lua_State* L) {
    std::string cmd = luaL_checkstring(L, 1);
    long timeout_ms = 10000;
    size_t max_bytes = 65536;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "timeout_ms");
        if (lua_isnumber(L, -1)) timeout_ms = static_cast<long>(lua_tonumber(L, -1));
        lua_pop(L, 1);
        lua_getfield(L, 2, "max_bytes");
        if (lua_isnumber(L, -1)) max_bytes = static_cast<size_t>(lua_tonumber(L, -1));
        lua_pop(L, 1);
    }
    ExecResult r = exec_command(cmd, timeout_ms, max_bytes);
    lua_pushlstring(L, r.output.data(), r.output.size());
    lua_pushnumber(L, r.code);
    lua_pushboolean(L, r.timed_out);
    return 3;
}

static int l_md5(lua_State* L) {
    size_t n;
    const char* s = luaL_checklstring(L, 1, &n);
    lua_pushstring(L, md5_hex(std::string(s, n)).c_str());
    return 1;
}

static int l_sha256(lua_State* L) {
    size_t n;
    const char* s = luaL_checklstring(L, 1, &n);
    lua_pushstring(L, sha256_hex(std::string(s, n)).c_str());
    return 1;
}

static int l_pinyin(lua_State* L) {
    lua_pushstring(L, to_pinyin(luaL_checkstring(L, 1)).c_str());
    return 1;
}

// mico.index_clear(name)
static int l_index_clear(lua_State* L) {
    rt(L)->indexes[luaL_checkstring(L, 1)].clear();
    return 0;
}

// mico.index_add(name, items): items = { {title=, artist=, album=, ...}, ... }.
// The whole item table is kept and returned by index_search.
static int l_index_add(lua_State* L) {
    FuzzyIndex& ix = rt(L)->indexes[luaL_checkstring(L, 1)];
    luaL_checktype(L, 2, LUA_TTABLE);
    size_t n = lua_objlen(L, 2);
    for (size_t i = 1; i <= n; ++i) {
        lua_rawgeti(L, 2, static_cast<int>(i));
        if (lua_istable(L, -1)) {
            int t = lua_gettop(L);
            ix.add(opt_field(L, t, "title", ""), opt_field(L, t, "artist", ""), opt_field(L, t, "album", ""),
                   lua_to_json(L, t));
        }
        lua_pop(L, 1);
    }
    lua_pushnumber(L, static_cast<lua_Number>(ix.size()));
    return 1;
}

static int l_index_size(lua_State* L) {
    Runtime* r = rt(L);
    auto it = r->indexes.find(luaL_checkstring(L, 1));
    lua_pushnumber(L, it == r->indexes.end() ? 0 : static_cast<lua_Number>(it->second.size()));
    return 1;
}

// mico.index_search(name, query [, {limit=10, min_score=0.3}])
//   -> { {score=, title_score=, artist_score=, album_score=, query_score=, item={...}}, ... }
static int l_index_search(lua_State* L) {
    Runtime* r = rt(L);
    std::string name = luaL_checkstring(L, 1);
    std::string query = luaL_checkstring(L, 2);
    size_t limit = 10;
    double min_score = 0.3;
    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "limit");
        if (lua_isnumber(L, -1)) limit = static_cast<size_t>(lua_tonumber(L, -1));
        lua_pop(L, 1);
        lua_getfield(L, 3, "min_score");
        if (lua_isnumber(L, -1)) min_score = lua_tonumber(L, -1);
        lua_pop(L, 1);
    }
    lua_newtable(L);
    auto it = r->indexes.find(name);
    if (it == r->indexes.end()) return 1;
    int i = 1;
    for (const FuzzyHit& h : it->second.search(query, limit, min_score)) {
        lua_createtable(L, 0, 6);
        lua_pushnumber(L, h.score);
        lua_setfield(L, -2, "score");
        lua_pushnumber(L, h.title);
        lua_setfield(L, -2, "title_score");
        lua_pushnumber(L, h.artist);
        lua_setfield(L, -2, "artist_score");
        lua_pushnumber(L, h.album);
        lua_setfield(L, -2, "album_score");
        lua_pushnumber(L, h.query);
        lua_setfield(L, -2, "query_score");
        push_json(L, it->second.payload(h.index));
        lua_setfield(L, -2, "item");
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

static int l_sleep(lua_State* L) {
    usleep(static_cast<useconds_t>(luaL_checknumber(L, 1) * 1000));
    return 0;
}

// mico.tool{name=, description=, parameters={...}, handler=function(args) ... end}
static int l_tool(lua_State* L) {
    Runtime* r = rt(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    Tool t;
    t.name = opt_field(L, 1, "name", "");
    t.description = opt_field(L, 1, "description", "");
    if (t.name.empty()) return luaL_error(L, "mico.tool: name required");
    lua_getfield(L, 1, "parameters");
    t.parameters = lua_istable(L, -1) ? lua_to_json(L, -1) : json::object();
    lua_pop(L, 1);
    if (!t.parameters.is_object()) t.parameters = json::object();
    if (!t.parameters.contains("type")) t.parameters["type"] = "object";
    if (!t.parameters.contains("properties")) t.parameters["properties"] = json::object();
    lua_getfield(L, 1, "handler");
    if (!lua_isfunction(L, -1)) return luaL_error(L, "mico.tool: handler function required");
    t.handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    auto old = r->tools.find(t.name);
    if (old != r->tools.end()) luaL_unref(L, LUA_REGISTRYINDEX, old->second.handler_ref);
    r->tools[t.name] = t;
    return 0;
}

// mico.configure{llm={base_url, api_key, model, timeout_ms, extra={}}, system_prompt, max_steps, max_history}
static int l_configure(lua_State* L) {
    Runtime* r = rt(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "llm");
    if (lua_istable(L, -1)) {
        int t = lua_gettop(L);
        r->llm.base_url = opt_field(L, t, "base_url", r->llm.base_url);
        r->llm.api_key = opt_field(L, t, "api_key", r->llm.api_key);
        r->llm.model = opt_field(L, t, "model", r->llm.model);
        lua_getfield(L, t, "timeout_ms");
        if (lua_isnumber(L, -1)) r->llm.timeout_ms = static_cast<long>(lua_tonumber(L, -1));
        lua_pop(L, 1);
        lua_getfield(L, t, "extra");
        if (lua_istable(L, -1)) r->llm.extra = lua_to_json(L, -1);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    r->system_prompt = opt_field(L, 1, "system_prompt", r->system_prompt);
    lua_getfield(L, 1, "max_steps");
    if (lua_isnumber(L, -1)) r->max_steps = static_cast<int>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "max_history");
    if (lua_isnumber(L, -1)) r->max_history = static_cast<int>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    return 0;
}

// mico.ask(text) -> reply | nil, err
static int l_ask(lua_State* L) {
    Runtime* r = rt(L);
    std::string text = luaL_checkstring(L, 1);
    std::string reply, err;
    if (!r->ask(text, reply, err)) {
        lua_pushnil(L);
        lua_pushstring(L, err.c_str());
        return 2;
    }
    lua_pushlstring(L, reply.data(), reply.size());
    return 1;
}

// mico.complete{messages={...}, max_tokens=?, timeout_ms=?} -> text | nil, err
// One-shot LLM call with the configured llm (incl. extra); no tools, not recorded in history.
static int l_complete(lua_State* L) {
    Runtime* r = rt(L);
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "messages");
    json messages = lua_istable(L, -1) ? lua_to_json(L, -1) : json();
    lua_pop(L, 1);
    if (!messages.is_array() || messages.empty()) return luaL_error(L, "mico.complete: messages required");
    LlmConfig cfg = r->llm;
    lua_getfield(L, 1, "timeout_ms");
    if (lua_isnumber(L, -1)) cfg.timeout_ms = static_cast<long>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "max_tokens");
    if (lua_isnumber(L, -1)) {
        if (!cfg.extra.is_object()) cfg.extra = json::object();
        cfg.extra["max_tokens"] = static_cast<long>(lua_tonumber(L, -1));
    }
    lua_pop(L, 1);
    LlmResult res = llm_chat(cfg, messages, json::array());
    if (!res.ok) {
        lua_pushnil(L);
        lua_pushstring(L, res.error.c_str());
        return 2;
    }
    const json& c = res.message.contains("content") ? res.message["content"] : json();
    std::string text = c.is_string() ? c.get<std::string>() : "";
    lua_pushlstring(L, text.data(), text.size());
    return 1;
}

static int l_config_path(lua_State* L) {
    const std::string& p = rt(L)->config_path;
    if (p.empty()) return 0;
    lua_pushstring(L, p.c_str());
    return 1;
}

static int l_script_dir(lua_State* L) {
    lua_pushstring(L, rt(L)->script_dir.c_str());
    return 1;
}

static int l_web_port(lua_State* L) {
    if (!rt(L)->web_port) return 0;
    lua_pushnumber(L, rt(L)->web_port);
    return 1;
}

// mico.listdir(dir) -> sorted array of names (no . / ..) | nil, err
static int l_listdir(lua_State* L) {
    const char* dir = luaL_checkstring(L, 1);
    DIR* d = opendir(dir);
    if (!d) {
        lua_pushnil(L);
        lua_pushstring(L, "cannot open directory");
        return 2;
    }
    std::vector<std::string> names;
    while (struct dirent* e = readdir(d)) {
        if (std::strcmp(e->d_name, ".") && std::strcmp(e->d_name, "..")) names.push_back(e->d_name);
    }
    closedir(d);
    std::sort(names.begin(), names.end());
    lua_createtable(L, static_cast<int>(names.size()), 0);
    for (size_t i = 0; i < names.size(); ++i) {
        lua_pushstring(L, names[i].c_str());
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 1;
}

static int l_tool_remove(lua_State* L) {
    Runtime* r = rt(L);
    auto it = r->tools.find(luaL_checkstring(L, 1));
    if (it != r->tools.end()) {
        luaL_unref(L, LUA_REGISTRYINDEX, it->second.handler_ref);
        r->tools.erase(it);
    }
    return 0;
}

static long long now_ms();

// mico.now_ms() -> monotonic milliseconds (for step timing)
static int l_now_ms(lua_State* L) {
    lua_pushnumber(L, static_cast<double>(now_ms()));
    return 1;
}

// mico.version() -> {app, git, build_time, lua, curl, compiler}
static int l_version(lua_State* L) {
    lua_createtable(L, 0, 6);
    lua_pushstring(L, MICO_VERSION);
    lua_setfield(L, -2, "app");
    lua_pushstring(L, MICO_GIT);
    lua_setfield(L, -2, "git");
    lua_pushstring(L, MICO_BUILD_TIME);
    lua_setfield(L, -2, "build_time");
    lua_pushstring(L, LUA_RELEASE);
    lua_setfield(L, -2, "lua");
    const curl_version_info_data* cv = curl_version_info(CURLVERSION_NOW);
    lua_pushstring(L, cv && cv->version ? cv->version : "unknown");
    lua_setfield(L, -2, "curl");
#if defined(__clang__)
    lua_pushstring(L, "clang " __clang_version__);
#elif defined(__GNUC__)
    lua_pushstring(L, "gcc " __VERSION__);
#else
    lua_pushstring(L, "unknown");
#endif
    lua_setfield(L, -2, "compiler");
    return 1;
}

// mico.save_start{src_url, src_headers={}, dav_base, name, username, password,
//                 max_bytes, buffer_kb, status_path} -> pid | nil, err
static int l_save_start(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    SaveJob j;
    j.src_url = opt_field(L, 1, "src_url", "");
    j.dav_base = opt_field(L, 1, "dav_base", "");
    j.name = opt_field(L, 1, "name", "");
    j.user = opt_field(L, 1, "username", "");
    j.pass = opt_field(L, 1, "password", "");
    j.status_path = opt_field(L, 1, "status_path", "");
    lua_getfield(L, 1, "max_bytes");
    if (lua_isnumber(L, -1)) j.max_bytes = static_cast<long long>(lua_tonumber(L, -1));
    lua_pop(L, 1);
    lua_getfield(L, 1, "buffer_kb");
    if (lua_isnumber(L, -1)) j.buffer_bytes = static_cast<size_t>(lua_tonumber(L, -1)) * 1024;
    lua_pop(L, 1);
    lua_getfield(L, 1, "src_headers");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) j.src_headers[lua_tostring(L, -2)] = lua_tostring(L, -1);
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
    if (j.src_url.empty() || j.dav_base.empty() || j.name.empty()) return luaL_error(L, "mico.save_start: src_url, dav_base, name required");
    pid_t pid = save_spawn(j);
    if (pid < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "fork failed");
        return 2;
    }
    lua_pushnumber(L, pid);
    return 1;
}

// mico.proc_reap(pid) -> true when the child has exited (non-blocking)
static int l_proc_reap(lua_State* L) {
    pid_t pid = static_cast<pid_t>(luaL_checknumber(L, 1));
    int st;
    pid_t w = waitpid(pid, &st, WNOHANG);
    lua_pushboolean(L, w == pid || (w < 0 && errno == ECHILD));
    return 1;
}

// mico.dav_test{url, username, password} -> {ok, status, error?}
static int l_dav_test(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    DavTestResult r = dav_test(opt_field(L, 1, "url", ""), opt_field(L, 1, "username", ""), opt_field(L, 1, "password", ""));
    lua_createtable(L, 0, 3);
    lua_pushboolean(L, r.ok);
    lua_setfield(L, -2, "ok");
    lua_pushnumber(L, static_cast<double>(r.status));
    lua_setfield(L, -2, "status");
    if (!r.error.empty()) {
        lua_pushstring(L, r.error.c_str());
        lua_setfield(L, -2, "error");
    }
    return 1;
}

static int l_reset(lua_State* L) {
    rt(L)->reset();
    return 0;
}

// ---------------------------------------------------------------- Runtime

Runtime::Runtime() : L_(luaL_newstate()) {
    luaL_openlibs(L_);
    static const luaL_Reg fns[] = {
        {"log", l_log},       {"json_encode", l_json_encode}, {"json_decode", l_json_decode},
        {"http", l_http},     {"exec", l_exec},               {"sleep", l_sleep},
        {"tool", l_tool},     {"configure", l_configure},     {"ask", l_ask}, {"complete", l_complete},
        {"reset", l_reset},   {"md5", l_md5},                 {"sha256", l_sha256},
        {"pinyin", l_pinyin}, {"index_clear", l_index_clear}, {"index_add", l_index_add},
        {"index_size", l_index_size}, {"index_search", l_index_search},
        {"config_path", l_config_path}, {"script_dir", l_script_dir}, {"web_port", l_web_port},
        {"listdir", l_listdir}, {"tool_remove", l_tool_remove}, {"version", l_version}, {"now_ms", l_now_ms},
        {"save_start", l_save_start}, {"log_config", l_log_config}, {"log_tail", l_log_tail}, {"proc_reap", l_proc_reap}, {"dav_test", l_dav_test},
        {nullptr, nullptr},
    };
    lua_newtable(L_);
    for (const luaL_Reg* f = fns; f->name; ++f) {
        lua_pushlightuserdata(L_, this);
        lua_pushcclosure(L_, f->func, 1);
        lua_setfield(L_, -2, f->name);
    }
    lua_setglobal(L_, "mico");
}

Runtime::~Runtime() { lua_close(L_); }

bool Runtime::load_script(const std::string& path, std::string& err) {
    // Let scripts `require` siblings: prepend <script dir>/?.lua to package.path.
    std::string dir = ".";
    size_t slash = path.find_last_of('/');
    if (slash != std::string::npos) dir = path.substr(0, slash);
    script_dir = dir;
    lua_getglobal(L_, "package");
    lua_getfield(L_, -1, "path");
    std::string p = dir + "/?.lua;" + dir + "/lib/?.lua;" + lua_tostring(L_, -1);
    lua_pop(L_, 1);
    lua_pushstring(L_, p.c_str());
    lua_setfield(L_, -2, "path");
    lua_pop(L_, 1);

    if (luaL_loadfile(L_, path.c_str()) != 0 || lua_pcall(L_, 0, 0, 0) != 0) {
        err = lua_tostring(L_, -1);
        lua_pop(L_, 1);
        return false;
    }
    return true;
}

bool Runtime::call_hook(const std::string& name, const std::vector<std::string>& args, std::string& err) {
    lua_getglobal(L_, name.c_str());
    if (!lua_isfunction(L_, -1)) {
        lua_pop(L_, 1);
        err = "no global function " + name;
        return false;
    }
    for (const auto& a : args) lua_pushlstring(L_, a.data(), a.size());
    if (lua_pcall(L_, static_cast<int>(args.size()), 0, 0) != 0) {
        err = lua_tostring(L_, -1);
        lua_pop(L_, 1);
        return false;
    }
    return true;
}

bool Runtime::push_config(const std::string& key) {
    lua_getglobal(L_, "config");
    size_t start = 0;
    for (;;) {
        if (!lua_istable(L_, -1)) {
            lua_pop(L_, 1);
            return false;
        }
        size_t dot = key.find('.', start);
        std::string part = key.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        lua_getfield(L_, -1, part.c_str());
        lua_remove(L_, -2);
        if (dot == std::string::npos) return true;
        start = dot + 1;
    }
}

std::string Runtime::config_string(const std::string& key, const std::string& def) {
    if (!push_config(key)) return def;
    std::string v = lua_isstring(L_, -1) ? lua_tostring(L_, -1) : def;
    lua_pop(L_, 1);
    return v;
}

double Runtime::config_number(const std::string& key, double def) {
    if (!push_config(key)) return def;
    double v = lua_isnumber(L_, -1) ? lua_tonumber(L_, -1) : (lua_isboolean(L_, -1) ? lua_toboolean(L_, -1) : def);
    lua_pop(L_, 1);
    return v;
}

static void read_string_map(lua_State* L, int idx, std::map<std::string, std::string>& out) {
    if (!lua_istable(L, idx)) return;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) out[lua_tostring(L, -2)] = lua_tostring(L, -1);
        lua_pop(L, 1);
    }
}

WebResponse Runtime::handle_http(const WebRequest& req) {
    WebResponse resp;
    int top = lua_gettop(L_);
    lua_getglobal(L_, "on_http");
    if (!lua_isfunction(L_, -1)) {
        lua_settop(L_, top);
        resp.status = 404;
        resp.body = "not found";
        return resp;
    }
    lua_pushstring(L_, req.method.c_str());
    lua_pushstring(L_, req.path.c_str());
    lua_pushstring(L_, req.query.c_str());
    lua_createtable(L_, 0, static_cast<int>(req.headers.size()));
    for (const auto& kv : req.headers) {
        lua_pushstring(L_, kv.second.c_str());
        lua_setfield(L_, -2, kv.first.c_str());
    }
    lua_pushlstring(L_, req.body.data(), req.body.size());
    if (lua_pcall(L_, 5, 1, 0) != 0) {
        resp.status = 500;
        resp.body = lua_tostring(L_, -1) ? lua_tostring(L_, -1) : "lua error";
        logf("on_http: %s", resp.body.c_str());
        lua_settop(L_, top);
        return resp;
    }
    int t = lua_gettop(L_);
    if (lua_istable(L_, t)) {
        lua_getfield(L_, t, "status");
        if (lua_isnumber(L_, -1)) resp.status = static_cast<int>(lua_tonumber(L_, -1));
        lua_pop(L_, 1);
        resp.body = opt_field(L_, t, "body", "");
        lua_getfield(L_, t, "headers");
        std::map<std::string, std::string> h;
        read_string_map(L_, lua_gettop(L_), h);
        lua_pop(L_, 1);
        for (const auto& kv : h) resp.headers.push_back(kv);
        lua_getfield(L_, t, "proxy");
        if (lua_istable(L_, -1)) {
            int p = lua_gettop(L_);
            resp.proxy = true;
            resp.proxy_url = opt_field(L_, p, "url", "");
            lua_getfield(L_, p, "buffer_kb");
            if (lua_isnumber(L_, -1)) resp.proxy_buffer = static_cast<size_t>(lua_tonumber(L_, -1)) * 1024;
            lua_pop(L_, 1);
            lua_getfield(L_, p, "headers");
            read_string_map(L_, lua_gettop(L_), resp.proxy_headers);
            lua_pop(L_, 1);
            if (resp.proxy_url.empty()) {
                resp.proxy = false;
                resp.status = 502;
            }
        }
        lua_pop(L_, 1);
    } else {
        resp.status = 500;
        resp.body = "on_http returned no table";
    }
    lua_settop(L_, top);
    return resp;
}

json Runtime::tools_json() const {
    json arr = json::array();
    for (const auto& kv : tools) {
        arr.push_back({{"type", "function"},
                       {"function",
                        {{"name", kv.second.name},
                         {"description", kv.second.description},
                         {"parameters", kv.second.parameters}}}});
    }
    return arr;
}

std::string Runtime::run_tool(const std::string& name, const std::string& args_json) {
    auto it = tools.find(name);
    if (it == tools.end()) return "error: unknown tool " + name;
    json args = json::parse(args_json.empty() ? "{}" : args_json, nullptr, false);
    if (args.is_discarded()) return "error: arguments are not valid JSON";
    lua_rawgeti(L_, LUA_REGISTRYINDEX, it->second.handler_ref);
    push_json(L_, args.is_object() ? args : json::object());
    if (lua_pcall(L_, 1, 1, 0) != 0) {
        std::string e = std::string("error: ") + lua_tostring(L_, -1);
        lua_pop(L_, 1);
        return e;
    }
    std::string out;
    if (lua_type(L_, -1) == LUA_TSTRING) {
        out = lua_tostring(L_, -1);
    } else if (lua_isnil(L_, -1)) {
        out = "ok";
    } else {
        out = lua_to_json(L_, -1).dump(-1, ' ', false, json::error_handler_t::replace);
    }
    lua_pop(L_, 1);
    return out;
}

void Runtime::trim_history() {
    if (max_history <= 0 || static_cast<int>(history_.size()) <= max_history) return;
    size_t start = history_.size() - static_cast<size_t>(max_history);
    // Never start on an orphan tool/assistant message: advance to a user message.
    while (start < history_.size() && history_[start].value("role", "") != "user") ++start;
    history_.erase(history_.begin(), history_.begin() + static_cast<long>(start));
}

bool Runtime::ask(const std::string& text, std::string& reply, std::string& err) {
    // Exceptions must not unwind through Lua's C frames.
    try {
        return ask_impl(text, reply, err);
    } catch (const std::exception& e) {
        err = std::string("internal error: ") + e.what();
        return false;
    }
}

static long long now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// Reports one agent step to the optional Lua hook on_step({kind, name, ms, args?, result?, error?}).
void Runtime::emit_step(const char* kind, const std::string& name, long long ms, const std::string* args,
                        const std::string* result, const std::string* error) {
    int top = lua_gettop(L_);
    lua_getglobal(L_, "on_step");
    if (!lua_isfunction(L_, -1)) {
        lua_settop(L_, top);
        return;
    }
    lua_createtable(L_, 0, 6);
    lua_pushstring(L_, kind);
    lua_setfield(L_, -2, "kind");
    lua_pushlstring(L_, name.data(), name.size());
    lua_setfield(L_, -2, "name");
    lua_pushnumber(L_, static_cast<double>(ms));
    lua_setfield(L_, -2, "ms");
    if (args) {
        lua_pushlstring(L_, args->data(), args->size());
        lua_setfield(L_, -2, "args");
    }
    if (result) {
        lua_pushlstring(L_, result->data(), result->size());
        lua_setfield(L_, -2, "result");
    }
    if (error) {
        lua_pushlstring(L_, error->data(), error->size());
        lua_setfield(L_, -2, "error");
    }
    if (lua_pcall(L_, 1, 0, 0) != 0) logf("on_step: %s", lua_tostring(L_, -1));
    lua_settop(L_, top);
}

bool Runtime::ask_impl(const std::string& text, std::string& reply, std::string& err) {
    history_.push_back({{"role", "user"}, {"content", text}});
    json tools_arr = tools_json();
    for (int step = 0; step < max_steps; ++step) {
        json messages = json::array();
        if (!system_prompt.empty()) messages.push_back({{"role", "system"}, {"content", system_prompt}});
        for (const auto& m : history_) messages.push_back(m);

        long long t0 = now_ms();
        LlmResult res = llm_chat(llm, messages, tools_arr);
        long long llm_ms = now_ms() - t0;
        if (!res.ok) {
            emit_step("llm", llm.model, llm_ms, nullptr, nullptr, &res.error);
            err = res.error;
            history_.pop_back();  // drop the unanswered user turn
            return false;
        }
        json msg = res.message;
        if (msg.contains("content") && msg["content"].is_null()) msg["content"] = "";
        history_.push_back(msg);

        const json& calls = msg.value("tool_calls", json::array());
        {
            std::string summary;
            if (calls.is_array() && !calls.empty()) {
                summary = "tool_calls:";
                for (const auto& c : calls) summary += " " + c.value("function", json::object()).value("name", "");
            } else {
                summary = msg.value("content", "");
            }
            emit_step("llm", llm.model, llm_ms, nullptr, &summary, nullptr);
        }
        if (!calls.is_array() || calls.empty()) {
            reply = msg.value("content", "");
            trim_history();
            return true;
        }
        for (const auto& c : calls) {
            const json& fn = c.value("function", json::object());
            std::string name = fn.value("name", "");
            std::string args = fn.value("arguments", "{}");
            logf("[tool] %s %s", name.c_str(), args.c_str());
            long long t1 = now_ms();
            std::string out = run_tool(name, args);
            long long tool_ms = now_ms() - t1;
            if (out.compare(0, 7, "error: ") == 0) {
                emit_step("tool", name, tool_ms, &args, nullptr, &out);
            } else {
                emit_step("tool", name, tool_ms, &args, &out, nullptr);
            }
            history_.push_back({{"role", "tool"}, {"tool_call_id", c.value("id", "")}, {"content", out}});
        }
    }
    err = "max_steps exceeded";
    trim_history();
    return false;
}

}  // namespace mico
