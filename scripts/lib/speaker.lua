-- Speaker actions. On the device these call the stock XiaoAi tools; with
-- dry_run = true (default off-device) they only log, so the agent can be
-- tested on a PC.
local M = {}

M.dry_run = os.getenv("MICO_DRY_RUN") == "1"

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(cmd)
  if M.dry_run then
    mico.log("[dry-run]", cmd)
    return "", 0
  end
  return mico.exec(cmd .. " 2>&1", { timeout_ms = 30000 })
end

-- Blocking TTS through the stock script (interruptible by killing miplayer).
function M.speak(text)
  if text == nil or text == "" then return end
  return run("/usr/sbin/tts_play.sh " .. sh_quote(text))
end

function M.play_url(url)
  local arg = mico.json_encode({ url = url, type = 1 })
  return run("ubus call mediaplayer player_play_url " .. sh_quote(arg))
end

-- OH2P/LX06 report 1=playing and 2=paused through the stock mediaplayer ubus.
-- Return nil when this firmware exposes a different response.
function M.play_status()
  if M.dry_run then return nil end
  local out, code = mico.exec("ubus call mediaplayer player_get_play_status 2>/dev/null", {
    timeout_ms = 500, max_bytes = 2048,
  })
  if code ~= 0 or type(out) ~= "string" then return nil end
  local ok, data = pcall(mico.json_decode, out)
  if not ok or type(data) ~= "table" then return nil end
  local status = data.status or data.state
  if status == 1 or status == "1" or status == "playing" then return "playing" end
  if status == 2 or status == "2" or status == "paused" then return "paused" end
  if status == 0 or status == "0" or status == "stopped" or status == "idle" then return "stopped" end
  return nil
end

-- Opt-in fallback (playback.mode = "download"): the stock player only takes a
-- bare URL, so fetch the file to /tmp (RAM) first and play it locally. The
-- default path is the built-in stream proxy (see tools.play_track).
M.cache_file = "/tmp/mico_play"
M.max_bytes = 30 * 1024 * 1024

local function remove_cache()
  if M.dry_run then
    mico.log("[dry-run]", "rm -f " .. M.cache_file)
  else
    os.remove(M.cache_file)
  end
end

function M.play_stream(url, headers)
  local h = ""
  for k, v in pairs(headers or {}) do h = h .. " -H " .. sh_quote(k .. ": " .. v) end
  local fetch = "curl -sfL --max-filesize " .. M.max_bytes .. h .. " -o " .. M.cache_file .. " " .. sh_quote(url)
  M.stop()  -- also deletes the previous cache file
  if M.dry_run then
    mico.log("[dry-run]", fetch)
    mico.log("[dry-run]", "miplayer -f " .. M.cache_file)
    return true
  end
  local out, code = mico.exec(fetch, { timeout_ms = 60000 })
  if code ~= 0 then
    remove_cache()
    return nil, "download failed: " .. out
  end
  -- A native XiaoAi answer may have arrived while the file was downloading.
  M.pause_native()
  mico.exec("(miplayer -f " .. M.cache_file .. " >/dev/null 2>&1 &)")
  return true
end

function M.stop()
  run("ubus call mediaplayer player_play_operation '{\"action\":\"stop\"}'")
  run("killall miplayer tts_play.sh")
  remove_cache()
end

-- Pause the stock XiaoAi answer before we speak (best effort).
function M.pause_native()
  if M.dry_run then return run("mphelper pause") end

  local helper
  for _, path in ipairs({ "/usr/bin/mphelper", "/usr/sbin/mphelper", "/bin/mphelper", "/sbin/mphelper" }) do
    local _, code = mico.exec("test -x " .. sh_quote(path), { timeout_ms = 1000, max_bytes = 1024 })
    if code == 0 then helper = path; break end
  end
  if not helper then
    local out, code = mico.exec("command -v mphelper 2>/dev/null", { timeout_ms = 1000, max_bytes = 1024 })
    if code == 0 then helper = tostring(out or ""):match("^%s*(.-)%s*$") end
  end
  if not helper or helper == "" then
    mico.log("[speaker] mphelper is unavailable; native playback cannot be paused")
    return nil, "mphelper unavailable"
  end
  local out, code = run(helper .. " pause")
  if code ~= 0 then
    mico.log("[speaker] mphelper pause failed:", tostring(out or ""))
    return nil, "mphelper pause failed"
  end
  return true
end

return M
