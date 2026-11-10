-- 边播边存: saves online tracks to a WebDAV share while they play.
-- The transfer runs in a forked C++ child (mico.save_start); this module does
-- the checks, the job queue (one running, max 3 queued) and status polling.
local config = require("config")
local plugins = require("plugins")

local M = { jobs = {}, queue = {}, running = nil, next_id = 1, MAX_JOBS = 20, MAX_QUEUE = 3,
            resync_at = nil }

local function cfg() return (config.current or {}).save or {} end
local function web() return package.loaded["web"] end
local function now() return os.date("%Y-%m-%d %H:%M:%S") end

local function info(msg, failed)
  local w = web()
  if w and w.current then
    w.step({ kind = "info", name = "save", result = msg, error = failed and msg or nil })
  end
  mico.log("[save]", msg)
end

local function host(url)
  local auth = tostring(url or ""):match("^%a[%w+.-]*://([^/?#]*)")
  return auth and (auth:match("@([^@]*)$") or auth) or "?"
end
M.host = host

-- Percent-encodes everything except unreserved characters (UTF-8 safe: bytewise).
local function enc(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end
M.enc = enc

-- Encodes the path of a URL segment by segment; existing %XX escapes are kept.
function M.encode_url(url)
  local pre, path = url:match("^(%a[%w+.-]*://[^/]*)(.*)$")
  if not pre then return nil end
  path = path:gsub("[^%w%-_%.~/%%]", function(c) return string.format("%%%02X", c:byte()) end)
  path = path:gsub("%%(%X)", "%%25%1"):gsub("%%(%x%X)", "%%25%1"):gsub("%%$", "%%25")
  if path:sub(-1) ~= "/" then path = path .. "/" end
  return pre .. path
end

function M.sanitize(s)
  s = tostring(s or ""):gsub("[/\\:%*%?\"<>|%c]", "_")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Renders the filename template; "{ext}" stays for the child (content-type).
function M.render(tpl, title, artist)
  tpl = (tpl and tpl ~= "") and tpl or "{artist} - {title}.{ext}"
  local name = tpl:gsub("{(%a+)}", function(k)
    if k == "title" then return M.sanitize(title) end
    if k == "artist" then return M.sanitize(artist) end
    if k == "ext" then return "\1" end
  end)
  -- Missing artist: drop the dangling separator ("- 晴天.m4a" -> "晴天.m4a").
  name = name:gsub("^[%s%-_]+", ""):gsub("[%s%-_]+(%.?\1)", "%1"):gsub("[%s%-_]+$", "")
  name = M.sanitize(name:gsub("\1", "{ext}"))
  return name
end

local function lower(s) return tostring(s or ""):lower() end  -- ASCII only: byte-safe for UTF-8
local function squash(s) return lower(s):gsub("[%s%p]", "") end

-- Does `hay` contain `needle`? Plain substring, then pinyin (homophones).
function M.contains(hay, needle)
  if not needle or needle == "" then return true end
  local h, n = squash(hay), squash(needle)
  if n == "" or h:find(n, 1, true) then return true end
  local ph, pn = squash(mico.pinyin(hay)), squash(mico.pinyin(needle))
  return pn ~= "" and ph:find(pn, 1, true) ~= nil
end

function M.keyword_hit(title)
  local t = lower(title)
  for kw in tostring(cfg().skip_keywords or ""):gsub("，", ","):gmatch("[^,]+") do
    kw = lower(kw):gsub("^%s+", ""):gsub("%s+$", "")
    if kw ~= "" and t:find(kw, 1, true) then return kw end
  end
end

-- Track-only checks (before naming): duration, keywords. nil = ok, else reason.
function M.check_track(track)
  if track.kind == "audio" then return "非歌曲内容不保存" end
  local c = cfg()
  local d = tonumber(track.duration)
  if d and d > 0 then
    if d < (tonumber(c.min_duration_s) or 0) then return "时长过短 " .. d .. "s" end
    local mx = tonumber(c.max_duration_s) or 0
    if mx > 0 and d > mx then return "时长过长 " .. d .. "s" end
  end
  local kw = M.keyword_hit(track.title)
  if kw then return "标题含关键词 " .. kw end
end

-- Does the result match the requested title/artist? (rule-based naming only)
function M.check_match(track, title, artist)
  if cfg().require_match == false then return end
  if not title or title == "" then return "未知歌名" end
  if not M.contains(track.title, title) then return "标题不匹配 " .. title end
  if artist and artist ~= "" and not M.contains((track.title or "") .. " " .. (track.artist or ""), artist) then
    return "歌手不匹配 " .. artist
  end
end

-- Returns nil when the track may be saved, else the skip reason.
function M.check(track, title, artist)
  return M.check_track(track) or M.check_match(track, title, artist)
end

-- Library spelling of an artist name (fuzzy, >= 0.8 both ways), or nil.
function M.library_artist(name)
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return nil end
  local best
  for _, h in ipairs(mico.index_search("music_artists", name, { limit = 5, min_score = 0.3 })) do
    local sc = math.min(h.title_score or 0, h.query_score or 0)
    if sc >= 0.8 and (not best or sc > best.sc) then best = { sc = sc, name = h.item.name or h.item.title } end
  end
  return best and best.name
end

-- Replaces each artist (joined with 、) by its library spelling. Returns artist, changed.
function M.correct_artist(artist)
  if not artist or artist == "" then return artist, false end
  local parts, changed = {}, false
  for a in (artist:gsub("、", "\1")):gmatch("[^\1]+") do
    local lib = M.library_artist(a)
    if lib and lib ~= a then changed = true; a = lib end
    parts[#parts + 1] = a
  end
  return table.concat(parts, "、"), changed
end

-- Rule-based naming: explicit title/artist, else the query; "歌手的歌名" is only
-- split when the left part is a known artist (library / result title / uploader).
function M.rule_name(track, opts)
  local title, artist = opts.title, opts.artist
  if (not title or title == "") and opts.query and opts.query ~= "" then
    local q = opts.query
    title = q
    if not M.contains(track.title, q) then
      local a, t = q:match("^(.-)的(.+)$")
      if a and a ~= "" and t ~= "" and (not artist or artist == "") then
        if M.library_artist(a) or M.contains((track.title or "") .. " " .. (track.artist or ""), a) then
          artist, title = a, t
        end
      end
    end
  end
  return title, artist
end

-- Extracts the first {...} JSON object from an LLM reply (```json fences ok).
function M.parse_json(text)
  text = tostring(text or ""):gsub("```%a*", "")
  local i = text:find("{", 1, true)
  if not i then return nil end
  local depth, instr, esc = 0, false, false
  for j = i, #text do
    local ch = text:sub(j, j)
    if instr then
      if esc then esc = false elseif ch == "\\" then esc = true elseif ch == '"' then instr = false end
    elseif ch == '"' then instr = true
    elseif ch == "{" then depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        local ok, v = pcall(mico.json_decode, text:sub(i, j))
        if ok and type(v) == "table" then return v end
        return nil
      end
    end
  end
end

local function fmt_dur(d)
  d = tonumber(d)
  if not d or d <= 0 then return "未知" end
  return string.format("%d:%02d", math.floor(d / 60), math.floor(d % 60))
end

-- Asks the LLM for clean {artist, title, confident}. Returns table or nil, err.
function M.llm_name(track, opts)
  local w = web()
  local utter = opts.utterance or (w and w.current and w.current.user) or ""
  local prompt = table.concat({
    "用户想听一首歌，我们从在线音乐源找到了一个结果，现在要把它保存为音乐文件，请给出规范的歌手和歌名。",
    "用户原话：" .. tostring(utter),
    "解析出的查询：" .. tostring(opts.query or opts.title or ""),
    (opts.artist and opts.artist ~= "") and ("用户说的歌手：" .. opts.artist) or "",
    "在线结果标题（原始）：" .. tostring(track.title or ""),
    (track.artist and track.artist ~= "") and ("上传者：" .. track.artist) or "",
    "时长：" .. fmt_dur(track.duration),
    "",
    "要求：",
    "1. title 为官方歌名，去掉所有修饰（如【】、《》、Live、MV、Hi-Res、无损、4K、高音质、完整版等）；",
    "2. artist 为原唱歌手的规范名称，修正语音识别的同音错字（如 周杰轮→周杰伦），多位歌手用“、”连接；",
    "3. 如果结果看起来是翻唱、合集、串烧、无关视频，或你不确定这首歌，confident 为 false；",
    '只返回 JSON，不要任何其他文字：{"artist":"","title":"","confident":true}',
  }, "\n"):gsub("\n\n+", "\n\n")
  local reply, err = mico.complete({
    messages = { { role = "user", content = prompt } },
    max_tokens = 200,
    timeout_ms = tonumber(cfg().normalize_timeout_ms) or 8000,
  })
  if not reply then return nil, err end
  local j = M.parse_json(reply)
  if not j then return nil, "无法解析：" .. reply:sub(1, 100) end
  local function str(v) return type(v) == "string" and (v:gsub("^%s+", ""):gsub("%s+$", "")) or "" end
  return { artist = str(j.artist), title = str(j.title), confident = j.confident ~= false }
end

local function record(job)
  table.insert(M.jobs, job)
  while #M.jobs > M.MAX_JOBS do table.remove(M.jobs, 1) end
end

local function finish(job, status, reason)
  job.status = status
  job.reason = reason ~= "" and reason or nil
  job.finished = now()
  job.ms = math.floor(mico.now_ms() - job.t0)
  if status == "done" then
    mico.log("[save]", "done #" .. job.id, job.bytes .. " bytes", job.ms .. " ms",
      "-> " .. tostring((config.current.save or {}).webdav_url or "") .. job.name)
  else
    mico.log("[save]", status .. " #" .. job.id, job.name, reason or "")
  end
  if status == "done" then M.resync_at = mico.now_ms() + 60000; M.mark_miss() end
end

-- Lets the next local-search miss resync right away (the NAS has a new file).
function M.mark_miss()
  local ix = package.loaded["indexer"]
  if ix then ix.force_miss = true end
end

local function start(job)
  local c = cfg()
  local url, headers = plugins.stream(job.plugin, job.raw_id)
  if not url then finish(job, "failed", "无法获取音频地址: " .. tostring(headers)); return end
  job.status_path = string.format("/tmp/mico-save-%d-%d.st", math.floor(mico.now_ms()) % 100000000, job.id)
  local pid, err = mico.save_start({
    src_url = url, src_headers = headers, dav_base = job.dav_base, name = job.enc_name,
    username = c.username or "", password = c.password or "",
    max_bytes = (tonumber(c.max_size_mb) or 200) * 1024 * 1024,
    buffer_kb = tonumber(config.get("playback.buffer_kb")) or 1024,
    status_path = job.status_path,
  })
  if not pid then finish(job, "failed", err); return end
  job.pid = pid
  job.status = "running"
  job.t0 = mico.now_ms()
  job.started = now()
  job.logged_mb = 0
  M.running = job
  mico.log("[save]", "started #" .. job.id, job.name, "from " .. host(url), "to " .. host(c.webdav_url))
end

local function read_status(job)
  local f = io.open(job.status_path, "r")
  if not f then return end
  local line = f:read("*l")
  f:close()
  if not line then return end
  local st, bytes, total, reason = line:match("^(%a+)\t(%-?%d+)\t(%-?%d+)\t([^\t]*)")
  if not st then return end
  job.bytes = tonumber(bytes) or 0
  local t = tonumber(total)
  job.total = (t and t >= 0) and t or nil
  return st, reason
end

-- Called from on_tick and the jobs API.
function M.poll()
  local job = M.running
  if job then
    local exited = mico.proc_reap(job.pid)
    local st, reason = read_status(job)
    local mb10 = math.floor((job.bytes or 0) / (10 * 1024 * 1024))
    if mb10 > (job.logged_mb or 0) then
      job.logged_mb = mb10
      mico.log("[save]", "progress #" .. job.id, job.bytes .. (job.total and ("/" .. job.total) or "") .. " bytes")
    end
    if exited then
      if st and st ~= "running" then finish(job, st, reason) else finish(job, "failed", "子进程异常退出") end
      os.remove(job.status_path)
      M.running = nil
    end
  end
  if not M.running and #M.queue > 0 then start(table.remove(M.queue, 1)) end
  if M.resync_at and mico.now_ms() >= M.resync_at then
    M.resync_at = nil
    local ix = package.loaded["indexer"]
    if ix and #plugins.of_type("local") > 0 then ix.sync("save") end
  end
end

-- Entry point after an online track started playing. opts: {title, artist}.
function M.maybe_save(track, opts)
  local c = cfg()
  if c.enabled ~= true then return end
  opts = opts or {}
  local name, raw = plugins.split_id(track.id)
  local p = plugins.get(name)
  if not p or p.type ~= "online" then return end
  local base = M.encode_url(c.webdav_url or "")
  if not base then info("边播边存：未配置 WebDAV 地址", true); return end
  local reason = M.check_track(track)
  local title, artist, source, llm_ms, llm_err
  if not reason and c.normalize ~= false then
    local t0 = mico.now_ms()
    local r, err = M.llm_name(track, opts)
    llm_ms = math.floor(mico.now_ms() - t0)
    if r and not r.confident then
      reason, source = "大模型判断不是原曲/不确定", "llm"
      title, artist = r.title, r.artist
    elseif r and r.title ~= "" then
      title, artist, source = r.title, r.artist, "llm"
    else
      llm_err = err or "未给出歌名"
    end
  end
  if not source then
    title, artist = M.rule_name(track, opts)
    source = "rule"
    reason = reason or M.check_match(track, title, artist)
  end
  if not reason then
    local fixed, changed = M.correct_artist(artist)
    if changed then artist, source = fixed, source .. "+library" end
    if c.require_artist ~= false and (not artist or artist == "") then reason = "未确定歌手" end
  end
  local note = string.format("（命名来源 %s：%s / %s%s%s", source, (artist and artist ~= "") and artist or "-",
    (title and title ~= "") and title or "-", llm_ms and ("，LLM " .. llm_ms .. " ms") or "",
    llm_err and ("；LLM 失败：" .. tostring(llm_err):sub(1, 120)) or "") .. "）"
  local display_title = (title and title ~= "") and title or track.title
  local display = M.render(c.filename, display_title, artist or "")
  local job = { id = M.next_id, name = (display:gsub("{ext}", "*")), plugin = name, raw_id = raw,
                status = "queued", bytes = 0, started = now(), t0 = mico.now_ms(), ms = 0 }
  M.next_id = M.next_id + 1
  if reason then
    record(job)
    finish(job, "skipped", reason)
    info("边播边存：跳过（" .. reason .. "）" .. note)
    return job
  end
  job.dav_base = base
  job.enc_name = enc(display):gsub("%%7Bext%%7D", "{ext}")
  local qmax = math.floor(tonumber(c.queue_size) or 3)
  if M.running and #M.queue >= qmax then
    info("边播边存：队列已满，放弃 " .. job.name .. note, true)
    return
  end
  record(job)
  M.queue[#M.queue + 1] = job
  mico.log("[save]", "queued #" .. job.id, job.name, "(queue " .. #M.queue .. ")")
  info("边播边存：开始保存 " .. job.name .. note)
  M.poll()
  return job
end

local function json_array(t) return setmetatable(t, { __jsontype = "array" }) end

function M.list()
  M.poll()
  local out = {}
  for i = #M.jobs, 1, -1 do
    local j = M.jobs[i]
    local ms = j.ms
    if j.status == "running" then ms = math.floor(mico.now_ms() - j.t0) end
    out[#out + 1] = { id = j.id, name = j.name, status = j.status, reason = j.reason, bytes = j.bytes,
                      total = j.total, started = j.started, finished = j.finished, ms = ms }
  end
  return json_array(out)
end

function M.test()
  local c = cfg()
  local base = M.encode_url(c.webdav_url or "")
  if not base then return { ok = false, status = 0, error = "未配置 WebDAV 地址" } end
  return mico.dav_test({ url = base, username = c.username or "", password = c.password or "" })
end

return M
