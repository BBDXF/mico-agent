-- Configuration: built-in defaults < config.json < environment variables.
local M = {}

M.defaults = {
  llm = {
    base_url = "https://api.siliconflow.cn/v1",
    api_key = "",
    model = "Qwen/Qwen3-8B",
    timeout_ms = 60000,
    extra = { enable_thinking = false },
  },
  agent = {
    system_prompt = table.concat({
      "你是运行在小爱音箱上的语音助手。回答会被直接朗读，请用简短口语化的中文，不要使用 Markdown。",
      "用户的话来自语音识别，可能有同音字或错别字。点歌时先用 music_search 搜索（它能容忍识别错误），",
      "用户要求播放时，只要有一个结果明显最匹配就立即调用 music_play，不要征求确认；只有多个结果同样可能时才简短询问。",
      "曲库里外文歌手多用原名（如艾薇儿=Avril Lavigne），中文名搜不到时换原名再搜一次。",
      "本地曲库没有时 music_search 会自动在线搜索；用户明确要求在线/B站时传 online=true。",
    }),
    max_steps = 8,
    max_history = 20,
  },
  -- Rule-based "播放 X" shortcut that skips the LLM when the match is clear.
  fast_path = { enabled = true, min_score = 0.6, margin = 0.15 },
  poll_ms = 50,
  -- Local-library index sync: on startup, every N minutes, and once on a search miss.
  index = { sync_on_start = true, sync_interval_min = 360, miss_resync_min = 10 },
  -- Plugin settings (飞牛 / B站 ...) live in each plugin file's M.config.
  web = { listen = "0.0.0.0:8080", token = "" },
  shell = { enabled = true },
  plugins = { dir = "", enabled = {} },
  -- Agent tools: custom tool dir, per-tool disable flags and description overrides.
  tools = { dir = "", disabled = {}, descriptions = {} },
  -- mode "proxy" (default): speaker plays http://127.0.0.1:PORT/stream/...;
  -- "download" (opt-in fallback): fetch to /tmp first (max_mb cap).
  playback = { mode = "proxy", max_mb = 30, buffer_kb = 1024 },
  instruction_log = "/tmp/mico_aivs_lab/instruction.log",
  dry_run = false,
}

-- path in the config table -> environment variable
M.env_map = {
  { { "llm", "base_url" }, "MICO_LLM_BASE_URL" },
  { { "llm", "api_key" }, "MICO_LLM_API_KEY" },
  { { "llm", "model" }, "MICO_LLM_MODEL" },
  { { "web", "listen" }, "MICO_WEB_LISTEN" },
  { { "web", "token" }, "MICO_WEB_TOKEN" },
  { { "shell", "enabled" }, "MICO_ENABLE_SHELL", "bool" },
  { { "plugins", "dir" }, "MICO_PLUGINS_DIR" },
  { { "tools", "dir" }, "MICO_TOOLS_DIR" },
  { { "playback", "mode" }, "MICO_PLAYBACK" },
  { { "instruction_log" }, "MICO_INSTRUCTION_LOG" },
  { { "dry_run" }, "MICO_DRY_RUN", "bool" },
}

