-- Named routes from XiaoAi voice requests to Linux Muse Gadget bridges.
-- Bridge contract: POST /ask {"text":"..."} -> {"reply":"..."}.
local config = require("config")
local web = require("web")

local M = {}

-- Short polite variants are common in spoken requests. Keep the recognized
-- speech verb distinct from music verbs such as "播放" to avoid stealing songs.
local route_prefixes = { "请问问", "请问一下", "请问下", "问一下", "问下", "问问", "请问" }

local lead_punct = { " ", "\t", "，", "。", "！", "？", "、", "：", "；", ",", ".", "!", "?", ":", ";" }
local function trim_lead(s)
  local changed = true
  while changed do
    changed = false
    for _, p in ipairs(lead_punct) do
      if s:sub(1, #p) == p then s = s:sub(#p + 1); changed = true end
    end
  end
  return s
end

local function compact(s)
  return (tostring(s or ""):gsub("%s+", ""):gsub("　", ""))
end

-- Match a prefix ignoring spaces, then return the untouched question text.
local function after_prefix(text, prefix)
  local t = trim_lead(tostring(text or ""))
  local cp = compact(prefix):lower()
  if cp == "" or compact(t):lower():sub(1, #cp) ~= cp then return nil end
  local i, consumed = 1, 0
  while i <= #t and consumed < #cp do
    if t:sub(i, i + 2) == "　" then
      i = i + 3
    elseif t:sub(i, i):match("%s") then
      i = i + 1
    else
      i, consumed = i + 1, consumed + 1
    end
  end
  return trim_lead(t:sub(i))
end

-- Returns the matching configured route and the question after "问问<name>".
function M.match(text)
  local routes = ((config.current or {}).muse or {}).routes or {}
  local ordered = {}
  for _, route in ipairs(routes) do ordered[#ordered + 1] = route end
  table.sort(ordered, function(a, b) return #compact("问问" .. tostring(a.name or "")) > #compact("问问" .. tostring(b.name or "")) end)
  for _, route in ipairs(ordered) do
    local name = tostring(route.name or ""):match("^%s*(.-)%s*$")
    if name ~= "" then
      for _, prefix in ipairs(route_prefixes) do
        local question = after_prefix(text, prefix .. name)
        if question ~= nil then return route, question end
      end
    end
  end
end

local function valid_host(host)
  return type(host) == "string" and #host > 0 and #host <= 253 and host:match("^[%w%.%-]+$") ~= nil
end

local function finish_step(route, question, started, result, err)
  web.step({
    kind = "tool", name = "muse_bridge", args = { name = route.name, host = route.host, question = question },
    result = result, error = err, ms = mico.now_ms() - started,
  })
end

-- Sends a text turn to the selected Linux bridge and waits for its Muse reply.
function M.ask(route, question)
  local started = mico.now_ms()
  local muse_cfg = (config.current or {}).muse or {}
  local token = tostring(muse_cfg.bridge_token or "")
  local host = route and route.host
  local port = tonumber(route and route.port) or 8765
  if token == "" then
    local err = "请先在配置页填写 Gadget 桥接令牌"
    finish_step(route, question, started, nil, err)
    return nil, err
  end
  if not valid_host(host) or port < 1 or port > 65535 or port ~= math.floor(port) then
    local err = "Muse 路由主机或端口无效"
    finish_step(route, question, started, nil, err)
    return nil, err
  end

  local timeout = tonumber(muse_cfg.timeout_ms) or 90000
  local response = mico.http({
    method = "POST",
    url = "http://" .. host .. ":" .. tostring(port) .. "/ask",
    headers = { Accept = "application/json", ["Content-Type"] = "application/json", Authorization = "Bearer " .. token },
    body = mico.json_encode({ text = question }),
    timeout_ms = timeout,
  })
  if response.error then
    local err = "Muse Gadget 请求失败：" .. tostring(response.error)
    finish_step(route, question, started, nil, err)
    return nil, err
  end
  if response.status < 200 or response.status >= 300 then
    local detail = tostring(response.body or ""):sub(1, 300)
    local err = "Muse Gadget HTTP " .. tostring(response.status) .. (detail ~= "" and (": " .. detail) or "")
    finish_step(route, question, started, nil, err)
    return nil, err
  end
  local payload = mico.json_decode(response.body or "")
  local reply = type(payload) == "table" and payload.reply or nil
  if type(reply) ~= "string" or reply:match("^%s*$") then
    local err = "Muse Gadget 响应格式错误，期望 {reply:string}"
    finish_step(route, question, started, nil, err)
    return nil, err
  end
  reply = reply:match("^%s*(.-)%s*$")
  finish_step(route, question, started, reply, nil)
  return reply
end

return M
