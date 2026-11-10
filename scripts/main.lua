-- Entry script. C++ provides the `mico` module; everything else lives here.
local config = require("config")
local speaker = require("speaker")
local plugins = require("plugins")
local web = require("web")
local agent_tools = require("agent_tools")  -- wraps mico.tool; must load before any registration

-- Effective config (defaults < config.json < env). The global `config` table
-- is read by C++ (instruction_log, poll_ms, web.listen).
local cfg = config.load()
_G.config = config.current


-- Conversation log: C++ reports LLM round trips and tool calls via on_step;
-- speaker actions (TTS, play) are wrapped here so every path records them.
function on_step(st) web.step(st) end

local function timed(kind, fn, label)
  -- (param is not called `arg`: Lua 5.1 compat reserves it in vararg functions)
  return function(x, ...)
    local t0 = mico.now_ms()
    local a, b = fn(x, ...)
    local failed = (kind == "play" and b ~= 0 and b ~= nil and a ~= true) or (a == nil and b ~= nil)
    web.step({ kind = kind, name = label, args = { [kind == "tts" and "text" or "url"] = x },
               ms = mico.now_ms() - t0, error = failed and tostring(b or a) or nil })
    return a, b
  end
end
speaker.speak = timed("tts", speaker.speak, "speak")
speaker.play_url = timed("play", speaker.play_url, "play_url")
speaker.play_stream = timed("play", speaker.play_stream, "download+play")

local tools = require("tools")
local indexer = require("indexer")

-- Called ~once per second by C++ in follow mode: startup + interval index sync.
local saver = require("saver")
function on_tick() indexer.tick(); saver.poll() end

local function apply(c)
  _G.config = c
  local lg = c.log or {}
  mico.log_config({ file = lg.file or "", max_kb = tonumber(lg.max_kb) or 512, keep = tonumber(lg.keep) or 1,
                    stderr = lg.stderr ~= false })
  speaker.dry_run = c.dry_run == true
  mico.configure({
    llm = {
      base_url = c.llm.base_url, api_key = c.llm.api_key, model = c.llm.model,
      timeout_ms = c.llm.timeout_ms, extra = c.llm.extra or {},
    },
    system_prompt = c.agent.system_prompt,
    max_steps = c.agent.max_steps,
    max_history = c.agent.max_history,
  })
  if tools.registered then tools.set_shell(c.shell.enabled ~= false) end
  plugins.reconfigure()
  agent_tools.sync()
end

apply(cfg)
plugins.load_all()  -- runs each plugin's setup (fnos -> fnmusic.setup)
config.on_change = function(c)
  apply(c)
  mico.index_clear("music")  -- re-synced lazily with the new settings
end
plugins.on_change = function() mico.index_clear("music") end