-- Field descriptors for the web UI and PUT validation.
-- type: string | number | bool | enum | text | secret | json; restart = needs restart.
M.schema = {
  { key = "llm.base_url", label = "LLM 接口地址", type = "string", help = "OpenAI 兼容接口的 base URL，如 https://api.siliconflow.cn/v1" },
  { key = "llm.api_key", label = "LLM API Key", type = "secret", help = "接口密钥；显示为 ****** 时提交不修改" },
  { key = "llm.model", label = "模型", type = "string", help = "模型名，如 Qwen/Qwen3-8B" },
  { key = "llm.timeout_ms", label = "LLM 超时（毫秒）", type = "number", integer = true, min = 1000, max = 600000, help = "单次 LLM 请求超时" },
  { key = "llm.extra", label = "额外请求参数", type = "json", help = "合并进请求体的 JSON 对象，如 {\"enable_thinking\":false}" },
  { key = "agent.system_prompt", label = "系统提示词", type = "text", help = "发给 LLM 的 system prompt" },
  { key = "agent.max_steps", label = "最大工具调用轮数", type = "number", integer = true, min = 1, max = 50, help = "单次对话中 LLM ↔ 工具的最大往返次数" },
  { key = "agent.max_history", label = "历史消息条数", type = "number", integer = true, min = 0, max = 200, help = "保留的上下文消息条数" },
  { key = "fast_path.enabled", label = "启用快路径", type = "bool", help = "“播放 X” 匹配明确时跳过 LLM 直接播放" },
  { key = "fast_path.min_score", label = "快路径最低分", type = "number", min = 0, max = 1, help = "最佳匹配低于此分数时交给 LLM" },
  { key = "fast_path.margin", label = "快路径领先差", type = "number", min = 0, max = 1, help = "第一名领先第二名至少此分差才直接播放（分数 ≥0.8 时总是播放）" },
  { key = "index.sync_on_start", label = "启动时同步曲库", type = "bool", help = "启动后立即从本地插件（飞牛等）重建曲库索引" },
  { key = "index.sync_interval_min", label = "定时同步间隔（分钟）", type = "number", min = 0, max = 10080, help = "每隔多少分钟自动重建曲库索引；0 关闭定时同步" },
  { key = "index.miss_resync_min", label = "未命中重同步间隔（分钟）", type = "number", min = 0, max = 10080, help = "本地搜索最佳分数低于快路径最低分、且距上次同步超过此分钟数时，先重新同步再搜一次；0 关闭" },
  { key = "playback.mode", label = "播放方式", type = "enum", options = { "proxy", "download" }, help = "proxy：音箱经本机代理流式播放；download：先下载到 /tmp" },
  { key = "playback.max_mb", label = "下载上限（MB）", type = "number", min = 1, max = 200, help = "download 模式下单个文件大小上限" },
  { key = "playback.buffer_kb", label = "代理缓冲（KB）", type = "number", integer = true, min = 64, max = 8192, help = "proxy 模式的缓冲大小" },
  { key = "web.listen", label = "Web 监听地址", type = "string", restart = true, help = "如 0.0.0.0:8080，空串关闭 Web" },
  { key = "web.token", label = "Web 访问令牌", type = "secret", help = "非空时需 Authorization: Bearer 或 ?token=" },
  { key = "shell.enabled", label = "允许 shell 工具", type = "bool", help = "是否注册 run_shell 工具" },
  { key = "plugins.dir", label = "插件目录", type = "string", restart = true, help = "默认 <脚本目录>/plugins" },
  { key = "tools.dir", label = "自定义工具目录", type = "string", restart = true, help = "默认 <脚本目录>/tools；每个 .lua 文件是一个工具" },
  { key = "poll_ms", label = "轮询间隔（毫秒）", type = "number", integer = true, min = 1, max = 1000, help = "主循环读取识别日志 / Web 请求的间隔" },
  { key = "instruction_log", label = "识别日志路径", type = "string", restart = true, help = "小爱 instruction.log 路径" },
  { key = "dry_run", label = "演练模式", type = "bool", help = "不真正调用音箱 TTS/播放" },
}
M.schema_by_key = {}
for _, f in ipairs(M.schema) do M.schema_by_key[f.key] = f end

-- Sentinel for JSON null in a patch ("reset to default"); pass to mico.json_decode.
M.NULL = setmetatable({}, { __tostring = function() return "null" end })

M.file = {}     -- raw contents of the config file
M.current = {}  -- effective config

local function is_array(t)
  return type(t) == "table" and #t > 0
end

function M.copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = M.copy(x) end
  return out
end

