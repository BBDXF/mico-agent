-- 哔哩哔哩在线音频插件：视频搜索 + DASH 音频流。
local M = {
  name = "bili",
  type = "online",
  version = "1.1",
  description = "哔哩哔哩视频音频（在线搜索与播放）",
}

-- 插件配置（直接修改本文件即可；网页「插件」页可在线编辑并热重载）。
-- 同名环境变量在运行时优先于这里的值。
M.config = {
  -- B 站 API 地址（不带结尾斜杠）。一般不用改；测试时可指向 mock 服务。
  -- 例："https://api.bilibili.com"   默认：同例   环境变量：MICO_BILI_API
  api = "https://api.bilibili.com",

  -- B 站主站地址，用作 Referer（不带结尾斜杠）。缺少正确 Referer 时 CDN 返回 403。
  -- 例："https://www.bilibili.com"   默认：同例   环境变量：MICO_BILI_WWW
  www = "https://www.bilibili.com",

  -- 每次搜索向 B 站请求的结果条数（B 站上限 50）。只取其中前 limit 条返回。
  -- 例：10   默认：20
  page_size = 20,

  -- 请求头 User-Agent。B 站会拦截非浏览器 UA（-412），一般保持默认。
  -- 默认：Chrome 120 桌面版 UA
  user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",

  -- 额外 Cookie（整串原样发送）。留空时自动申请匿名 buvid3。
  -- 填登录后的 SESSDATA 可获得更高音质/会员内容。
  -- 例："SESSDATA=xxxx; buvid3=yyyy"   默认：""   环境变量：MICO_BILI_COOKIE
  cookie = "",

  -- 音质偏好：B 站 AAC 音轨 id，选择不高于该值的最高一档。
  --   30216 = 64K，30232 = 132K，30280 = 192K
  -- 只会在普通 AAC 音轨（dash.audio）里挑；杜比全景声(dash.dolby)和
  -- Hi-Res 无损(dash.flac) 永远不选——音箱的 ffmpeg 解不了 E-AC-3/FLAC-in-MP4。
  -- 例：30232   默认：30280
  audio_quality = 30280,
}

local env = { api = "MICO_BILI_API", www = "MICO_BILI_WWW", cookie = "MICO_BILI_COOKIE" }
local cfg = {}
local buvid3

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

function M.setup()
  for k, v in pairs(M.config) do cfg[k] = v end
  for k, var in pairs(env) do
    local v = os.getenv(var)
    if v and v ~= "" then cfg[k] = v end
  end
  cfg.api = tostring(cfg.api or ""):gsub("/+$", "")
  cfg.www = tostring(cfg.www or ""):gsub("/+$", "")
  buvid3 = nil
end

local function headers()
  local h = { ["User-Agent"] = cfg.user_agent, Referer = cfg.www .. "/" }
  local parts = {}
  if cfg.cookie and cfg.cookie ~= "" then parts[#parts + 1] = cfg.cookie end
  if buvid3 then parts[#parts + 1] = "buvid3=" .. buvid3 end
  if #parts > 0 then h.Cookie = table.concat(parts, "; ") end
  return h
end

local function get(path)
  local r = mico.http({ url = cfg.api .. path, headers = headers(), timeout_ms = 10000 })
  if r.error then return nil, r.error end
  local j = mico.json_decode(r.body)
  if not j then return nil, "http " .. r.status end
  if j.code ~= 0 then return nil, "bili code " .. tostring(j.code) .. ": " .. tostring(j.message) end
  return j.data
end

local function ensure_cookie()
  if buvid3 or (cfg.cookie or ""):find("buvid3=", 1, true) then return end
  local d = get("/x/frontend/finger/spi")
  if d and d.b_3 then buvid3 = d.b_3 end
end

local entities = { ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"', ["&#39;"] = "'" }

local function clean(s)
  s = tostring(s or ""):gsub("<[^>]*>", "")
  return (s:gsub("&%a+;", entities):gsub("&#39;", "'"))
end

local function seconds(d)
  if type(d) == "number" then return d end
  local total = 0
  for n in tostring(d or ""):gmatch("%d+") do total = total * 60 + tonumber(n) end
  return total
end

function M.search(query, limit)
  ensure_cookie()
  local d, err = get("/x/web-interface/search/type?search_type=video&page=1&page_size="
    .. (tonumber(cfg.page_size) or 20) .. "&keyword=" .. urlencode(query))
  if not d then return nil, err end
  local out = {}
  for _, v in ipairs(d.result or {}) do
    if v.bvid and v.bvid ~= "" then
      out[#out + 1] = { id = v.bvid, title = clean(v.title), artist = clean(v.author), album = "", duration = seconds(v.duration) }
      if #out >= (limit or 5) then break end
    end
  end
  return out
end

-- Picks a plain AAC track from dash.audio: highest id <= preference, else
-- the lowest available. dash.dolby / dash.flac are deliberately ignored.
function M.pick_audio(list, pref)
  pref = tonumber(pref) or 30280
  local best, lowest
  for _, a in ipairs(list or {}) do
    local codec = tostring(a.codecs or "mp4a")
    if codec:find("mp4a", 1, true) then
      local id = tonumber(a.id) or 0
      if id <= pref and (not best or id > (tonumber(best.id) or 0)
          or (id == (tonumber(best.id) or 0) and (a.bandwidth or 0) > (best.bandwidth or 0))) then
        best = a
      end
      if not lowest or id < (tonumber(lowest.id) or 0) then lowest = a end
    end
  end
  return best or lowest
end

function M.stream(bvid)
  ensure_cookie()
  local v, err = get("/x/web-interface/view?bvid=" .. urlencode(bvid))
  if not v then return nil, err end
  local cid = v.cid or (v.pages and v.pages[1] and v.pages[1].cid)
  if not cid then return nil, "no cid" end
  local p, perr = get(string.format("/x/player/playurl?bvid=%s&cid=%d&fnval=16", urlencode(bvid), cid))
  if not p then return nil, perr end
  local a = M.pick_audio(p.dash and p.dash.audio, cfg.audio_quality)
  local url = a and (a.baseUrl or a.base_url)
  if not url and p.durl and p.durl[1] then url = p.durl[1].url end
  if not url then return nil, "no audio url" end
  return url, headers()
end

return M
