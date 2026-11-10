-- Automatic local-library index sync: startup / interval (driven by on_tick)
-- and "miss" resync when a local search finds nothing good.
local plugins = require("plugins")
local config = require("config")

local M = {
  INDEX = "music",
  status = { last_sync_time = false, last_sync_ms = false, tracks = 0, last_error = false,
             next_sync_time = false, syncing = false, last_reason = false },
  last_sync_at = nil,  -- mico.now_ms() of last attempt (success or failure)
  started = false,
}

local function cfg() return (config.current or {}).index or {} end
local function fmt(t) return t and os.date("%Y-%m-%d %H:%M:%S", t) or false end

-- Records a sync event in the conversation log ("info" step) and the process log.
local function record(reason, ok, msg, ms)
  mico.log("index sync (" .. reason .. "):", msg)
  local web = package.loaded["web"]
  if not web then return end
  local st = { kind = "info", name = "index_sync", result = msg, ms = ms, error = (not ok) and msg or nil }
  if web.current then
    web.step(st)
  else
    web.begin_turn("system", "索引同步（" .. reason .. "）")
    web.step(st)
    web.end_turn({ route = "info", reply = msg, error = (not ok) and msg or nil })
  end
end

local function schedule(now)
  local iv = tonumber(cfg().sync_interval_min) or 0
  M.status.next_sync_time = (iv > 0) and fmt(now + math.floor(iv * 60)) or false
end

-- Rebuilds the index from enabled local plugins. Failure keeps the old index.
function M.sync(reason)
  reason = reason or "manual"
  local now = os.time()
  local t0 = mico.now_ms()
  M.last_sync_at = t0
  M.force_miss = false
  M.status.syncing = true
  local n, err = plugins.sync_index(M.INDEX)
  M.status.syncing = false
  local ms = math.floor(mico.now_ms() - t0)
  M.status.last_sync_time = fmt(now)
  M.status.last_sync_ms = ms
  M.status.last_reason = reason
  M.status.tracks = mico.index_size(M.INDEX)
  schedule(now)
  if not n then
    M.status.last_error = tostring(err)
    record(reason, false, "索引同步失败（保留旧索引 " .. M.status.tracks .. " 首）：" .. tostring(err), ms)
    return nil, err
  end
  M.status.last_error = err and tostring(err) or false  -- partial errors
  record(reason, true, string.format("索引同步完成：%d 首，%d ms%s", n, ms, err and ("；部分失败：" .. err) or ""), ms)
  return n
end

-- Called ~1/s by C++ (follow mode only).
function M.tick()
  local now = os.time()
  if not M.started then
    M.started = true
    if cfg().sync_on_start ~= false and #plugins.of_type("local") > 0 then
      M.sync("startup")
    else
      schedule(now)
    end
    return
  end
  local iv = tonumber(cfg().sync_interval_min) or 0
  if iv <= 0 then M.status.next_sync_time = false; return end
  if #plugins.of_type("local") == 0 then return end
  if not M.last_sync_at then M.last_sync_at = mico.now_ms(); schedule(now) end
  if mico.now_ms() - M.last_sync_at >= iv * 60000 then M.sync("interval") end
end

-- True when a miss may trigger a resync (last attempt older than miss_resync_min).
function M.miss_resync_due()
  local m = tonumber(cfg().miss_resync_min) or 0
  if #plugins.of_type("local") == 0 then return false end
  if M.force_miss then return true end  -- a file was just saved to the NAS
  if m <= 0 then return false end
  return not M.last_sync_at or (mico.now_ms() - M.last_sync_at) >= m * 60000
end

-- Lazy first sync when the index is empty.
function M.ensure()
  if mico.index_size(M.INDEX) > 0 or #plugins.of_type("local") == 0 then return true end
  local n, err = M.sync("lazy")
  if not n then return nil, err end
  return true
end

function M.info()
  local s = {}
  for k, v in pairs(M.status) do s[k] = v end
  s.tracks = mico.index_size(M.INDEX)
  return s
end

return M
