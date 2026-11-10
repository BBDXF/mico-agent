-- HTTP API + web UI, called from C++ via on_http (main thread only).
local config = require("config")
local plugins = require("plugins")

local M = {}
M.started = os.time()
M.conversations = {}  -- ring buffer of the last M.max_conversations turns
M.max_conversations = 100
M.MASK = "******"
M.ask = nil       -- function(text) -> reply, err   (set by main.lua)
M.status_extra = nil  -- function() -> table

local secrets = { { "llm", "api_key" }, { "web", "token" }, { "save", "password" } }

-- ---------------------------------------------------------------- turns
-- Turn: {id, time, source, user, route, reply, error?, duration_ms, status,
--        steps = {{kind, name, args?, result?, ms, error?}}}
M.next_id = 1
M.current = nil  -- in-progress turn (status = "running")
M.MAX_RESULT = 500

local function utf8_cut(s, n)
  s = tostring(s)
  if #s <= n then return s end
  while n > 0 and s:byte(n + 1) and s:byte(n + 1) >= 0x80 and s:byte(n + 1) < 0xC0 do n = n - 1 end
  return s:sub(1, n) .. "…"
end
M.truncate = utf8_cut

function M.begin_turn(source, user)
  local t = {
    id = M.next_id, time = os.date("%Y-%m-%d %H:%M:%S"), source = source, user = user,
    route = "llm", reply = "", steps = setmetatable({}, { __jsontype = "array" }), status = "running", started_ms = mico.now_ms(),
  }
  M.next_id = M.next_id + 1
  M.current = t
  return t
end

