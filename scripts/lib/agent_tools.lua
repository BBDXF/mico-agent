-- Agent tool registry. Wraps mico.tool / mico.tool_remove so every tool
-- (builtin from tools.lua, custom from <tools.dir>/*.lua) is tracked here with
-- call stats; only enabled tools are pushed to C++ (i.e. sent to the LLM),
-- using the description override from config `tools.descriptions`.
local config = require("config")

local M = { tools = {} }  -- name -> entry
local raw_tool, raw_remove = mico.tool, mico.tool_remove

function M.dir()
  local d = config.get("tools.dir")
  if d and d ~= "" then return d end
  return mico.script_dir() .. "/tools"
end

function M.enabled(name)
  local d = config.get("tools.disabled") or {}
  return d[name] ~= true
end

function M.description(e)
  local d = config.get("tools.descriptions") or {}
  local v = d[e.name]
  if type(v) == "string" and v ~= "" then return v end
  return e.description
end

local function push(e)
  if M.enabled(e.name) then
    raw_tool({ name = e.name, description = M.description(e), parameters = e.parameters, handler = e.wrapped })
  else
    raw_remove(e.name)
  end
end

local function record(e, ms, failed)
  local s = e.stats
  s.calls = s.calls + 1
  if failed then s.errors = s.errors + 1 end
  s.total_ms = s.total_ms + ms
  s.last_time = os.date("%Y-%m-%d %H:%M:%S")
end

-- Adds/replaces a tool. t = {name, description, parameters, handler}.
function M.add(t, source, file)
  local old = M.tools[t.name]
  local e = {
    name = t.name, description = t.description or "", handler = t.handler,
    parameters = type(t.parameters) == "table" and t.parameters or { type = "object", properties = {} },
    source = source or "builtin", file = file,
    stats = old and old.stats or { calls = 0, errors = 0, total_ms = 0 },
  }
  e.wrapped = function(args)
    local t0 = mico.now_ms()
    local ok, r = pcall(e.handler, args)
    record(e, mico.now_ms() - t0, not ok or (type(r) == "table" and r.error ~= nil))
    if not ok then error(r, 0) end
    return r
  end
  M.tools[t.name] = e
  push(e)
  return e
end

function M.remove(name)
  M.tools[name] = nil
  raw_remove(name)
end

-- Builtin registrations go through the registry.
mico.tool = function(t)
  if type(t) ~= "table" or type(t.name) ~= "string" or t.name == "" then error("mico.tool: name required", 2) end
  if type(t.handler) ~= "function" then error("mico.tool: handler function required", 2) end
  local old = M.tools[t.name]
  M.add(t, old and old.source or "builtin", old and old.file)
end
mico.tool_remove = function(name) M.remove(name) end

-- Re-pushes everything (after config changes).
function M.sync()
  for _, e in pairs(M.tools) do push(e) end
end

local function json_array(t) return setmetatable(t, { __jsontype = "array" }) end

local function view(e)
  local s = e.stats
  return {
    name = e.name, description = M.description(e), default_description = e.description,
    parameters = e.parameters, source = e.source, enabled = M.enabled(e.name),
    editable = e.source == "custom", file = e.file,
    stats = { calls = s.calls, errors = s.errors, last_time = s.last_time,
              avg_ms = s.calls > 0 and math.floor(s.total_ms / s.calls + 0.5) or 0 },
  }
end

function M.get(name) return M.tools[name] end

function M.list()
  local names = {}
  for n in pairs(M.tools) do names[#names + 1] = n end
  table.sort(names, function(a, b)
    local sa, sb = M.tools[a].source, M.tools[b].source
    if sa ~= sb then return sa == "builtin" end
    return a < b
  end)
  local out = {}
  for i, n in ipairs(names) do out[i] = view(M.tools[n]) end
  return json_array(out)
end

function M.view(name) return M.tools[name] and view(M.tools[name]) end

function M.set_enabled(name, on)
  if not M.tools[name] then return nil, "no such tool", 404 end
  local ok, err = config.save({ tools = { disabled = { [name] = on and config.NULL or true } } })
  if not ok then return nil, err, 500 end
  push(M.tools[name])
  return true
end

-- desc: string override, or nil/config.NULL to reset.
function M.set_description(name, desc)
  if not M.tools[name] then return nil, "no such tool", 404 end
  if desc ~= nil and desc ~= config.NULL and type(desc) ~= "string" then
    return nil, "description 必须是字符串或 null", 400
  end
  if desc == "" then desc = nil end
  local ok, err = config.save({ tools = { descriptions = { [name] = desc or config.NULL } } })
  if not ok then return nil, err, 500 end
  push(M.tools[name])
  return true
end

-- Runs the handler directly (even when disabled). Not counted in stats.
function M.test(name, args)
  local e = M.tools[name]
  if not e then return nil, "no such tool", 404 end
  local t0 = mico.now_ms()
  local ok, r = pcall(e.handler, type(args) == "table" and args or {})
  local res = { ms = math.floor(mico.now_ms() - t0) }
  if ok then res.result = r else res.error = tostring(r) end
  return res
end

-- ---------------------------------------------------------------- custom files

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, "cannot write " .. path .. ": " .. tostring(err) end
  f:write(data)
  f:close()
  return true
end

local function validate(t)
  if type(t) ~= "table" then return nil, "tool file must return a table" end
  if type(t.name) ~= "string" or not t.name:match("^[%w_%-]+$") then return nil, "invalid name（只能用字母、数字、_、-）" end
  if type(t.description) ~= "string" then return nil, "description 必须是字符串" end
  if t.parameters ~= nil and type(t.parameters) ~= "table" then return nil, "parameters 必须是表（JSON Schema）" end
  if type(t.handler) ~= "function" then return nil, "handler(args) 必须是函数" end
  return t
end

-- Compiles tool source; errors carry "<chunk>:<line>:".
function M.compile(source, chunkname)
  local fn, err = loadstring(source, "=" .. (chunkname or "tool.lua"))
  if not fn then return nil, err end
  local ok, t = pcall(fn)
  if not ok then return nil, tostring(t) end
  return validate(t)
end

function M.path_of(name) return M.dir() .. "/" .. name .. ".lua" end

function M.load_custom()
  local dir = M.dir()
  for _, f in ipairs(mico.listdir(dir) or {}) do
    if f:sub(-4) == ".lua" then
      local path = dir .. "/" .. f
      local t, err = M.compile(read(path) or "", f)
      if not t then
        mico.log("tool", f, "failed:", err)
      elseif M.tools[t.name] and M.tools[t.name].source == "builtin" then
        mico.log("tool", f, "skipped: name clashes with builtin", t.name)
      else
        M.add(t, "custom", path)
      end
    end
  end
end

local function custom(name)
  local e = M.tools[name]
  if not e then return nil, "no such tool", 404 end
  if e.source ~= "custom" then return nil, "内置工具不能编辑或删除，只能禁用或修改描述", 400 end
  return e
end

function M.source(name)
  local e, err, code = custom(name)
  if not e then return nil, err, code end
  local s = read(e.file)
  if not s then return nil, "cannot read source", 500 end
  return s
end

-- opts.name: must match (PUT); opts.overwrite: replace existing custom tool.
function M.save(source, opts)
  opts = opts or {}
  if type(source) ~= "string" or source == "" then return nil, "source 为空", 400 end
  local t, err = M.compile(source, (opts.name or "tool") .. ".lua")
  if not t then return nil, err, 400 end
  if opts.name and opts.name ~= t.name then
    return nil, "name mismatch: 文件中 name = " .. t.name .. "，应为 " .. opts.name, 400
  end
  local old = M.tools[t.name]
  if old and old.source == "builtin" then return nil, "与内置工具重名: " .. t.name, 409 end
  if old and not opts.overwrite then return nil, "工具已存在: " .. t.name, 409 end
  local path = old and old.file or M.path_of(t.name)
  local prev = read(path)
  if prev then
    local ok, werr = write(path .. ".bak", prev)
    if not ok then return nil, werr, 500 end
  end
  local ok, werr = write(path, source)
  if not ok then return nil, werr, 500 end
  M.add(t, "custom", path)
  return t.name
end

function M.delete(name)
  local e, err, code = custom(name)
  if not e then return nil, err, code end
  local old = read(e.file)
  if old then write(e.file .. ".bak", old) end
  os.remove(e.file)
  M.remove(name)
  return true
end

M.TEMPLATE = [==[
-- mico-agent 自定义工具模板。
-- 工具是一个 Lua 文件，返回一个表；放在 tools 目录（默认 <脚本目录>/tools，
-- 可用配置 tools.dir 修改）或通过网页上传即可。LLM 会根据 description 和
-- parameters 决定何时调用。文件名须为 <name>.lua。
-- 可用 API：mico.http{url,method,headers,body,timeout_ms} -> {status,body,error}，
--   mico.exec(cmd, {timeout_ms}) / mico.json_decode / mico.json_encode / mico.log。
return {
  -- 唯一名称：只能用字母、数字、_、-（LLM 以此名调用）
  name = "my_tool",
  -- 给 LLM 看的说明：做什么、何时使用。可在网页上覆盖。
  description = "示例：把输入文字重复指定次数",
  -- 参数的 JSON Schema（type = "object"）
  parameters = {
    type = "object",
    properties = {
      text = { type = "string", description = "要重复的文字" },
      times = { type = "number", description = "重复次数，默认 2" },
    },
    required = { "text" },
  },
  -- args 为 LLM 传入的参数表。返回字符串或表（表会编码为 JSON 交给 LLM）；
  -- 出错可 error("...") 或返回 { error = "..." }。
  handler = function(args)
    local n = math.min(tonumber(args.times) or 2, 10)
    return { result = string.rep(args.text or "", n) }
  end,
}
]==]

return M
