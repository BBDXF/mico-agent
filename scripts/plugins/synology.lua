-- Synology Audio Station local music library.
-- Credentials should be supplied through MICO_SYNO_* environment variables,
-- not committed in this source file.
local M = {
  name = "synology",
  type = "local",
  version = "1.0",
  description = "群晖 DSM Audio Station 曲库与串流",
}

M.config = {
  url = "",
  user = "",
  pass = "",
  otp = "",
  device_name = "mico-agent",
  device_id = "",
  device_id_file = "/data/mico-agent/synology.device_id",
  entry_path = "/webapi/entry.cgi",
  timeout = 15000,
  page_size = 200,
  max_tracks = 10000,
  skip_formats = { "ape", "wma", "dsf", "dff", "dsd", "alac" },
}

M.cfg, M.apis = {}, {}
M.sid, M.synotoken, M.session_at = nil, nil, nil

local API_INFO = "SYNO.API.Info"
local API_AUTH = "SYNO.API.Auth"
local API_SONG = "SYNO.AudioStation.Song"
local API_STREAM = "SYNO.AudioStation.Stream"
local API_PLAYLIST = "SYNO.AudioStation.Playlist"
local version_caps = { [API_AUTH] = 6, [API_SONG] = 3, [API_STREAM] = 2, [API_PLAYLIST] = 3 }

