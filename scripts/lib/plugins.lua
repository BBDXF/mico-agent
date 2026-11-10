-- Music plugin manager. Plugins live in <dir>/*.lua and return
--   { name, type = "local"|"online", version, description, setup(cfg, all_cfg),
--     list_tracks() (local) | search(query, limit) (online), stream(id) -> url, headers,
--     on_play(id) (optional) }
-- Tracks are addressed as "<plugin>:<id>".
local config = require("config")

local M = {}
M.plugins = {}  -- name -> { mod = table, file = path, enabled = bool, error = string }
M.order = {}
-- Plugins shipped with mico-agent: can be disabled but not deleted.
M.builtin = { fnos = true, bili = true }

function M.dir()
  local d = config.get("plugins.dir")
  if d and d ~= "" then return d end
  return mico.script_dir() .. "/plugins"
end

local function validate(p)
  if type(p) ~= "table" then return nil, "plugin must return a table" end
  if type(p.name) ~= "string" or not p.name:match("^[%w_%-]+$") then return nil, "invalid name" end
  if p.type ~= "local" and p.type ~= "online" then return nil, "type must be local or online" end
  if type(p.stream) ~= "function" then return nil, "stream(id) required" end
  if p.type == "local" and type(p.list_tracks) ~= "function" then return nil, "list_tracks() required" end
  if p.type == "online" and type(p.search) ~= "function" then return nil, "search(query, limit) required" end
  return p
end

-- Loads plugin source; returns the validated table or nil, err.
function M.compile(source, chunkname)
  local fn, err = loadstring(source, "=" .. (chunkname or "plugin"))
  if not fn then return nil, err end
  local ok, p = pcall(fn)
  if not ok then return nil, tostring(p) end
  return validate(p)
end

local function is_enabled(name)
  local e = config.get("plugins.enabled") or {}
  return e[name] ~= false
end

local function setup(entry)
  local p = entry.mod
  if p.setup then
    local ok, err = pcall(p.setup, p.config or {}, config.current)
    if not ok then entry.error = tostring(err) end
  end
end

local function add(p, file)
  if not M.plugins[p.name] then M.order[#M.order + 1] = p.name end
  local entry = { mod = p, file = file, enabled = is_enabled(p.name) }
  M.plugins[p.name] = entry
  setup(entry)
  return entry
end

function M.load_all()
  M.plugins, M.order = {}, {}
  local dir = M.dir()
  for _, f in ipairs(mico.listdir(dir) or {}) do
    if f:sub(-4) == ".lua" then
      local path = dir .. "/" .. f
      local fh = io.open(path, "r")
      local src = fh and fh:read("*a")
      if fh then fh:close() end
      local p, err = M.compile(src or "", f)
      if p then add(p, path) else mico.log("plugin", f, "failed:", err) end
    end
  end
  return #M.order
end

-- Re-applies configuration (enabled flags, setup) after a config change.
function M.reconfigure()
  for _, name in ipairs(M.order) do
    local e = M.plugins[name]
    e.enabled = is_enabled(name)
    e.error = nil
    setup(e)
  end
end

function M.get(name)
  local e = M.plugins[name]
  return e and e.enabled and e.mod or nil
end

function M.list()
  local out = {}
  for _, name in ipairs(M.order) do
    local e = M.plugins[name]
    out[#out + 1] = {
      name = name, type = e.mod.type, version = e.mod.version or "", description = e.mod.description or "",
      enabled = e.enabled, error = e.error, file = e.file, builtin = M.builtin[name] == true,
    }
  end
  return out
end

function M.of_type(t)
  local out = {}
  for _, name in ipairs(M.order) do
    local e = M.plugins[name]
    if e.enabled and e.mod.type == t and (not e.mod.available or e.mod.available()) then out[#out + 1] = e.mod end
  end
  return out
end

function M.any_available()
  return #M.of_type("local") > 0 or #M.of_type("online") > 0
end

function M.set_enabled(name, on)
  if not M.plugins[name] then return nil, "no such plugin" end
  local ok, err = config.save({ plugins = { enabled = { [name] = on and true or false } } })
  if not ok then return nil, err end
  M.plugins[name].enabled = on and true or false
  if M.on_change then M.on_change() end
  return true
end

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

function M.exists(name) return M.plugins[name] ~= nil end

function M.path_of(name)
  local e = M.plugins[name]
  return e and e.file or (M.dir() .. "/" .. name .. ".lua")
end

function M.source(name)
  if not M.plugins[name] then return nil, "no such plugin" end
  local s = read(M.path_of(name))
  if not s then return nil, "cannot read source" end
  return s
end

-- Validates source, writes <dir>/<name>.lua (previous version -> .bak),
-- (re)loads it and re-indexes when it is a local plugin.
-- opts.name: required plugin name; opts.overwrite: allow replacing.
-- Returns name or nil, err, http_status.
function M.save(source, opts)
  opts = opts or {}
  if type(source) ~= "string" or source == "" then return nil, "source 为空", 400 end
  local p, err = M.compile(source, (opts.name or "plugin") .. ".lua")
  if not p then return nil, err, 400 end
  if opts.name and opts.name ~= "" and opts.name ~= p.name then
    return nil, "name mismatch: 文件中 name = " .. p.name .. "，应为 " .. opts.name, 400
  end
  if M.plugins[p.name] and not opts.overwrite then return nil, "插件已存在: " .. p.name, 409 end
  local path = M.path_of(p.name)
  local old = read(path)
  if old then
    local ok, werr = write(path .. ".bak", old)
    if not ok then return nil, werr, 500 end
  end
  local ok, werr = write(path, source)
  if not ok then return nil, werr, 500 end
  local e = add(p, path)
  if M.on_change then M.on_change() end
  if p.type == "local" and e.enabled then
    local n, serr = M.sync_index("music")
    if not n then e.error = serr end
  end
  return p.name
end

-- Backwards compatible helper (old POST /api/plugins {name, source}).
function M.install(name, source)
  local n, err = M.save(source, { name = name, overwrite = true })
  return n, err
end

function M.remove(name)
  local e = M.plugins[name]
  if not e then return nil, "no such plugin", 404 end
  if M.builtin[name] then return nil, "内置插件不能删除，只能禁用", 400 end
  local old = read(e.file)
  if old then write(e.file .. ".bak", old) end
  os.remove(e.file)
  M.plugins[name] = nil
  for i, n in ipairs(M.order) do if n == name then table.remove(M.order, i) break end end
  if M.on_change then M.on_change() end
  return true
end

M.TEMPLATE = [==[
-- mico-agent 音乐插件模板。
-- 插件是一个 Lua 文件，返回一个表。放在 plugins 目录（或通过网页上传）即可。
-- 两种类型：
--   type = "local"  : 本地/私有曲库。实现 list_tracks()，曲目会进入模糊索引，
--                     语音识别错字也能匹配。
--   type = "online" : 在线搜索。实现 search(query, limit)，本地没有好结果或
--                     用户说“在B站/在线播放…”时调用。
-- 两种类型都必须实现 stream(id) -> url, headers。
-- 可用 API：mico.http{url,method,headers,body,timeout_ms} -> {status,body,error}，
--   mico.json_decode / mico.json_encode / mico.md5 / mico.sha256 / mico.log。
local M = {
  name = "myplugin",         -- 唯一名称：只能用字母、数字、_、-；须与文件名一致
  type = "online",           -- "local" 或 "online"
  version = "0.1",
  description = "示例插件",  -- 在网页插件列表中显示
}

-- 插件配置：每项都写清楚含义、示例与默认值。
M.config = {
  -- 服务地址（不带结尾斜杠）。例："https://music.example.com"   默认：""
  url = "",
  -- 访问令牌（可选）。例："abc123"   默认：""
  token = "",
}

-- 可选：加载/重新加载时调用，参数为 M.config。可在此读取环境变量覆盖。
function M.setup(cfg)
end

-- 可选：返回 false 时插件暂不参与（例如未配置地址）。
function M.available()
  return M.config.url ~= ""
end

-- type = "local" 时必需：返回全部曲目
--   { {id = "1", title = "晴天", artist = "周杰伦", album = "叶惠美", duration = 269}, ... }
-- 失败时 return nil, "错误信息"。
-- function M.list_tracks()
--   return {}
-- end

-- type = "online" 时必需：搜索，返回同样格式的列表（最多 limit 条）。
function M.search(query, limit)
  local r = mico.http({ url = M.config.url .. "/search?q=" .. query, timeout_ms = 10000 })
  if r.error then return nil, r.error end
  local j = mico.json_decode(r.body) or {}
  local out = {}
  for _, t in ipairs(j.items or {}) do
    out[#out + 1] = { id = tostring(t.id), title = t.title or "", artist = t.artist or "", album = "" }
    if #out >= (limit or 5) then break end
  end
  return out
end

-- 必需：返回可直接播放的音频地址和需要的请求头（由内置代理转发给音箱）。
-- 音箱解码能力有限：优先返回 mp3 / AAC(m4a) 地址。
function M.stream(id)
  return M.config.url .. "/stream/" .. id, { Authorization = "Bearer " .. M.config.token }
end

-- 可选：开始播放后调用（如上报播放记录）。
-- function M.on_play(id) end

return M
]==]

function M.split_id(id)
  id = tostring(id or "")
  local name, raw = id:match("^([%w_%-]+):(.+)$")
  if name and M.plugins[name] then return name, raw end
  return "fnos", id  -- bare ids are 飞牛 guids (backwards compatible)
end

-- Rebuilds fuzzy index `music` from all enabled local plugins.
function M.sync_index(index_name)
  index_name = index_name or "music"
  local all, errs = {}, {}
  for _, p in ipairs(M.of_type("local")) do
    local ok, list, err = pcall(p.list_tracks)
    if ok and list then
      for _, t in ipairs(list) do
        local item = {}
        for k, v in pairs(t) do item[k] = v end
        item.raw_id = t.id
        item.id = p.name .. ":" .. tostring(t.id)
        item.plugin = p.name
        item.title = item.title or ""
        item.artist = item.artist or ""
        item.album = item.album or ""
        all[#all + 1] = item
      end
    else
      errs[#errs + 1] = p.name .. ": " .. tostring(ok and err or list)
    end
  end
  -- Any plugin failure keeps the old index (unless it is empty: then take what we got).
  if #errs > 0 and (#all == 0 or mico.index_size(index_name) > 0) then
    return nil, table.concat(errs, "; ")
  end
  mico.index_clear(index_name)
  mico.index_add(index_name, all)
  return #all, (#errs > 0) and table.concat(errs, "; ") or nil
end

-- Searches enabled online plugins; ids are namespaced.
function M.search_online(query, limit)
  local out, errs = {}, {}
  for _, p in ipairs(M.of_type("online")) do
    local ok, list, err = pcall(p.search, query, limit or 5)
    if ok and list then
      for _, t in ipairs(list) do
        t.raw_id = t.id
        t.id = p.name .. ":" .. tostring(t.id)
        t.plugin = p.name
        t.matched = "online"
        out[#out + 1] = t
      end
    else
      errs[#errs + 1] = p.name .. ": " .. tostring(ok and err or list)
    end
  end
  if #out == 0 and #errs > 0 then return nil, table.concat(errs, "; ") end
  return out
end

-- Resolves an upstream url + headers for "<plugin>:<id>" (or plugin, id).
function M.stream(name, raw)
  if not raw then name, raw = M.split_id(name) end
  local p = M.get(name)
  if not p then return nil, "plugin not available: " .. tostring(name) end
  local ok, url, headers = pcall(p.stream, raw)
  if not ok then return nil, tostring(url) end
  if not url then return nil, headers or "no stream url" end
  return url, headers or {}
end

return M
