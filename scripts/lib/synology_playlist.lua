-- Optional Audio Station playlist API adapter.
-- It reuses the loaded Synology plugin's config/session without modifying its
-- source file, so deployments keep credentials configured in that file.
local plugins = require("plugins")

local M = {}
local API = "SYNO.AudioStation.Playlist"

local function plugin()
  local p = plugins.get("synology")
  if not p or type(p.login) ~= "function" or type(p.cfg) ~= "table" then
    return nil, "群晖插件未启用或未配置"
  end
  return p
end

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
    local v = params[k]
    if v ~= nil then parts[#parts + 1] = encode(k) .. "=" .. encode(v) end
  end
  return table.concat(parts, "&")
end

local function endpoint(p, path)
  path = tostring(path or ""):gsub("^/+", "")
  if path:match("^webapi/") then return p.cfg.url .. "/" .. path end
  return p.cfg.url .. "/webapi/" .. path
end

local function entry_endpoint(p)
  local path = tostring(p.cfg.entry_path or "/webapi/entry.cgi")
  if path:match("^https?://") then return path end
  return endpoint(p, path)
end

local function decode(resp, label)
  if resp.error then return nil, label .. ": " .. tostring(resp.error), nil, resp.status end
  local json = mico.json_decode(resp.body or "")
  if type(json) ~= "table" then return nil, label .. ": DSM 响应不是 JSON", nil, resp.status end
  if json.success == false then
    local code = tonumber(json.error and json.error.code)
    local name = code == 101 and "缺少参数" or code == 102 and "参数无效" or
      code == 103 and "方法不存在" or code == 106 and "权限不足" or
      code == 119 and "会话过期" or "DSM API 错误"
    return nil, label .. ": " .. name .. (code and (" (" .. code .. ")") or ""), code, resp.status
  end
  if resp.status and (resp.status < 200 or resp.status >= 400) then
    return nil, label .. ": HTTP " .. tostring(resp.status), nil, resp.status
  end
  return json.data or {}, nil, nil, resp.status
end

local function ensure_session(p)
  if p.sid and p.session_at and os.time() - p.session_at < 20 * 60 then return true end
  return p.login()
end

local function ensure_api(p)
  local ok, err = ensure_session(p)
  if not ok then return nil, err end
  p.apis = p.apis or {}
  if type(p.apis[API]) == "table" and type(p.apis[API].path) == "string" then return true end
  local query = form_encode({ api = "SYNO.API.Info", version = 1, method = "query", query = API })
  local resp = mico.http({
    method = "GET", url = entry_endpoint(p) .. "?" .. query,
    headers = { Accept = "application/json" }, timeout_ms = tonumber(p.cfg.timeout) or 15000,
  })
  local data
  data, err = decode(resp, "查询 Playlist API")
  if not data then return nil, err end
  local info = data[API]
  if type(info) ~= "table" or type(info.path) ~= "string" or info.path == "" then
    return nil, "此 DSM 未提供 Audio Station Playlist API"
  end
  p.apis[API] = info
  return true
end

local function request(p, method, params, retried)
  local ok, err = ensure_api(p)
  if not ok then return nil, err end
  ok, err = ensure_session(p)
  if not ok then return nil, err end
  local info = p.apis[API]
  local version = math.min(tonumber(info.maxVersion) or 3, 3)
  if version < (tonumber(info.minVersion) or 1) then version = tonumber(info.maxVersion) or 3 end
  local args = {}
  for k, v in pairs(params or {}) do args[k] = v end
  args.api, args.version, args.method, args._sid = API, version, method, p.sid
  if p.synotoken and p.synotoken ~= "" then args.SynoToken = p.synotoken end
  local resp = mico.http({
    method = "GET", url = endpoint(p, info.path) .. "?" .. form_encode(args),
    headers = { Accept = "application/json" }, timeout_ms = tonumber(p.cfg.timeout) or 15000,
  })
  local data, call_err, api_error, http_status = decode(resp, API .. "." .. method)
  if not data and not retried and (api_error == 119 or http_status == 401 or http_status == 403) then
    ok, err = p.login()
    if not ok then return nil, err end
    return request(p, method, params, true)
  end
  return data, call_err
end

local function text_value(value)
  if type(value) == "string" or type(value) == "number" then return tostring(value) end
  if type(value) == "table" then
    if value.name ~= nil then return text_value(value.name) end
    if value.title ~= nil then return text_value(value.title) end
    local out = {}
    for _, v in ipairs(value) do
      local s = text_value(v)
      if s ~= "" then out[#out + 1] = s end
    end
    return table.concat(out, "/")
  end
  return ""
end

local function duration(value)
  local n = tonumber(value)
  if n then return math.floor(n) end
  if type(value) ~= "string" then return nil end
  local h, m, s = value:match("^(%d+):(%d%d):(%d%d)$")
  if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) end
  m, s = value:match("^(%d+):(%d%d)$")
  if m then return tonumber(m) * 60 + tonumber(s) end
  return nil
end

local function simplify(song)
  if type(song) ~= "table" then return { id = tostring(song or ""), title = "", artist = "" } end
  local additional = song.additional or {}
  local tag = additional.song_tag or {}
  local audio = additional.song_audio or {}
  local path = text_value(song.path or song.file_path or song.filePath or song.filename or song.file_name)
  local fmt = text_value(song.format or song.file_format or song.fileFormat or song.file_type or audio.format or audio.codec or song.codec)
  if fmt == "" then fmt = path:match("%.([%w]+)$") or "" end
  return {
    id = text_value(song.id or song.song_id),
    title = text_value(song.title or tag.title or song.name),
    artist = text_value(song.artist or song.artists or tag.artist or song.album_artist),
    album = text_value(song.album or tag.album),
    duration = duration(song.duration or song.time or song.length or audio.duration),
    format = fmt, codec = text_value(audio.codec or song.codec), path = path,
  }
end

local function playlist_songs(data)
  if type(data) ~= "table" then return nil end
  local candidates = { data }
  local seen = { [data] = true }
  local parents = { "playlists", "playlist", "info", "additional", "items", "list", "data", "result", "payload" }
  local i = 1
  while i <= #candidates and i <= 32 do
    local item = candidates[i]
    for _, key in ipairs({ "songs", "song_list", "songList", "song_ids", "songIds", "tracks" }) do
      if type(item[key]) == "table" then return item[key] end
      if type(item[key]) == "string" then
        local ok, value = pcall(mico.json_decode, item[key])
        if ok and type(value) == "table" then return value end
      end
    end
    for _, key in ipairs({ "items", "list" }) do
      local value = item[key]
      if type(value) == "table" then
        local first = value[1]
        if type(first) == "string" or type(first) == "number" then return value end
        if type(first) == "table" and (first.song_id or first.artist or first.album or first.duration or
            first.path or first.song_tag or first.song_audio) then return value end
      end
    end
    for _, key in ipairs(parents) do
      local value = item[key]
      if type(value) == "table" and not seen[value] then
        seen[value] = true
        candidates[#candidates + 1] = value
        if value[1] and type(value[1]) == "table" and not seen[value[1]] then
          seen[value[1]] = true
          candidates[#candidates + 1] = value[1]
        end
      end
    end
    i = i + 1
  end
end

local function playlist_info_shape(data)
  local function keys(value)
    if type(value) ~= "table" then return "" end
    local names = {}
    for key in pairs(value) do names[#names + 1] = tostring(key) end
    table.sort(names)
    while #names > 8 do table.remove(names) end
    return table.concat(names, ",")
  end
  local parts = { "data{" .. keys(data) .. "}" }
  if type(data) == "table" then
    for _, key in ipairs({ "playlists", "playlist", "info", "additional", "data", "result" }) do
      local value = data[key]
      if type(value) == "table" then
        if value[1] and type(value[1]) == "table" then value = value[1] end
        parts[#parts + 1] = key .. "{" .. keys(value) .. "}"
        if type(value.additional) == "table" then
          parts[#parts + 1] = key .. ".additional{" .. keys(value.additional) .. "}"
        end
        if #parts >= 4 then break end
      end
    end
  end
  return table.concat(parts, " ")
end

function M.list_playlists()
  local p, err = plugin()
  if not p then return nil, err end
  local ok
  ok, err = ensure_api(p)
  if not ok then return nil, err end
  local queries = {
    { library = "all", offset = 0, limit = 500 },
    { library = "personal", offset = 0, limit = 500 },
    { library = "shared", offset = 0, limit = 500 },
    { offset = 0, limit = 500 },
  }
  local out, seen, saw_list_field, shape_keys = {}, {}, false, {}
  local function collect(data)
    if type(data) ~= "table" then return end
    local items = data.playlists or data.playlist or data.list or data.items
      or (type(data.info) == "table" and (data.info.playlists or data.info.list))
      or (data[1] and data)
    if type(items) == "table" then
      saw_list_field = true
      if items.id or items.name or items.title then items = { items } end
      local rows = {}
      if items[1] then
        for _, item in ipairs(items) do rows[#rows + 1] = item end
      else
        for key, item in pairs(items) do
          if type(item) == "table" then
            if not (item.id or item.playlist_id or item.playlistId) then
              local copy = {}; for k, v in pairs(item) do copy[k] = v end
              copy.id = key
              item = copy
            end
            rows[#rows + 1] = item
          end
        end
      end
      for _, item in ipairs(rows) do
        if type(item) == "table" then
          local id = text_value(item.id or item.playlist_id or item.playlistId)
          local name = text_value(item.name or item.title)
          if id ~= "" and name ~= "" and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, name = name, song_count = tonumber(item.song_count or item.songCount or item.count) }
          end
        end
      end
    else
      for key in pairs(data) do shape_keys[#shape_keys + 1] = tostring(key) end
    end
  end
  local last_err
  for _, params in ipairs(queries) do
    local data
    data, last_err = request(p, "list", params)
    if data then
      collect(data)
      if #out > 0 then return out end
    end
  end
  if not saw_list_field then
    table.sort(shape_keys)
    local shape = #shape_keys > 0 and table.concat(shape_keys, ",") or "空对象"
    return nil, "DSM Playlist.list 响应格式未识别（字段：" .. shape .. "）" .. (last_err and ("；" .. last_err) or "")
  end
  return out
end

function M.get_playlist_tracks(id)
  local p, err = plugin()
  if not p then return nil, err end
  -- Playlist.getinfo only returns playlist metadata unless the song-specific
  -- additional fields are requested. Audio Station expects a comma-separated
  -- list of songs_* fields, not a JSON array and not the generic "songs" key.
  local data
  data, err = request(p, "getinfo", {
    id = tostring(id or ""),
    library = "all",
    offset = 0,
    limit = 1000,
    sort_direction = "ASC",
    additional = "songs_song_tag,songs_song_audio,songs_song_rating,sharing_info",
  })
  local songs = data and playlist_songs(data) or nil
  if not data then return nil, err end
  if not songs then
    local shape = playlist_info_shape(data)
    mico.log("[synology_playlist] Playlist.getinfo response shape:", shape)
    return nil, "DSM 返回歌单信息，但未返回曲目列表（Playlist.getinfo；字段：" .. shape .. ")" .. (err and ("；" .. err) or "")
  end

  local by_id
  local function library_lookup(song_id)
    if not by_id then
      by_id = {}
      local all = p.list_tracks()
      for _, track in ipairs(all or {}) do by_id[tostring(track.id)] = track end
    end
    return by_id[tostring(song_id)]
  end
  local blocked = {}
  for _, value in ipairs(p.cfg.skip_formats or {}) do blocked[#blocked + 1] = tostring(value):lower() end
  local out = {}
  for _, song in ipairs(songs) do
    local track = simplify(song)
    if track.id ~= "" and (track.title == "" or not track.duration) then
      local found = library_lookup(track.id)
      if found then track = found end
    end
    if track.id ~= "" and track.title ~= "" then
      local fmt = tostring(track.format or track.codec or ""):lower()
      local allowed = true
      for _, value in ipairs(blocked) do if value ~= "" and fmt:find(value, 1, true) then allowed = false; break end end
      if allowed then out[#out + 1] = track end
    end
  end
  if #out == 0 then return nil, "这个歌单没有可播放曲目" end
  return out
end

return M