local function encode(s)
  return (tostring(s or ""):gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function form_encode(params)
  local keys, parts = {}, {}
  for k in pairs(params or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if params[k] ~= nil then parts[#parts + 1] = encode(k) .. "=" .. encode(params[k]) end
  end
  return table.concat(parts, "&")
end

local function sorted_unique_formats(values)
  local out, seen = {}, {}
  for _, value in ipairs(values or {}) do
    local s = tostring(value or ""):lower()
    if s ~= "" and not seen[s] then seen[s] = true; out[#out + 1] = s end
  end
  return out
end

local function env_value(name)
  local value = os.getenv(name)
  if value == nil or value == "" then return nil end
  return value
end

local function read_device_id(path)
  if not path or path == "" then return "" end
  local fh = io.open(path, "r")
  if not fh then return "" end
  local value = fh:read("*l") or ""
  fh:close()
  return value:match("^%s*(.-)%s*$") or ""
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function save_device_id(path, value)
  if not path or path == "" or not value or value == "" then return end
  local fh = io.open(path, "w")
  if not fh then
    mico.log("[synology] unable to save DSM device token")
    return
  end
  fh:write(value, "\n")
  fh:close()
  mico.exec("chmod 600 " .. shell_quote(path), { timeout_ms = 1000, max_bytes = 1024 })
end

function M.setup(cfg)
  local c = {}
  for k, v in pairs(M.config) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  local vars = {
    url = "MICO_SYNO_URL", user = "MICO_SYNO_USER", pass = "MICO_SYNO_PASS",
    otp = "MICO_SYNO_OTP", device_name = "MICO_SYNO_DEVICE_NAME",
    device_id = "MICO_SYNO_DEVICE_ID", timeout = "MICO_SYNO_TIMEOUT",
    page_size = "MICO_SYNO_PAGE_SIZE",
  }
  for key, name in pairs(vars) do
    local value = env_value(name)
    if value ~= nil then c[key] = value end
  end
  c.url = tostring(c.url or ""):gsub("/+$", "")
  c.user, c.pass = tostring(c.user or ""), tostring(c.pass or "")
  c.otp, c.device_name = tostring(c.otp or ""), tostring(c.device_name or "mico-agent")
  c.device_id_file = tostring(c.device_id_file or "")
  c.entry_path = tostring(c.entry_path or "/webapi/entry.cgi")
  c.timeout = math.max(1000, tonumber(c.timeout) or 15000)
  c.page_size = math.max(1, math.min(1000, math.floor(tonumber(c.page_size) or 200)))
  c.max_tracks = math.max(1, math.min(100000, math.floor(tonumber(c.max_tracks) or 10000)))
  c.skip_formats = sorted_unique_formats(c.skip_formats)
  if c.device_id == nil or c.device_id == "" then c.device_id = read_device_id(c.device_id_file) end
  M.cfg, M.apis = c, {}
  M.sid, M.synotoken, M.session_at = nil, nil, nil
end

function M.available()
  return M.cfg.url ~= "" and M.cfg.user ~= "" and M.cfg.pass ~= ""
end

local function endpoint(path)
  path = tostring(path or ""):gsub("^/+", "")
  if path:match("^webapi/") then return M.cfg.url .. "/" .. path end
  return M.cfg.url .. "/webapi/" .. path
end

local function entry_endpoint()
  local path = M.cfg.entry_path
  if path:match("^https?://") then return path end
  return endpoint(path)
end

local function http_get(url)
  return mico.http({
    method = "GET", url = url,
    headers = { Accept = "application/json" },
    timeout_ms = tonumber(M.cfg.timeout) or 15000,
  })
end

local function decode(resp, label)
  if resp.error then return nil, label .. ": HTTP 请求失败", nil, resp.status end
  local status = tonumber(resp.status)
  if status and (status < 200 or status >= 400) then
    return nil, label .. ": HTTP " .. tostring(status), nil, status
  end
  local ok, json = pcall(mico.json_decode, resp.body or "")
  if not ok or type(json) ~= "table" then return nil, label .. ": DSM 响应不是 JSON", nil, status end
  if json.success == false then
    local code = tonumber(json.error and json.error.code)
    local detail = code == 105 and "权限不足" or
      (code == 106 or code == 119) and "会话过期" or
      code == 403 and "需要两步验证码" or "DSM API 错误"
    return nil, label .. ": " .. detail .. (code and (" (" .. code .. ")") or ""), code, status
  end
  return json.data or {}, nil, nil, status
end

local function query_apis()
  if next(M.apis) ~= nil then return true end
  local names = table.concat({ API_AUTH, API_SONG, API_STREAM, API_PLAYLIST }, ",")
  local query = form_encode({ api = API_INFO, version = 1, method = "query", query = names })
  local resp = http_get(entry_endpoint() .. "?" .. query)
  local data, err = decode(resp, "查询 DSM API")
  if not data then return nil, err end
  M.apis = data
  return true
end

local function api_version(name)
  local info = M.apis[name]
  if type(info) ~= "table" then return nil end
  local max_version = tonumber(info.maxVersion) or 1
  local min_version = tonumber(info.minVersion) or 1
  local version = math.min(max_version, version_caps[name] or max_version)
  if version < min_version then return nil end
  return version
end

local function auth_call(params)
  local query = form_encode(params)
  return decode(http_get(entry_endpoint() .. "?" .. query), "DSM 登录")
end

local function persist_device_id(device_id)
  M.cfg.device_id = device_id
  save_device_id(M.cfg.device_id_file, device_id)
end

function M.login()
  if not M.available() then return nil, "群晖 Audio Station 未配置" end
  local ok, err = query_apis()
  if not ok then return nil, err end
  local version = api_version(API_AUTH)
  if not version then return nil, "此 DSM 不支持 Audio Station 登录 API" end
  local params = {
    api = API_AUTH, version = version, method = "login", account = M.cfg.user,
    passwd = M.cfg.pass, session = "AudioStation", format = "sid",
    device_name = M.cfg.device_name, enable_device_token = "yes",
  }
  if M.cfg.device_id ~= "" then params.device_id = M.cfg.device_id end
  if M.cfg.otp ~= "" then params.otp_code = M.cfg.otp end
  local data, login_err, code = auth_call(params)
  if not data then
    if code == 403 and M.cfg.otp == "" then login_err = login_err .. "；请通过 MICO_SYNO_OTP 提供验证码" end
    return nil, login_err
  end
  if type(data.sid) ~= "string" or data.sid == "" then return nil, "DSM 登录响应缺少 sid" end
  M.sid = data.sid
  M.synotoken = tostring(data.synotoken or data.SynoToken or "")
  M.session_at = os.time()
  if data.did and data.did ~= "" then persist_device_id(tostring(data.did)) end
  return true
end

local function ensure_session()
  if M.sid and M.session_at and os.time() - M.session_at < 20 * 60 then return true end
  return M.login()
end

local function request_api(name, method, params, retried)
  local ok, err = query_apis()
  if not ok then return nil, err end
  ok, err = ensure_session()
  if not ok then return nil, err end
  local info = M.apis[name]
  local version = api_version(name)
  if type(info) ~= "table" or type(info.path) ~= "string" or not version then
    return nil, "此 DSM 未提供 " .. name .. " API"
  end
  local args = {}
  for k, v in pairs(params or {}) do args[k] = v end
  args.api, args.version, args.method, args._sid = name, version, method, M.sid
  if M.synotoken ~= "" then args.SynoToken = M.synotoken end
  local resp = http_get(endpoint(info.path) .. "?" .. form_encode(args))
  local data, call_err, code, status = decode(resp, name .. "." .. method)
  if not data and not retried and (code == 106 or code == 119 or status == 401) then
    M.sid, M.session_at = nil, nil
    ok, err = M.login()
    if not ok then return nil, err end
    return request_api(name, method, params, true)
  end
  return data, call_err
end

local function text_value(value)
  if type(value) == "string" or type(value) == "number" then return tostring(value) end
  if type(value) ~= "table" then return "" end
  if value.name ~= nil then return text_value(value.name) end
  if value.title ~= nil then return text_value(value.title) end
  local out = {}
  for _, item in ipairs(value) do
    local s = text_value(item)
    if s ~= "" then out[#out + 1] = s end
  end
  return table.concat(out, "/")
end

local function duration(value)
  local n = tonumber(value)
  if n then return math.floor(n) end
  if type(value) ~= "string" then return nil end
  local h, m, s = value:match("^(%d+):(%d%d):(%d%d)$")
  if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
  m, s = value:match("^(%d+):(%d%d)$")
  if m then return tonumber(m) * 60 + tonumber(s) end
end

local function simplify(song)
  local additional = song.additional or {}
  local tag = additional.song_tag or {}
  local audio = additional.song_audio or {}
  local path = text_value(song.path or song.file_path or song.filePath or song.filename or song.file_name)
  local fmt = text_value(song.format or song.file_format or song.fileFormat or song.file_type or audio.format or audio.container)
  local codec = text_value(song.codec or audio.codec)
  if fmt == "" then fmt = codec end
  if fmt == "" then fmt = path:match("%.([%w]+)$") or "" end
  return {
    id = text_value(song.id or song.song_id),
    title = text_value(song.title or tag.title or song.name),
    artist = text_value(song.artist or song.artists or tag.artist or song.album_artist),
    album = text_value(song.album or tag.album),
    duration = duration(song.duration or song.time or song.length or audio.duration),
    format = fmt, codec = codec, path = path,
  }
end

local function playable(track)
  local fmt = tostring(track.format or track.codec or ""):lower()
  if fmt == "" then return true end
  for _, blocked in ipairs(M.cfg.skip_formats or {}) do
    if fmt:find(tostring(blocked):lower(), 1, true) then return false end
  end
  return true
end

function M.list_tracks()
  if not M.available() then return nil, "群晖 Audio Station 未配置" end
  local tracks, offset, total = {}, 0, nil
  local size = tonumber(M.cfg.page_size) or 200
  local max_tracks = tonumber(M.cfg.max_tracks) or 10000
  while #tracks < max_tracks do
    local data, err = request_api(API_SONG, "list", {
      library = "all", offset = offset, limit = math.min(size, max_tracks - #tracks),
      sort_by = "title", sort_direction = "ASC", additional = "song_tag,song_audio",
    })
    if not data then return nil, err end
    local songs = data.songs or data.list or data.items or {}
    if type(songs) ~= "table" then return nil, "Audio Station 曲目列表格式无效" end
    total = tonumber(data.total or data.song_total) or total
    for _, item in ipairs(songs) do
      local track = simplify(item)
      if track.id ~= "" and track.title ~= "" and playable(track) then tracks[#tracks + 1] = track end
    end
    if #songs == 0 then break end
    offset = offset + #songs
    if (total and offset >= total) or #songs < size then break end
  end
  return tracks
end

function M.stream(id)
  if not M.available() then return nil, "群晖 Audio Station 未配置" end
  local ok, err = ensure_session()
  if not ok then return nil, err end
  local info = M.apis[API_STREAM]
  local version = api_version(API_STREAM)
  if type(info) ~= "table" or type(info.path) ~= "string" or not version then
    return nil, "此 DSM 未提供 Audio Station Stream API"
  end
  local args = {
    api = API_STREAM, version = version, method = "stream", id = tostring(id or ""), _sid = M.sid,
  }
  if M.synotoken ~= "" then args.SynoToken = M.synotoken end
  return endpoint(info.path) .. "?" .. form_encode(args), {}
end

return M
