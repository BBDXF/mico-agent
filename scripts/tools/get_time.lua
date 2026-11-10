-- 示例自定义工具：返回本地日期和时间。
-- 模板说明见网页「工具」页或 GET /api/tool-template。
return {
  name = "get_time",
  description = "获取当前本地日期和时间",
  parameters = { type = "object", properties = {} },
  handler = function()
    return { now = os.date("%Y-%m-%d %H:%M:%S"), weekday = os.date("%A") }
  end,
}