tools.register({
  shell = cfg.shell.enabled ~= false,
  http = true,
})
tools.registered = true
agent_tools.load_custom()  -- <tools.dir>/*.lua (e.g. get_time)

-- Fast path: obvious play requests skip the LLM when the match is clear.
local play_prefixes = { "我想听", "我要听", "播放", "放一首", "来一首", "放首", "来首", "听", "放", "来点" }
local filler_suffixes = { "的歌曲", "的歌", "这首歌", "歌曲", "吧", "呗" }

local trailing_punct = { "，", "。", "！", "？", ",", ".", "!", "?", " " }

-- "在B站播放X" / "在线播放X": leading source hints force online search.
local online_prefixes = { "在B站上", "在b站上", "在B站", "在b站", "去B站", "去b站", "用B站", "用b站",
  "从B站", "从b站", "在哔哩哔哩", "用哔哩哔哩", "在网上", "网上", "在线上", "在线", "B站", "b站" }

local function strip_play_request(text)
  local online = false
  for _, p in ipairs(online_prefixes) do
    if text:sub(1, #p) == p and #text > #p then
      text = text:sub(#p + 1)
      online = true
      break
    end
  end
  local changed = true
  while changed do
    changed = false
    for _, p in ipairs(trailing_punct) do
      if #text > #p and text:sub(-#p) == p then
        text = text:sub(1, -#p - 1)
        changed = true
      end
    end
  end
  for _, p in ipairs(play_prefixes) do
    if text:sub(1, #p) == p and #text > #p then
      local q = text:sub(#p + 1)
      local artist_like = false
      for _, s in ipairs(filler_suffixes) do
        if #q > #s and q:sub(-#s) == s then
          q = q:sub(1, -#s - 1)
          if s == "的歌" or s == "的歌曲" then artist_like = true end
        end
      end
      return q, online, artist_like
    end
  end
end

-- Non-song content goes straight to the online audio search.
local audio_words = { "播客", "访谈", "采访", "讲座", "演讲", "相声", "评书", "有声书", "小说", "节目", "脱口秀", "新闻", "课程" }
local function is_audio_request(q)
  for _, w in ipairs(audio_words) do
    if q:find(w, 1, true) then return true end
  end
  return false
end

-- "阿杜" alone: does it name a library artist (or look like "<歌手>的歌")?
local function looks_like_artist(q, artist_like)
  if artist_like then return true end
  pcall(tools.ensure_index)
  local hits = mico.index_search("music_artists", q, { limit = 1, min_score = 0.8 })
  return hits[1] ~= nil and hits[1].title_score >= 0.8
end

local function try_fast_play(text)
  local q, online, artist_like = strip_play_request(text)
  local fp = config.current.fast_path
  if not fp.enabled then return false end
  if not q or not plugins.any_available() then return false end
  for _, w in ipairs({ "在线", "网上", "B站", "b站", "哔哩哔哩" }) do
    local i = q:find(w, 1, true)
    if i then online = true; q = (q:sub(1, i - 1) .. q:sub(i + #w)) end
  end
  q = q:gsub("^的", ""):gsub("^上的", "")
  if q == "" then return false end
  local t0 = mico.now_ms()
  local function info(msg)
    web.step({ kind = "info", name = "fast_path", result = msg, ms = mico.now_ms() - t0 })
  end
  local kind = is_audio_request(q) and "audio" or "song"
  local opts = online and { online = true } or nil
  if kind == "audio" then
    opts = { online = true, kind = "audio" }
  elseif online and looks_like_artist(q, artist_like) then
    opts = { online = true, artist = true }
  end
  if opts and (opts.kind or opts.artist) then
    info(string.format("快路径：%s 按%s在线搜索", q, kind == "audio" and "非歌曲（kind=audio）" or "歌手（随机一首单曲）"))
  end
  local list = tools.search_music(q, 20, opts)
  local top = list and list[1]
  if not top then info("快路径：未找到 " .. q .. "，交给 LLM"); return false end
  local second = list[2]
  local pick
  if top.matched == "artist" then
    -- "来点陈奕迅的歌": random song by that artist.
    local same = {}
    for _, s in ipairs(list) do if s.matched == "artist" then same[#same + 1] = s end end
    pick = same[math.random(#same)]
  elseif top.matched == "online" then
    if not online and kind ~= "audio" then
      -- Online hits for a failed local match are often unrelated videos; let the LLM decide.
      info("快路径：本地未匹配 " .. q .. "，在线结果不自动播放，交给 LLM")
      return false
    end
    pick = top
  elseif top.score < fp.min_score then
    info(string.format("快路径：%s 最佳 %s %.2f 太低，交给 LLM", q, top.title, top.score))
    return false
  elseif top.score >= 0.8 or not second or top.score - second.score >= fp.margin then
    pick = top
  else
    info(string.format("快路径：%s 有歧义（%s %.2f / %s %.2f），交给 LLM", q, top.title, top.score,
      second.title, second.score))
    return false  -- ambiguous: let the LLM ask
  end
  info(string.format("快路径：匹配 %s/%s %.2f%s", pick.title, pick.artist ~= "" and pick.artist or "-",
    pick.score or 0, (online or kind == "audio") and ("（在线，" .. kind .. "）") or ""))
  mico.log("fast play:", q, "->", pick.title, pick.artist, pick.score)
  -- Online video titles are noisy ("【Hi-Res】…"): announce what the user asked for.
  pick.say = pick.matched == "online" and q or ((pick.artist ~= "" and (pick.artist .. "的") or "") .. pick.title)
  speaker.speak("为你播放" .. pick.say)
  if pick.matched == "online" and kind ~= "audio" then
    -- 边播边存 naming input: the saver normalizes it (LLM / library / rules).
    pick.save = { query = q, utterance = text }
  end
  local ok, err = tools.play_track(pick)
  if not ok then mico.log("play failed:", err) end
  return true, pick, err
end

-- Called by C++ for every final recognition result (and by --once).
function on_input(text, dialog_id)
  mico.log("user:", text, dialog_id)
  speaker.pause_native()
  web.begin_turn("voice", text)
  local fast, pick, perr = try_fast_play(text)
  if fast then
    web.end_turn({ route = "fast", reply = "为你播放" .. pick.say,
                   error = perr and tostring(perr) or nil })
    return
  end
  local reply, err = mico.ask(text)
  if not reply then
    mico.log("ask failed:", err)
    speaker.speak("抱歉，我暂时无法回答。")
  else
    mico.log("reply:", reply)
    speaker.speak(reply)
  end
  web.end_turn({ route = "llm", reply = reply or "", error = (not reply) and tostring(err) or nil })
end

-- Called by C++ for every web request.
web.ask = function(text)
  mico.log("web:", web.truncate(text, 300))
  web.begin_turn("web", text)
  local fast, pick, perr = try_fast_play(text)
  if fast then
    local reply = "为你播放" .. pick.say
    web.end_turn({ route = "fast", reply = reply, error = perr and tostring(perr) or nil })
    return reply
  end
  local reply, err = mico.ask(text)
  web.end_turn({ route = "llm", reply = reply or "", error = (not reply) and tostring(err) or nil })
  return reply, err
end
function on_http(method, path, query, headers, body)
  return web.handle(method, path, query, headers, body)
end

math.randomseed(os.time())
