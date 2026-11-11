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
      "播客、访谈、讲座、相声、评书、有声书、节目、脱口秀、新闻等非歌曲内容，music_search 传 kind=\"audio\"。",
    }),
    max_steps = 8,
    max_history = 20,
  },
  -- Rule-based "播放 X" shortcut that skips the LLM when the match is clear.
  fast_path = { enabled = true, min_score = 0.6, margin = 0.15 },
  -- Voice takeover: "off" (default, native assistant untouched) | "music" | "all".
  takeover = { mode = "off", keywords = "请问,问问AI,小爱AI" },
  poll_ms = 50,
  -- Local-library index sync: on startup, every N minutes, and once on a search miss.
  index = { sync_on_start = true, sync_interval_min = 360, miss_resync_min = 10 },
  -- Plugin settings (飞牛 / B站 ...) live in each plugin file's M.config.
  web = { listen = "0.0.0.0:8080", token = "" },
  -- Built-in mDNS responder: http://<hostname>.local:<web port>
  mdns = { enabled = true, hostname = "mico", instance = "小爱音箱 mico-agent" },
  shell = { enabled = true },
  plugins = { dir = "", enabled = {} },
  -- Agent tools: custom tool dir, per-tool disable flags and description overrides.
  tools = { dir = "", disabled = {}, descriptions = {} },
  -- mode "proxy" (default): speaker plays http://127.0.0.1:PORT/stream/...;
  -- "download" (opt-in fallback): fetch to /tmp first (max_mb cap).
  playback = { mode = "proxy", max_mb = 30, buffer_kb = 1024 },
  -- Online search filters: songs are 90–480 s singles; kind="audio" allows long items.
  online = {
    song_min_s = 90, song_max_s = 480, audio_max_s = 14400,
    skip_keywords = "合集,串烧,歌单,连播,小时,循环,伴奏,教学,reaction",
  },
  -- 边播边存: save online tracks to a WebDAV share while playing (off by default).
  save = {
    enabled = false, webdav_url = "", username = "", password = "",
    filename = "{artist} - {title}.{ext}",
    min_duration_s = 60, max_duration_s = 600, max_size_mb = 200, queue_size = 3,
    skip_keywords = "合集,串烧,翻唱,cover,伴奏,纯音乐,DJ,remix,live,现场,教学,reaction",
    require_match = true, normalize = true, normalize_timeout_ms = 8000, require_artist = true,
  },
  -- Process log: bounded file with rotation (keep in RAM-backed /tmp on the speaker).
  log = { file = "/tmp/mico-agent.log", max_kb = 512, keep = 1, stderr = true },
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
  { { "log", "file" }, "MICO_LOG_FILE" },
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
  { key = "takeover.mode", label = "语音接管模式", type = "enum", options = { "off", "music", "all" }, help = "默认 off（关闭）：不接管任何语音，小爱原生助手照常处理，需在此显式开启。music：只接管点歌（快路径能直接播放的请求）和以接管关键词开头的话；all：接管所有语音（闹钟、智能家居等原生功能将失效）。web 控制台提问不受影响。保存后立即生效" },
  { key = "takeover.keywords", label = "接管关键词", type = "string", help = "music 模式下，以这些词开头的话交给本程序（去掉关键词后先走快路径再交给 LLM）。逗号分隔（中英文逗号均可），英文不区分大小写" },
  { key = "index.sync_on_start", label = "启动时同步曲库", type = "bool", help = "启动后立即从本地插件（飞牛等）重建曲库索引" },
  { key = "index.sync_interval_min", label = "定时同步间隔（分钟）", type = "number", min = 0, max = 10080, help = "每隔多少分钟自动重建曲库索引；0 关闭定时同步" },
  { key = "index.miss_resync_min", label = "未命中重同步间隔（分钟）", type = "number", min = 0, max = 10080, help = "本地搜索最佳分数低于快路径最低分、且距上次同步超过此分钟数时，先重新同步再搜一次；0 关闭" },
  { key = "playback.mode", label = "播放方式", type = "enum", options = { "proxy", "download" }, help = "proxy：音箱经本机代理流式播放；download：先下载到 /tmp" },
  { key = "playback.max_mb", label = "下载上限（MB）", type = "number", min = 1, max = 200, help = "download 模式下单个文件大小上限" },
  { key = "playback.buffer_kb", label = "代理缓冲（KB）", type = "number", integer = true, min = 64, max = 8192, help = "proxy 模式的缓冲大小" },
  { key = "online.song_min_s", label = "在线歌曲最短（秒）", type = "number", integer = true, min = 0, max = 3600, help = "在线搜索歌曲时，时长低于此值的结果不播放（过滤片段、预告）" },
  { key = "online.song_max_s", label = "在线歌曲最长（秒）", type = "number", integer = true, min = 60, max = 3600, help = "在线搜索歌曲时，时长超过此值的结果不播放（过滤合集、串烧）；没有单曲时会从分P/合集里挑出对应的一集" },
  { key = "online.audio_max_s", label = "在线长音频最长（秒）", type = "number", integer = true, min = 60, max = 86400, help = "播客、访谈、讲座、相声等非歌曲内容的时长上限；短于 60 秒的结果不播放" },
  { key = "online.skip_keywords", label = "在线歌曲跳过关键词", type = "string", help = "逗号分隔；在线歌曲标题包含任一关键词（不区分大小写）时不选" },
  { key = "save.enabled", label = "边播边存", type = "bool", help = "播放在线音乐源的歌曲时，同时通过 WebDAV 保存到 NAS（默认关闭）" },
  { key = "save.webdav_url", label = "WebDAV 目录地址", type = "string", help = "保存目录的 URL，如 http://nas:5005/音乐/在线收藏/；目录不存在时自动创建" },
  { key = "save.username", label = "WebDAV 用户名", type = "string", help = "Basic 认证用户名；留空不认证" },
  { key = "save.password", label = "WebDAV 密码", type = "secret", help = "Basic 认证密码；显示为 ****** 时提交不修改" },
  { key = "save.filename", label = "文件名模板", type = "string", help = "可用 {artist} {title} {ext}；歌手为空时自动去掉分隔符。非法字符 / \\ : * ? \" < > | 替换为 _" },
  { key = "save.min_duration_s", label = "最短时长（秒）", type = "number", integer = true, min = 0, max = 36000, help = "搜索结果时长低于此值不保存（时长未知时不检查）" },
  { key = "save.max_duration_s", label = "最长时长（秒）", type = "number", integer = true, min = 0, max = 36000, help = "搜索结果时长超过此值不保存；0 不限制" },
  { key = "save.max_size_mb", label = "大小上限（MB）", type = "number", integer = true, min = 1, max = 2048, help = "超过此大小不保存；大小未知时传输中超过则中止并删除临时文件" },
  { key = "save.queue_size", label = "保存队列长度", type = "number", integer = true, min = 0, max = 20, help = "排队等待保存的最大数量；超出的直接放弃。0 表示不排队，正在保存时新的请求直接放弃" },
  { key = "save.skip_keywords", label = "跳过关键词", type = "string", help = "逗号分隔；标题包含任一关键词（不区分大小写）时不保存" },
  { key = "save.require_match", label = "要求标题匹配", type = "bool", help = "规则命名时（未用大模型或大模型失败），只有结果标题包含所点歌名（以及所说的歌手，支持拼音模糊）时才保存" },
  { key = "save.normalize", label = "大模型规范命名", type = "bool", help = "开始保存前调用一次大模型，从用户原话和在线结果标题得出规范的歌手和歌名（修正同音错字、去掉【】/MV/无损等修饰）；判断为翻唱/合集/不确定时不保存。失败时退回规则命名" },
  { key = "save.normalize_timeout_ms", label = "命名超时（毫秒）", type = "number", integer = true, min = 1000, max = 60000, help = "规范命名的大模型调用超时；调用发生在开始播放之后，会短暂阻塞语音处理" },
  { key = "save.require_artist", label = "要求歌手", type = "bool", help = "无法确定歌手时不保存" },
  { key = "log.file", label = "日志文件", type = "string", help = "运行日志路径，默认 /tmp/mico-agent.log（内存盘）；空串只输出到 stderr。不要放在 /data（空间很小）" },
  { key = "log.max_kb", label = "日志大小上限（KB）", type = "number", integer = true, min = 64, max = 10240, help = "超过后轮转为 .1 文件；总占用 ≤ 上限 ×（保留份数 + 1）" },
  { key = "log.keep", label = "日志保留份数", type = "number", integer = true, min = 0, max = 5, help = "轮转后保留的旧日志数量（file.1 … file.N）；0 表示直接丢弃" },
  { key = "log.stderr", label = "同时输出到 stderr", type = "bool", help = "日志同时写到标准错误（在音箱上建议启动时重定向到 /dev/null）" },
  { key = "web.listen", label = "Web 监听地址", type = "string", restart = true, help = "如 0.0.0.0:8080，空串关闭 Web" },
  { key = "web.token", label = "Web 访问令牌", type = "secret", help = "非空时需 Authorization: Bearer 或 ?token=" },
  { key = "mdns.enabled", label = "局域网域名（mDNS）", type = "bool", help = "内置 mDNS 应答：局域网内可用 http://<主机名>.local:端口 访问，并发布 _http._tcp 服务（环境变量 MICO_MDNS=0 可强制关闭）。保存后约 1 秒生效" },
  { key = "mdns.hostname", label = "mDNS 主机名", type = "string", pattern = "^[a-z0-9%-]+$", max_len = 63, pattern_help = "只能包含小写字母、数字和 -，1–63 个字符", help = "<主机名>.local；只能用小写字母、数字和 -，1–63 个字符。保存后约 1 秒生效" },
  { key = "mdns.instance", label = "mDNS 服务名", type = "string", help = "DNS-SD 服务实例名（可用中文，最长 63 字节），显示在服务发现工具里。保存后约 1 秒生效" },
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
    if (f.pattern and not v:match(f.pattern)) or (f.max_len and #v > f.max_len) then
      return nil, f.key .. " " .. (f.pattern_help or "格式不正确")
    end
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
