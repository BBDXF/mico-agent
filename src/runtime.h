#pragma once

#include <map>
#include <string>
#include <vector>

#include "fuzzy.h"
#include "httpd.h"
#include "llm.h"

struct lua_State;

namespace mico {

struct Tool {
    std::string name;
    std::string description;
    json parameters;    // JSON Schema object
    int handler_ref;    // Lua registry ref of the handler function
};

// Owns the Lua state and the agent loop. Lua scripts drive everything through
// the global `mico` module; C++ only provides primitives.
class Runtime {
public:
    Runtime();
    ~Runtime();

    // Loads and runs a Lua script. Returns false and fills err on failure.
    bool load_script(const std::string& path, std::string& err);

    // Calls global Lua function `name(args...)` with string args, if it exists.
    bool call_hook(const std::string& name, const std::vector<std::string>& args, std::string& err);

    // Calls Lua `on_http(method, path, query, headers, body)`; 404 if undefined.
    WebResponse handle_http(const WebRequest& req);

    // Reads global `config.<key>` as string/number (with defaults). Dotted keys
    // ("web.listen") descend into nested tables.
    std::string config_string(const std::string& key, const std::string& def);
    double config_number(const std::string& key, double def);

    // Runs one agent turn: user text in, final assistant text out.
    bool ask(const std::string& text, std::string& reply, std::string& err);
    void reset() { history_.clear(); }

    lua_State* L() { return L_; }

    LlmConfig llm;
    std::string system_prompt;
    int max_steps = 6;
    int max_history = 20;
    std::map<std::string, Tool> tools;
    std::map<std::string, FuzzyIndex> indexes;
    std::string config_path;  // from -c; exposed as mico.config_path()
    std::string script_dir = ".";
    int web_port = 0;         // exposed as mico.web_port() (nil when 0)

private:
    bool push_config(const std::string& key);  // pushes config value or returns false
    json tools_json() const;
    bool ask_impl(const std::string& text, std::string& reply, std::string& err);
    std::string run_tool(const std::string& name, const std::string& args_json);
    void emit_step(const char* kind, const std::string& name, long long ms, const std::string* args,
                   const std::string* result, const std::string* error);
    void trim_history();

    lua_State* L_;
    std::vector<json> history_;
};

// Lua <-> JSON conversion (exposed for tests).
json lua_to_json(lua_State* L, int idx, int depth = 0);
void push_json(lua_State* L, const json& j, int null_idx = 0);  // null_idx: absolute stack index of the value used for JSON null

struct ExecResult {
    std::string output;   // stdout+stderr, capped at max_bytes
    int code = -1;        // exit code; -1 if killed or failed to start
    bool timed_out = false;
    bool truncated = false;
};

// Runs `sh -c cmd` in its own process group; kills the group on timeout.
ExecResult exec_command(const std::string& cmd, long timeout_ms, size_t max_bytes);

std::string md5_hex(const std::string& data);
std::string sha256_hex(const std::string& data);

}  // namespace mico
