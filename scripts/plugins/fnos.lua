-- 飞牛音乐 (fnOS trim.music) 本地曲库插件。登录/签名等 API 细节在
-- lib/fnmusic.lua；歌单/收藏/歌词作为额外的 LLM 工具也在那里实现。
local fnmusic = require("fnmusic")

local M = {
  name = "fnos",
  type = "local",
  version = "1.1",
  description = "飞牛 NAS 音乐库（登录 + 曲目列表 + 流地址）",
}

-- 插件配置（直接修改本文件即可；网页「插件」页可在线编辑并热重载）。
-- 同名环境变量在运行时优先于这里的值（方便调试 / 不把密码写进文件）。
M.config = {
  -- 飞牛 NAS 的 Web 地址（协议 + 主机 + 端口，不带结尾斜杠）。
  -- 例："http://192.168.1.10:5666"   默认：""（为空时插件视为未配置、不参与搜索）
  -- 环境变量：MICO_FN_URL
  url = "",

  -- 飞牛账号用户名。例："andy"   默认：""
  -- 环境变量：MICO_FN_USER
  user = "",

  -- 飞牛账号密码（明文填写，发送前做 sha256）。例："p@ssw0rd"   默认：""
  -- 环境变量：MICO_FN_PASS
  pass = "",

  -- authx 签名前缀与 client key。两者都填写时才给请求加 authx 头；
  -- App 客户端通常不强制校验，留空即可。例："NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
  -- 默认：""   环境变量：MICO_FN_AUTHX_PREFIX / MICO_FN_CLIENT_KEY
  authx_prefix = "",
  client_key = "",

  -- 单次 HTTP 请求超时（毫秒）。NAS 唤醒硬盘较慢时可调大。
  -- 例：30000   默认：15000   环境变量：MICO_FN_TIMEOUT
  timeout = 15000,

  -- 同步曲库时每页拉取的曲目数。例：500   默认：200
  page_size = 200,

  -- 音箱自带的 ffmpeg/播放器解不了的文件格式（小写扩展名或编码名）。
  -- 这些曲目在同步索引时直接跳过，否则会“点到了却播不出声”。
  -- APE/WMA/DSD(dsf/dff)/ALAC 在小爱音箱固件的精简 ffmpeg 中均未编译进去。
  -- 格式未知（服务端没给 format/codec/路径）的曲目保留。
  -- 例：{ "ape", "wma" }   默认：如下
  skip_formats = { "ape", "wma", "dsf", "dff", "dsd", "alac" },
}

local env = {
  url = "MICO_FN_URL", user = "MICO_FN_USER", pass = "MICO_FN_PASS",
  authx_prefix = "MICO_FN_AUTHX_PREFIX", client_key = "MICO_FN_CLIENT_KEY", timeout = "MICO_FN_TIMEOUT",
}

-- 生效配置 = M.config 被环境变量覆盖后的结果。
local function effective()
  local c = {}
  for k, v in pairs(M.config) do c[k] = v end
  for k, var in pairs(env) do
    local v = os.getenv(var)
    if v and v ~= "" then c[k] = v end
  end
  return c
end

function M.setup()
  local c = effective()
  fnmusic.setup({
    base_url = c.url or "",
    username = c.user or "",
    password = c.pass or "",
    authx_prefix = c.authx_prefix or "",
    client_key = c.client_key or "",
    timeout_ms = tonumber(c.timeout) or 15000,
  })
end

function M.available()
  return fnmusic.configured()
end

-- 曲目格式（小写），取 format/codec/文件扩展名中第一个可用的；未知返回 nil。
function M.track_format(t)
  local f = t.format or t.codec
  if (not f or f == "") and t.path then f = tostring(t.path):match("%.([%w]+)$") end
  if not f or f == "" then return nil end
  return tostring(f):lower()
end

-- 音箱能否解码该曲目（未知格式视为可以）。
function M.playable(t)
  local f = M.track_format(t)
  if not f then return true end
  for _, s in ipairs(M.config.skip_formats or {}) do
    if f == s or f:find(s, 1, true) then return false end
  end
  return true
end

function M.list_tracks()
  local all, page, size = {}, 1, tonumber(M.config.page_size) or 200
  local fetched = 0
  while true do
    local list, total = fnmusic.tracks(page, size)
    if not list then return nil, total end
    fetched = fetched + #list
    for _, t in ipairs(list) do
      if M.playable(t) then all[#all + 1] = t end
    end
    if #list < size or (tonumber(total) and fetched >= tonumber(total)) then break end
    page = page + 1
  end
  return all
end

function M.stream(id)
  if not fnmusic.token then
    local ok, err = fnmusic.login()
    if not ok then return nil, err end
  end
  return fnmusic.stream_url(id)
end

function M.on_play(id)
  fnmusic.report_play(id)
end

return M
