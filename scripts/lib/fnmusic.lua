-- 飞牛音乐 (trim.music) private API client: /music/api/v1/*.
-- Auth: password-login (sha256 password) -> userToken, sent as Cookie
-- music-token=<token>. The authx signature header is added only when both
-- authx_prefix and client_key are configured (it may not be enforced for app
-- clients; verify on your NAS).
local M = {}

M.cfg = {
  base_url = "",      -- http://<NAS>:5666
  username = "",
  password = "",
  device_id = "",     -- 32 hex chars; generated from username if empty
  authx_prefix = "",
  client_key = "",
  timeout_ms = 15000,
}
M.token = nil

local API = "/music/api/v1"

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function authx(path, query, body)
  local c = M.cfg
  if c.authx_prefix == "" or c.client_key == "" then return nil end
  local payload
  if query then
    local parts = {}
    for _, k in ipairs(sorted_keys(query)) do parts[#parts + 1] = k .. "=" .. tostring(query[k]) end
    payload = table.concat(parts, "&")
  else
    payload = body or ""
  end
  local nonce = tostring(math.random(100000, 999999))
  local ts = string.format("%d", os.time() * 1000)
  local sign = mico.md5(table.concat({ c.authx_prefix, path, nonce, ts, mico.md5(payload), c.client_key }, "_"))
  return "nonce=" .. nonce .. "&timestamp=" .. ts .. "&sign=" .. sign
end

function M.setup(cfg)
  for k, v in pairs(cfg or {}) do M.cfg[k] = v end
  M.cfg.base_url = (M.cfg.base_url or ""):gsub("/+$", "")
  if M.cfg.device_id == "" then M.cfg.device_id = mico.md5("mico-agent:" .. (M.cfg.username or "")) end
  M.token = nil
end

function M.configured()
  return M.cfg.base_url ~= "" and M.cfg.username ~= ""
end

-- Low-level call. method "GET" uses query, others send body as JSON.
local function call(method, path, params, with_auth)
  local full = API .. path
  local url = M.cfg.base_url .. full
  local headers = { Accept = "application/json", ["Accept-Language"] = "zh-CN" }
  local body, query
  if method == "GET" then
    query = params or {}
    local parts = {}
    for _, k in ipairs(sorted_keys(query)) do parts[#parts + 1] = urlencode(k) .. "=" .. urlencode(query[k]) end
    if #parts > 0 then url = url .. "?" .. table.concat(parts, "&") end
  else
    body = mico.json_encode(params or {})
    headers["Content-Type"] = "application/json"
  end
  local ax = authx(full, query, body)
  if ax then headers.authx = ax end
  if with_auth and M.token then headers.Cookie = "music-token=" .. M.token end
  local resp = mico.http({ method = method, url = url, headers = headers, body = body, timeout_ms = M.cfg.timeout_ms })
  if resp.error then return nil, "http: " .. resp.error, 0 end
  local j = mico.json_decode(resp.body)
  if not j then return nil, "http " .. resp.status .. ": " .. resp.body:sub(1, 200), resp.status end
  if j.code ~= 0 then return nil, "fn code " .. tostring(j.code) .. ": " .. tostring(j.msg), resp.status, j.code end
  return j.data, nil, resp.status
end

function M.login()
  if not M.configured() then return nil, "飞牛音乐未配置" end
  local data, err = call("POST", "/user/password-login", {
    username = M.cfg.username,
    password = mico.sha256(M.cfg.password),
    deviceId = M.cfg.device_id,
  }, false)
  if not data then return nil, err end
  if not data.userToken or data.userToken == "" then return nil, "login: no userToken" end
  M.token = data.userToken
  return true
end

-- Authenticated request; logs in lazily and retries once on auth failure.
function M.request(method, path, params)
  if not M.token then
    local ok, err = M.login()
    if not ok then return nil, err end
  end
  local data, err, status = call(method, path, params, true)
  if not data and (status == 401 or status == 403 or (err and err:find("token"))) then
    M.token = nil
    local ok, lerr = M.login()
    if not ok then return nil, lerr end
    data, err = call(method, path, params, true)
  end
  return data, err
end

-- Compact track for the LLM and the fuzzy index.
function M.simplify(t)
  local names = {}
  for _, a in ipairs(t.artists or {}) do names[#names + 1] = a.name end
  return {
    id = t.guid,
    title = t.title,
    artist = table.concat(names, "/"),
    album = t.album and t.album.name or "",
    duration = t.duration,
    favorite = t.isFavorite or nil,
    -- Field names vary between trim.music versions; used to skip formats the
    -- speaker can't decode (see plugins/fnos.lua).
    format = t.format or t.fileFormat or t.fileType or t.container or nil,
    codec = t.codec or t.audioCodec or nil,
    path = t.path or t.filePath or t.fileName or nil,
  }
end

local function simplify_list(data)
  local out = {}
  for _, t in ipairs((data and data.list) or {}) do out[#out + 1] = M.simplify(t) end
  return out
end

-- Server-side search (exact-ish; use the fuzzy index for ASR text).
function M.search(query, size)
  local data, err = M.request("GET", "/search/track", { q = query, page = 1, size = size or 20 })
  if not data then return nil, err end
  return simplify_list(data)
end

function M.tracks(page, size)
  local data, err = M.request("GET", "/track/list", { page = page or 1, size = size or 50 })
  if not data then return nil, err end
  return simplify_list(data), data.total
end

function M.report_play(track_id)
  return M.request("POST", "/event/report", { trackGUID = track_id })
end

-- Direct stream URL. It requires the Cookie header, so the speaker plays it
-- through the local stream proxy (/stream/fnos/<guid>).
function M.stream_url(track_id)
  return M.cfg.base_url .. API .. "/track/stream?guid=" .. urlencode(track_id),
    { Cookie = "music-token=" .. (M.token or "") }
end

return M