-- Deep merge src into dst (tables merged, scalars/arrays replaced).
function M.merge(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == "table" and not is_array(v) and type(dst[k]) == "table" and next(v) ~= nil then
      M.merge(dst[k], v)
    else
      dst[k] = M.copy(v)
    end
  end
  return dst
end

local function exists(p)
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

function M.find_path()
  local p = mico.config_path and mico.config_path()
  if p and p ~= "" then return p end
  p = os.getenv("MICO_CONFIG")
  if p and p ~= "" then return p end
  if exists("./config.json") then return "./config.json" end
  return "/data/mico-agent/config.json"
end

local function get_path(t, path)
  for _, k in ipairs(path) do
    if type(t) ~= "table" then return nil end
    t = t[k]
  end
  return t
end

local function set_path(t, path, v)
  for i = 1, #path - 1 do
    t[path[i]] = t[path[i]] or {}
    t = t[path[i]]
  end
  t[path[#path]] = v
end

-- Defaults merged with the file (what the web UI edits; no env values).
function M.file_view()
  return M.merge(M.copy(M.defaults), M.file)
end

-- Names of settings currently overridden by environment variables.
function M.env_overrides()
  local out = {}
  for _, e in ipairs(M.env_map) do
    if os.getenv(e[2]) then out[#out + 1] = table.concat(e[1], ".") end
  end
  return out
end

function M.compute()
  local c = M.file_view()
  for _, e in ipairs(M.env_map) do
    local v = os.getenv(e[2])
    if v then
      if e[3] == "bool" then v = (v == "1" or v == "true") end
      set_path(c, e[1], v)
    end
  end
  M.current = c
  return c
end

function M.load(path)
  M.path = path or M.find_path()
  M.file = {}
  M.error = nil
  local f = io.open(M.path, "r")
  if f then
    local s = f:read("*a")
    f:close()
    local j, err = mico.json_decode(s)
    if type(j) == "table" then
      M.file = j
    else
      M.error = "invalid config " .. M.path .. ": " .. tostring(err)
      mico.log(M.error)
    end
  end
  return M.compute()
end

function M.get(dotted)
  local path = {}
  for part in dotted:gmatch("[^%.]+") do path[#path + 1] = part end
  return get_path(M.current, path)
end

local function validate_value(f, v)
  local t = f.type
  if t == "string" or t == "text" or t == "secret" then
    if type(v) ~= "string" then return nil, f.key .. " 必须是字符串" end
  elseif t == "bool" then
    if type(v) ~= "boolean" then return nil, f.key .. " 必须是布尔值" end
  elseif t == "enum" then
    for _, o in ipairs(f.options) do if v == o then return v end end
    return nil, f.key .. " 必须是 " .. table.concat(f.options, " / ") .. " 之一"
  elseif t == "number" then
    local n = tonumber(v)
    if type(v) == "boolean" or not n then return nil, f.key .. " 必须是数字" end
    if f.integer then n = math.floor(n) end
    if (f.min and n < f.min) or (f.max and n > f.max) then
      return nil, string.format("%s 必须在 %s–%s 之间", f.key, tostring(f.min), tostring(f.max))
    end
    return n
  elseif t == "json" then
    if type(v) ~= "table" then return nil, f.key .. " 必须是 JSON 对象" end
  end
  return v
end

-- Validates (and normalizes in place) a patch against the schema.
-- Returns nil on success, or error message and dotted key.
function M.validate(patch, prefix)
  for k, v in pairs(patch) do
    local key = (prefix and (prefix .. ".") or "") .. tostring(k)
    local f = M.schema_by_key[key]
    if v == M.NULL then
      -- reset to default: always allowed
    elseif f then
      local nv, e = validate_value(f, v)
      if e then return e, key end
      patch[k] = nv
    elseif type(v) == "table" then
      local e, ek = M.validate(v, key)
      if e then return e, ek end
    end
  end
end

-- Applies patch to dst: NULL removes the key (and empty parents).
local function apply_patch(dst, patch)
  for k, v in pairs(patch) do
    if v == M.NULL then
      dst[k] = nil
    elseif type(v) == "table" and not is_array(v) and next(v) ~= nil and type(dst[k]) == "table" then
      apply_patch(dst[k], v)
      if next(dst[k]) == nil then dst[k] = nil end
    elseif type(v) == "table" and not is_array(v) and next(v) ~= nil then
      local t = {}
      apply_patch(t, v)
      if next(t) ~= nil then dst[k] = t end
    else
      dst[k] = M.copy(v)
    end
  end
end

-- Merges patch into the file contents, writes pretty JSON and recomputes.
function M.save(patch)
  apply_patch(M.file, patch or {})
  local f, err = io.open(M.path, "w")
  if not f then return nil, "cannot write " .. M.path .. ": " .. tostring(err) end
  f:write(mico.json_encode(M.file, true), "\n")
  f:close()
  M.compute()
  if M.on_change then M.on_change(M.current) end
  return true
end

return M
