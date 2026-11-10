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
  run("mphelper pause")
end

return M