-- Appends a step to the running turn (no-op outside a turn).
function M.step(st)
  local t = M.current
  if not t then return end
  local s = { kind = st.kind or "info", name = st.name or "", ms = math.floor(tonumber(st.ms) or 0) }
  if st.args ~= nil then
    local a = st.args
    if type(a) == "string" then a = mico.json_decode(a) or a end
    s.args = a
  end
  if st.result ~= nil then
    local r = st.result
    if type(r) ~= "string" then r = mico.json_encode(r) end
    s.result = utf8_cut(r, M.MAX_RESULT)
  end
  if st.error ~= nil then s.error = utf8_cut(st.error, M.MAX_RESULT) end
  t.steps[#t.steps + 1] = s
end

function M.end_turn(fields)
  local t = M.current
  if not t then return end
  for k, v in pairs(fields or {}) do t[k] = v end
  t.duration_ms = math.floor(mico.now_ms() - t.started_ms)
  t.started_ms = nil
  t.status = "done"
  M.current = nil
  local c = M.conversations
  c[#c + 1] = t
  while #c > M.max_conversations do table.remove(c, 1) end
  return t
end

-- Legacy one-shot record (kept for scripts that call it directly).
function M.record(turn)
  M.begin_turn(turn.source or "web", turn.user or "")
  return M.end_turn(turn)
end

local function urldecode(s)
  s = tostring(s or ""):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
M.urldecode = urldecode

local function parse_query(q)
  local out = {}
  for pair in tostring(q or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    out[urldecode(k)] = urldecode(v)
  end
  return out
end

local function json(status, obj)
  return { status = status, headers = { ["Content-Type"] = "application/json; charset=utf-8" }, body = mico.json_encode(obj) }
end

local function err(status, msg) return json(status, { error = msg }) end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function mask(c)
  for _, path in ipairs(secrets) do
    local t = c[path[1]]
    if type(t) == "table" and t[path[2]] and t[path[2]] ~= "" then t[path[2]] = M.MASK end
  end
  return c
end

local function masked_config() return mask(config.file_view()) end

local function config_response()
  local schema = {}
  for i, f in ipairs(config.schema) do
    local d = {}
    for k, v in pairs(f) do d[k] = v end
    schema[i] = d
  end
  return {
    config = masked_config(),
    defaults = mask(config.copy(config.defaults)),
    effective = mask(config.copy(config.current)),
    env_overrides = setmetatable(config.env_overrides(), { __jsontype = "array" }),
    schema = schema,
    path = config.path,
  }
end

local function put_config(body)
  local patch = mico.json_decode(body or "", config.NULL)
  if type(patch) ~= "table" or patch == config.NULL then return err(400, "invalid json") end
  -- Masked sentinel means "unchanged".
  for _, path in ipairs(secrets) do
    local t = patch[path[1]]
    if type(t) == "table" and t[path[2]] == M.MASK then t[path[2]] = nil end
  end
  local verr, vkey = config.validate(patch)
  if verr then return json(400, { error = verr, key = vkey }) end
  local ok, e = config.save(patch)
  if not ok then return err(500, e) end
  local r = config_response()
  r.ok = true
  return json(200, r)
end

local function status()
  local tools = require("tools")
  local s = {
    uptime = os.time() - M.started,
    started = os.date("%Y-%m-%d %H:%M:%S", M.started),
    now_playing = tools.now_playing or false,
    index_size = mico.index_size("music"),
    index = require("indexer").info(),
    plugins = plugins.list(),
    conversations = #M.conversations,
    config_path = config.path,
    web_port = mico.web_port(),
    playback = config.get("playback"),
    version = mico.version(),
  }
  if M.status_extra then for k, v in pairs(M.status_extra()) do s[k] = v end end
  return json(200, s)
end

local function authorized(headers, q)
  local token = config.get("web.token") or ""
  if token == "" then return true end
  local auth = headers.authorization or ""
  return auth == "Bearer " .. token or q.token == token
end

-- /api/tools* routes (agent tools). Returns nil when the path doesn't match.
function M.tools_route(method, path, body)
  local agent_tools = require("agent_tools")
  local function fail(e, code) return err(code or 400, e) end
  if path == "/api/tool-template" and method == "GET" then return json(200, { source = agent_tools.TEMPLATE }) end
  if path == "/api/tools" then
    if method == "GET" then return json(200, agent_tools.list()) end
    if method == "POST" then
      local j = mico.json_decode(body or "")
      if type(j) ~= "table" then return fail("需要 {source} 或 {url}") end
      local source = j.source
      if type(source) ~= "string" and type(j.url) == "string" and j.url ~= "" then
        local r = mico.http({ url = j.url, timeout_ms = 15000 })
        if r.error then return fail("下载失败: " .. r.error) end
        if r.status ~= 200 then return fail("下载失败: HTTP " .. tostring(r.status)) end
        source = r.body
      end
      if type(source) ~= "string" then return fail("需要 {source} 或 {url}") end
      local name, e, code = agent_tools.save(source, { overwrite = j.overwrite == true })
      if not name then return fail(e, code) end
      return json(200, { ok = true, name = name, tools = agent_tools.list() })
    end
    return err(405, "method not allowed")
  end
  local name, action = path:match("^/api/tools/([%w_%-]+)/(%a+)$")
  if name then
    if not agent_tools.get(name) then return err(404, "no such tool") end
    if action == "source" then
      if method == "GET" then
        local src, e, code = agent_tools.source(name)
        if not src then return fail(e, code) end
        return json(200, { name = name, source = src })
      elseif method == "PUT" then
        local j = mico.json_decode(body or "")
        if type(j) ~= "table" or type(j.source) ~= "string" then return fail("需要 {source}") end
        local _, e, code = agent_tools.source(name)  -- builtin check
        if e then return fail(e, code) end
        local n, e2, code2 = agent_tools.save(j.source, { name = name, overwrite = true })
        if not n then return fail(e2, code2) end
        return json(200, { ok = true, name = n, tool = agent_tools.view(n) })
      end
      return err(405, "method not allowed")
    end
    if method ~= "POST" then return err(405, "method not allowed") end
    if action == "enable" or action == "disable" then
      local ok, e, code = agent_tools.set_enabled(name, action == "enable")
      if not ok then return fail(e, code) end
      return json(200, { ok = true, tool = agent_tools.view(name) })
    end
    if action == "test" then
      local j = mico.json_decode(body or "{}") or {}
      if type(j) ~= "table" then j = {} end
      local args = j.args
      if args ~= nil and type(args) ~= "table" then return fail("args 必须是对象") end
      return json(200, agent_tools.test(name, args or {}))
    end
    return err(404, "not found")
  end
  name = path:match("^/api/tools/([%w_%-]+)$")
  if name then
    if not agent_tools.get(name) then return err(404, "no such tool") end
    if method == "PUT" then
      local j = mico.json_decode(body or "", config.NULL)
      if type(j) ~= "table" or j == config.NULL or j.description == nil then
        return fail("需要 {description: string|null}")
      end
      local ok, e, code = agent_tools.set_description(name, j.description)
      if not ok then return fail(e, code) end
      return json(200, { ok = true, tool = agent_tools.view(name) })
    end
    if method == "DELETE" then
      local ok, e, code = agent_tools.delete(name)
      if not ok then return fail(e, code) end
      return json(200, { ok = true, tools = agent_tools.list() })
    end
    return err(405, "method not allowed")
  end
end

function M.handle(method, path, query, headers, body)
  local q = parse_query(query)
  if method == "GET" and (path == "/" or path == "/index.html") then
    local html = read_file(mico.script_dir() .. "/web/index.html") or "<h1>index.html missing</h1>"
    return { status = 200, headers = { ["Content-Type"] = "text/html; charset=utf-8" }, body = html }
  end
  if not authorized(headers, q) then return err(401, "unauthorized") end

  local pname, pid = path:match("^/stream/([%w_%-]+)/(.+)$")
  if pname and method == "GET" then
    local url, h = plugins.stream(pname, urldecode(pid))
    if not url then return err(502, h) end
    return { proxy = { url = url, headers = h, buffer_kb = tonumber(config.get("playback.buffer_kb")) or 1024 } }
  end

  if path == "/api/config" then
    if method == "GET" then
      return json(200, config_response())
    elseif method == "PUT" or method == "POST" then
      return put_config(body)
    end
    return err(405, "method not allowed")
  end
  if path == "/api/status" and method == "GET" then return status() end
  if path == "/api/conversations" and method == "GET" then
    local since = tonumber(q.since) or 0
    local out = {}
    if M.current then
      local cur = {}
      for k, v in pairs(M.current) do if k ~= "started_ms" then cur[k] = v end end
      cur.duration_ms = math.floor(mico.now_ms() - M.current.started_ms)
      out[1] = cur
    end
    for i = #M.conversations, 1, -1 do  -- newest first
      local t = M.conversations[i]
      if t.id <= since then break end
      out[#out + 1] = t
    end
    local last = M.conversations[#M.conversations]
    return json(200, { conversations = setmetatable(out, { __jsontype = "array" }), last_id = last and last.id or 0 })
  end
  if path == "/api/logs" and method == "GET" then
    local n = math.floor(tonumber(q.lines) or 200)
    if n < 1 then n = 1 elseif n > 1000 then n = 1000 end
    local r = mico.log_tail(n)
    setmetatable(r.lines, { __jsontype = "array" })
    return json(200, r)
  end
  if path == "/api/save/jobs" and method == "GET" then return json(200, require("saver").list()) end
  if path == "/api/save/test" and method == "POST" then return json(200, require("saver").test()) end
  if path == "/api/index/sync" and method == "POST" then
    local n, e = require("indexer").sync("manual")
    if not n then return json(500, { error = tostring(e), index = require("indexer").info() }) end
    return json(200, { ok = true, tracks = n, index = require("indexer").info() })
  end
  if path == "/api/plugin-template" and method == "GET" then
    return json(200, { source = plugins.TEMPLATE })
  end
  if path == "/api/plugins" then
    if method == "GET" then return json(200, setmetatable(plugins.list(), { __jsontype = "array" })) end
    if method == "POST" then
      local j = mico.json_decode(body or "")
      if type(j) ~= "table" then return err(400, "需要 {source} 或 {url}") end
      local source = j.source
      if type(source) ~= "string" and type(j.url) == "string" and j.url ~= "" then
        local r = mico.http({ url = j.url, timeout_ms = 15000 })
        if r.error then return err(400, "下载失败: " .. r.error) end
        if r.status ~= 200 then return err(400, "下载失败: HTTP " .. tostring(r.status)) end
        source = r.body
      end
      if type(source) ~= "string" then return err(400, "需要 {source} 或 {url}") end
      local name, e, code = plugins.save(source, { name = j.name, overwrite = j.overwrite == true })
      if not name then return err(code or 400, e) end
      return json(200, { ok = true, name = name, plugins = plugins.list() })
    end
    return err(405, "method not allowed")
  end
  local sname = path:match("^/api/plugins/([%w_%-]+)/source$")
  if sname then
    if not plugins.exists(sname) then return err(404, "no such plugin") end
    if method == "GET" then
      local src, e = plugins.source(sname)
      if not src then return err(500, e) end
      return json(200, { name = sname, source = src })
    end
    if method == "PUT" then
      local j = mico.json_decode(body or "")
      if type(j) ~= "table" or type(j.source) ~= "string" then return err(400, "需要 {source}") end
      local name, e, code = plugins.save(j.source, { name = sname, overwrite = true })
      if not name then return err(code or 400, e) end
      return json(200, { ok = true, name = name, plugins = plugins.list() })
    end
    return err(405, "method not allowed")
  end
  local dname = path:match("^/api/plugins/([%w_%-]+)$")
  if dname and method == "DELETE" then
    local ok, e, code = plugins.remove(dname)
    if not ok then return err(code or 400, e) end
    return json(200, { ok = true, plugins = plugins.list() })
  end
  local n, action = path:match("^/api/plugins/([%w_%-]+)/(%a+)$")
  if n and method == "POST" and (action == "enable" or action == "disable") then
    local ok, e = plugins.set_enabled(n, action == "enable")
    if not ok then return err(404, e) end
    return json(200, { ok = true, plugins = plugins.list() })
  end
  local tr = M.tools_route(method, path, body)
  if tr then return tr end
  if path == "/api/ask" and method == "POST" then
    local j = mico.json_decode(body or "")
    if type(j) ~= "table" or type(j.text) ~= "string" or j.text == "" then return err(400, "需要 {text}") end
    local reply, e = M.ask(j.text)
    if not reply then return err(502, e) end
    return json(200, { reply = reply })
  end
  return err(404, "not found")
end

return M
