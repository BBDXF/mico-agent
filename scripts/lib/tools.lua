-- Tools exposed to the LLM. register(opts) installs them via mico.tool.
local fnmusic = require("fnmusic")
local speaker = require("speaker")
local plugins = require("plugins")
local config = require("config")

local M = { online_seen = {}, online_seen_n = 0 }  -- recent online results by id (title/duration)

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

-- Decision notes: process log + conversation info step (when the web module is loaded).
function M.note(msg)
  mico.log("[online]", msg)
  local web = package.loaded["web"]
  if web and web.step then pcall(web.step, { kind = "info", name = "online", result = msg }) end
end

local function lower(s) return tostring(s or ""):lower() end

local function keyword_hit(title, list)
  local t = lower(title)
  for kw in (tostring(list or ""):gsub("，", ",")):gmatch("[^,]+") do
    kw = kw:gsub("^%s+", ""):gsub("%s+$", "")
    if kw ~= "" and t:find(lower(kw), 1, true) then return kw end
  end
end

-- Ranks items by fuzzy match (temp index) then play count. Returns copies with .score.
local function rank(items, query, min_score)
  if #items == 0 then return {} end
  local ix = "online_tmp"
  mico.index_clear(ix)
  local tagged = {}
  for i, t in ipairs(items) do
    tagged[i] = { title = t.title, artist = t.artist or "", album = t.album or "", n = i }
  end
  mico.index_add(ix, tagged)
  local scores = {}
  for _, h in ipairs(mico.index_search(ix, query, { limit = #items, min_score = 0 })) do
    scores[h.item.n] = h.score
  end
  mico.index_clear(ix)
  local out = {}
  for i, t in ipairs(items) do
    local sc = scores[i] or 0
    if not min_score or sc >= min_score then
      t.score = math.floor(sc * 100 + 0.5) / 100
      out[#out + 1] = t
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (tonumber(a.play) or 0) > (tonumber(b.play) or 0)
  end)
  return out
end

-- Online search with song/audio filtering.
-- opts.kind = "song" (default) | "audio"; opts.artist = true: artist-only (pick one random single).
function M.online_search(query, limit, opts)
  opts = opts or {}
  local kind = opts.kind == "audio" and "audio" or "song"
  local oc = config.current.online or {}
  if kind == "audio" then
    local list, err = plugins.search_online(query, 20, { kind = "audio" })
    if not list then return nil, err end
    local maxs = tonumber(oc.audio_max_s) or 14400
    local keep = {}
    for _, t in ipairs(list) do
      local d = tonumber(t.duration) or 0
      if d == 0 or (d >= 60 and d <= maxs) then t.kind = "audio"; keep[#keep + 1] = t end
    end
    local out = rank(keep, query)
    M.note(string.format("在线搜索（非歌曲）%s：%d 条结果，%d 条时长符合（60–%d 秒）%s", query, #list, #keep, maxs,
      out[1] and ("，选 " .. out[1].title .. " " .. (out[1].duration or 0) .. "s") or ""))
    while #out > limit do table.remove(out) end
    return out
  end
  local mins, maxs = tonumber(oc.song_min_s) or 90, tonumber(oc.song_max_s) or 480
  local skip = oc.skip_keywords or ""
  local sq = opts.artist and (query .. " 歌曲") or query
  local list, err = plugins.search_online(sq, 20, { kind = "song" })
  if not list then return nil, err end
  local singles, multi, n_kw, n_dur = {}, {}, 0, 0
  for _, t in ipairs(list) do
    local d = tonumber(t.duration) or 0
    local kw = keyword_hit(t.title, skip)
    if d > maxs or (t.pages and t.pages > 1) or (kw and d > mins) then multi[#multi + 1] = t end
    if kw then n_kw = n_kw + 1
    elseif d < mins or d > maxs then n_dur = n_dur + 1
    else t.kind = "song"; singles[#singles + 1] = t end
  end
  local summary = string.format("在线搜索歌曲 %s：%d 条结果，关键词排除 %d，时长不符（%d–%d 秒）%d，单曲 %d",
    sq, #list, n_kw, mins, maxs, n_dur, #singles)
  if opts.artist then
    local cand = {}
    for _, t in ipairs(singles) do
      local r = rank({ { title = t.title .. " " .. (t.artist or ""), artist = "" } }, query)
      if lower(t.title):find(lower(query), 1, true) or lower(t.artist):find(lower(query), 1, true)
          or (r[1] and r[1].score >= 0.6) then
        cand[#cand + 1] = t
      end
    end
    if #cand == 0 then M.note(summary .. "；没有提到歌手 " .. query .. " 的单曲"); return {} end
    local pick = cand[math.random(#cand)]
    pick.score = 1
    M.note(summary .. string.format("；歌手 %s 符合 %d 首，随机选 %s（%ds）", query, #cand, pick.title, pick.duration or 0))
    return { pick }
  end
  local out = rank(singles, query)
  if #out > 0 then
    M.note(summary .. string.format("；选 %s（%ds，匹配 %.2f）", out[1].title, out[1].duration or 0, out[1].score))
    while #out > limit do table.remove(out) end
    return out
  end
  -- Fallback: a matching part inside multi-part videos / collections. The song
  -- search only returns short videos, so look for long ones once more.
  local long = plugins.search_online(sq, 20, { kind = "song", long = true }) or {}
  local seen = {}
  for _, t in ipairs(multi) do seen[t.id] = true end
  for _, t in ipairs(long) do
    if not seen[t.id] and ((tonumber(t.duration) or 0) > maxs or (t.pages and t.pages > 1)) then
      seen[t.id] = true
      multi[#multi + 1] = t
    end
  end
  multi = rank(multi, query)
  for i = 1, math.min(3, #multi) do
    local v = multi[i]
    local parts = plugins.parts(v.plugin, v.raw_id) or {}
    local ok = {}
    for _, pt in ipairs(parts) do
      local d = tonumber(pt.duration) or 0
      if d >= mins and d <= maxs and not keyword_hit(pt.title, skip) then
        pt.album = ""  -- match on the part title only
        ok[#ok + 1] = pt
      end
    end
    local hits = rank(ok, query, 0.6)
    if hits[1] then
      local h = hits[1]
      h.kind = "song"
      h.album = v.title
      M.note(summary .. string.format("；从 %s 的 %d 个分P/合集条目中选 %s（%ds，匹配 %.2f，id %s）",
        v.title, #parts, h.title, h.duration or 0, h.score, h.id))
      return { h }
    end
  end
  M.note(summary .. string.format("；分P/合集 %d 个也没有符合的，放弃", math.min(3, #multi)))
  return {}
end

-- Fuzzy search over the local index; falls back to the 飞牛 server search,
-- then to online plugins when nothing local is good (score < 0.6).
-- opts.online: true = only online, false = never online.
-- opts.kind: "song" (default) | "audio" (podcast etc.: online only, no song filters).
-- opts.artist: artist-only online request (one random single).
function M.search_music(query, limit, opts)
  limit = limit or 5
  opts = opts or {}
  local out = {}
  if opts.kind == "audio" then opts.online = true end
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
    local list, err = M.online_search(query, limit, opts)
    if list then
      for _, s in ipairs(list) do
        out[#out + 1] = s
        M.online_seen[s.id] = s
        M.online_seen_n = M.online_seen_n + 1
      end
      if M.online_seen_n > 200 then M.online_seen, M.online_seen_n = {}, 0 end
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
  local pt = p.type
  if pt == "online" then
    local ok2, e2 = pcall(function() require("saver").maybe_save(track, track.save) end)
    if not ok2 then mico.log("save:", e2) end
  end
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
    description = "模糊搜索歌曲（容忍同音字/错别字）。默认先搜本地曲库，没有好结果时自动在线搜索；online=true 只在线搜索（用户明确要求在线/B站时）。播客、访谈、讲座、相声、评书、有声书、节目、脱口秀、新闻等非歌曲内容传 kind=\"audio\"（只在线搜索，不限歌曲时长）。返回的 id 传给 music_play。",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "歌名、歌手或两者组合，去掉“播放”“我想听”等词" },
        limit = { type = "number", description = "返回数量，默认 5" },
        online = { type = "boolean", description = "true 只在线搜索" },
        kind = { type = "string", enum = { "song", "audio" }, description = "song（默认，歌曲）或 audio（播客/访谈/讲座/相声/有声书等长音频）" },
      },
      required = { "query" },
    },
    handler = function(args)
      local list, err = M.search_music(args.query, tonumber(args.limit) or 5,
        { online = args.online == true or nil, kind = args.kind == "audio" and "audio" or nil })
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
        title = { type = "string", description = "可选：用户要听的歌名（干净的歌名，用于在线歌曲保存命名）" },
        artist = { type = "string", description = "可选：用户说的歌手名" },
      },
    },
    handler = function(args)
      local track
      if args.id and args.id ~= "" then
        local name, raw = plugins.split_id(args.id)
        track = { id = name .. ":" .. raw }
        local seen = M.online_seen[track.id]
        if seen then track = {}; for k, v in pairs(seen) do track[k] = v end end
        for _, h in ipairs(mico.index_search("music", args.query or "", { limit = 1 })) do
          if h.item.id == track.id then track = h.item end
        end
      elseif args.query then
        local list, err = M.search_music(args.query, 1)
        if not list then return { error = err } end
        track = list[1]
      end
      if not track then return { error = "没有找到歌曲" } end
      track.save = { title = args.title, artist = args.artist, query = args.query }
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
