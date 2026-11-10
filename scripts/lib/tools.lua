-- Tools exposed to the LLM. register(opts) installs them via mico.tool.
local fnmusic = require("fnmusic")
local speaker = require("speaker")
local plugins = require("plugins")
local config = require("config")

local M = {}

local function truncate(s, n)
  if #s <= n then return s end
  -- Back off to a UTF-8 character boundary (continuation bytes are 0x80-0xBF).
  while n > 0 and s:byte(n + 1) and s:byte(n + 1) >= 0x80 and s:byte(n + 1) < 0xC0 do n = n - 1 end
  return s:sub(1, n) .. "\n...(truncated " .. (#s - n) .. " bytes)"
end

-- Ensures the fuzzy index is populated (lazy first sync).
function M.ensure_index()
  return require("indexer").ensure()
end

local function good(s)
  return s.score >= 0.6 or s.matched == "artist" or s.matched == "server"
end

-- Fuzzy search over the local index; falls back to the 飞牛 server search,
-- then to online plugins when nothing local is good (score < 0.6).
-- opts.online: true = only online, false = never online.
function M.search_music(query, limit, opts)
  limit = limit or 5
  opts = opts or {}
  local out = {}
  if opts.online ~= true then
    local ok, err = M.ensure_index()
    if not ok then mico.log("index:", err) end
    local function local_search()
      local r = {}
      for _, h in ipairs(mico.index_search("music", query, { limit = limit })) do
        local s = h.item
        s.score = math.floor(h.score * 100 + 0.5) / 100
        s.matched = h.title_score >= 0.5 and (h.artist_score >= 0.5 and "title+artist" or "title")
          or (h.artist_score >= 0.8 and "artist" or (h.album_score >= 0.5 and "album" or "partial"))
        r[#r + 1] = s
      end
      return r
    end
    out = local_search()
    -- Miss: the library may have changed since the last sync -> resync once and retry.
    local min_score = tonumber((config.current.fast_path or {}).min_score) or 0.6
    local indexer = require("indexer")
    if (not out[1] or out[1].score < min_score) and indexer.miss_resync_due() then
      if indexer.sync("miss") then out = local_search() end
    end
    if #out == 0 and plugins.get("fnos") and fnmusic.configured() then
      local fp = plugins.get("fnos")
      for _, s in ipairs(fnmusic.search(query, limit) or {}) do
        if not fp.playable or fp.playable(s) then
        s.raw_id = s.id
        s.id = "fnos:" .. s.id
        s.plugin = "fnos"
        s.matched = "server"
        s.score = 0.6
        out[#out + 1] = s
        end
      end
    end
  end
  if opts.online ~= false and (not out[1] or not good(out[1])) then
    local list, err = plugins.search_online(query, limit)
    if list then
      for _, s in ipairs(list) do out[#out + 1] = s end
    elseif opts.online then
      return nil, err
    end
  end
  return out
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Plays "<plugin>:<id>". Default: speaker streams from our local proxy;
-- playback.mode = "download" (or no web server) downloads to /tmp first.
function M.play_track(track)
  local name, raw = plugins.split_id(track.id)
  local p = plugins.get(name)
  if not p then return nil, "插件不可用: " .. name end
  local port = mico.web_port()
  local mode = config.get("playback.mode") or "proxy"
  local ok, err
  if port and mode ~= "download" then
    local url = "http://127.0.0.1:" .. port .. "/stream/" .. name .. "/" .. urlencode(raw)
    local token = config.get("web.token") or ""
    if token ~= "" then url = url .. "?token=" .. urlencode(token) end
    speaker.stop()
    local out, code = speaker.play_url(url)
    if code == 0 then ok = true else err = "play_url failed: " .. tostring(out) end
  else
    local url, headers = plugins.stream(name, raw)
    if not url then return nil, headers end
    speaker.max_bytes = (tonumber(config.get("playback.max_mb")) or 30) * 1024 * 1024
    ok, err = speaker.play_stream(url, headers)
  end
  if not ok then return nil, err end
  if p.on_play then pcall(p.on_play, raw) end
  track.plugin = name
  M.now_playing = track
  M.now_playing_since = os.time()
  return true
end

function M.set_shell(enabled, allow)
  if not enabled then
    mico.tool_remove("run_shell")
    return
  end
  mico.tool({
    name = "run_shell",
    description = "在音箱 Linux(BusyBox) 上执行 shell 命令，返回输出与退出码。用于查询系统状态、调用 ubus 等。",
    parameters = {
      type = "object",
      properties = {
        command = { type = "string", description = "要执行的命令" },
        timeout_s = { type = "number", description = "超时秒数，默认 10，最大 60" },
      },
      required = { "command" },
    },
    handler = function(args)
      local cmd = args.command or ""
      if allow then
        local permitted = false
        for _, p in ipairs(allow) do if cmd:match(p) then permitted = true break end end
        if not permitted then return { error = "command not allowed" } end
      end
      local t = math.min(tonumber(args.timeout_s) or 10, 60)
      local out, code, timed_out = mico.exec(cmd, { timeout_ms = t * 1000, max_bytes = 16384 })
      return { exit_code = code, timed_out = timed_out, output = truncate(out, 4000) }
    end,
  })
end

function M.register(opts)
  opts = opts or {}

  M.set_shell(opts.shell ~= false, opts.shell_allow)

  if opts.http ~= false then
    mico.tool({
      name = "http_request",
      description = "发送 HTTP 请求（类似 curl），返回状态码和响应正文（截断到 4000 字节）。",
      parameters = {
        type = "object",
        properties = {
          url = { type = "string" },
          method = { type = "string", description = "GET/POST/PUT/DELETE，默认 GET" },
          headers = { type = "object", description = "请求头键值对" },
          body = { type = "string", description = "请求正文" },
        },
        required = { "url" },
      },
      handler = function(args)
        local r = mico.http({
          method = (args.method or "GET"):upper(),
          url = args.url,
          headers = args.headers,
          body = args.body,
          timeout_ms = 20000,
        })
        if r.error then return { error = r.error } end
        return { status = r.status, body = truncate(r.body, 4000) }
      end,
    })
  end

  mico.tool({
    name = "music_search",
    description = "模糊搜索歌曲（容忍同音字/错别字）。默认先搜本地曲库，没有好结果时自动在线搜索；online=true 只在线搜索（用户明确要求在线/B站时）。返回的 id 传给 music_play。",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "歌名、歌手或两者组合，去掉“播放”“我想听”等词" },
        limit = { type = "number", description = "返回数量，默认 5" },
        online = { type = "boolean", description = "true 只在线搜索" },
      },
      required = { "query" },
    },
    handler = function(args)
      local list, err = M.search_music(args.query, tonumber(args.limit) or 5,
        args.online == true and { online = true } or nil)
      if not list then return { error = err } end
      return { results = list }
    end,
  })

  mico.tool({
    name = "music_play",
    description = "在音箱上播放歌曲。优先传 music_search 返回的 id；只传 query 时播放最佳匹配。",
    parameters = {
      type = "object",
      properties = {
        id = { type = "string", description = "歌曲 id" },
        query = { type = "string", description = "没有 id 时用于搜索" },
      },
    },
    handler = function(args)
      local track
      if args.id and args.id ~= "" then
        local name, raw = plugins.split_id(args.id)
        track = { id = name .. ":" .. raw }
        for _, h in ipairs(mico.index_search("music", args.query or "", { limit = 1 })) do
          if h.item.id == track.id then track = h.item end
        end
      elseif args.query then
        local list, err = M.search_music(args.query, 1)
        if not list then return { error = err } end
        track = list[1]
      end
      if not track then return { error = "没有找到歌曲" } end
      local ok, err = M.play_track(track)
      if not ok then return { error = err } end
      return { playing = track }
    end,
  })

  mico.tool({
    name = "music_stop",
    description = "停止播放",
    handler = function()
      speaker.stop()
      return "stopped"
    end,
  })

  mico.tool({
    name = "music_now_playing",
    description = "当前播放的歌曲信息",
    handler = function()
      return M.now_playing or { now_playing = false }
    end,
  })

end

return M
