# 开发参考

> 面向开发者的详细说明：Lua API、HTTP API、插件/工具协议、模糊搜索算法。用户文档见 [README](../README.md)。

## 构建与测试（本机）

```sh
make          # build/mico-agent 及 build/mico-agent.stripped
make test     # 单元测试 + 集成测试（Python mock OpenAI 服务，dry-run 不执行音箱命令）
```

依赖：g++（C++14）、libcurl 开发头文件。Lua 5.1.5 与 nlohmann/json 3.11.3 已放在 `third_party/`。
目标固件（1.77.6）自带 glibc 2.25、libstdc++ 6.0.22、libcurl 4.4.0，只动态链接 libc/libstdc++/libcurl。

`make` 通过 `-D` 注入版本信息：`MICO_VERSION`（默认 `0.2.2`，可 `make MICO_VERSION=x.y.z`）、
构建时 `git rev-parse --short HEAD`（失败为 `unknown`）、构建时间；运行时 `mico.version()` / `GET /api/status` 的 `version` 字段
还包含 Lua 版本、libcurl 版本与编译器。

手动运行：

```sh
MICO_LLM_API_KEY=sk-xxx MICO_DRY_RUN=1 build/mico-agent --once "现在几点"
MICO_INSTRUCTION_LOG=/tmp/test.log MICO_DRY_RUN=1 build/mico-agent   # 跟随日志
```

模拟飞牛：`tools/mock_fnos.py` 是一个以本地音乐文件夹为曲库的假 fnOS 音乐 API（曲目带 `format` 字段，如 flac/mp3），
可用来在 PC 上联调 `fnos` 插件，例如在 :5666 运行（账号 test/test）后：
`MICO_FN_URL=http://127.0.0.1:5666 MICO_FN_USER=test MICO_FN_PASS=test MICO_DRY_RUN=1 build/mico-agent`。

## 配置文件

查找顺序：`-c PATH` → `$MICO_CONFIG` → `./config.json`（存在时）→ `/data/mico-agent/config.json`。
优先级：环境变量 > 配置文件 > 内置默认值。模板见 `config.example.json`（`config.json` 已加入 `.gitignore`）。

| 段 | 字段 | 说明 |
|---|---|---|
| `llm` | `base_url` `api_key` `model` `timeout_ms`（默认 60000） `extra` | OpenAI 兼容接口；`extra` 合并进请求体（如 `{"enable_thinking":false}`） |
| `agent` | `system_prompt` `max_steps`（默认 8） `max_history`（默认 20） | Agent 提示词与循环限制 |
| `fast_path` | `enabled`（默认 true） `min_score`（0.6） `margin`（0.15） | “播放 X” 快路径：最佳分 ≥ min_score 且（≥0.8 或领先第二名 ≥ margin）时跳过 LLM |
| `web` | `listen`（默认 `0.0.0.0:8080`，空串关闭） `token` | Web UI / API；`token` 非空时需 `Authorization: Bearer` 或 `?token=` |
| `mdns` | `enabled`（默认 true） `hostname`（默认 `mico`，`[a-z0-9-]` 1–63 字符） `instance`（默认 `小爱音箱 mico-agent`） | 内置 mDNS 应答（`src/mdns.cpp`，仅 IPv4，UDP 5353，主循环非阻塞轮询）：A `<hostname>.local`、PTR `_http._tcp.local` → `<instance>._http._tcp.local`、SRV/TXT（`path=/`、`version=`）、`_services._dns-sd._udp.local`；TTL 120；每 30 秒检查地址变化并重新广播；绑定失败只记日志。修改每秒检查一次即时生效 |
| `shell` | `enabled` | 是否注册 `run_shell` |
| `plugins` | `dir`（默认 `<脚本目录>/plugins`） `enabled{name:bool}` | 插件 |
| `playback` | `mode`（`proxy` 默认 / `download`） `buffer_kb`（默认 1024，64–8192） `max_mb`（下载上限，默认 30） | 播放 |
| | `instruction_log`、`dry_run`、`poll_ms`（默认 50） | |

环境变量：`MICO_LLM_BASE_URL`、`MICO_LLM_API_KEY`、`MICO_LLM_MODEL`、
`MICO_WEB_LISTEN`、`MICO_WEB_TOKEN`、`MICO_ENABLE_SHELL`、`MICO_PLUGINS_DIR`、`MICO_PLAYBACK`、`MICO_INSTRUCTION_LOG`、`MICO_DRY_RUN=1`、`MICO_MDNS=0`（关闭 mDNS；测试用 `MICO_MDNS_PORT` 改端口）。
Web 保存时合并写回配置文件（格式化 JSON）并立即生效（LLM、Agent、快路径、插件、shell、播放参数、poll_ms）；
`web.listen`、`plugins.dir`、`instruction_log` 需重启（schema 中标记 `restart: true`）。
所有字段的说明见 `scripts/lib/config.lua` 中的 `M.schema`。

## 音乐插件（`scripts/plugins/*.lua`）

插件返回表 `{name, type="local"|"online", version, description, setup(cfg, all_cfg), stream(id) -> url, headers, on_play(id)?, available()?}`：

- `local`：`list_tracks()` → `{ {id,title,artist,album,duration}, ... }`；全部写入模糊索引 `music`，id 为 `插件名:id`。
- `online`：`search(query, limit, opts)` → 同上（可带 `duration` 秒、`play` 播放量）；仅在本地无好结果（分数 < 0.6）或用户说“在线”时使用。
  `opts.kind="song"` 时插件应只返回短视频（`opts.long` 为真时不限时长，用于找分 P / 合集），`"audio"` 不过滤。
  可选 `parts(id)` 返回分 P / 合集条目 `{id, title, duration}`；在线音乐源插件的 id 为 `BVxxx`（第一 P）或 `BVxxx:<cid>`（指定分 P），`stream` 按 cid 取流。
  核心筛选（`online.*`）：歌曲时长须在 `song_min_s`–`song_max_s`（默认 90–480 秒），标题含 `skip_keywords` 的排除，按模糊匹配分再按播放量排序；
  没有单曲时查看前 3 个长视频的分 P / 合集，取标题匹配 ≥ 0.6 且时长合格的一集；仍没有则交给 LLM。
  只说歌手（“X的歌”或命中曲库歌手）的在线请求搜 “X 歌曲”，从提到该歌手的单曲里随机放一首。
  `kind="audio"`（播客/访谈/讲座/相声等，快路径按关键词识别，`music_search` 传 `kind`）：不做歌曲过滤，60 秒–`audio_max_s`，从不边播边存。
- **插件配置写在插件文件里**：文件顶部 `M.config = {...}`，每项带中文注释（含义/示例/默认值）；
  `setup(M.config, all_cfg)` 在加载与配置变更时调用。`config.json` 不再有插件配置段。
  环境变量仍在运行时覆盖：`MICO_FN_URL/USER/PASS/AUTHX_PREFIX/CLIENT_KEY/TIMEOUT`，在线音乐源插件也有对应的环境变量。
- 新插件骨架：`GET /api/plugin-template`（两种类型都有注释说明）。
- `fnos` 与在线音乐源插件为内置插件（`builtin=true`）：可禁用、不可删除。

内置：`fnos`（飞牛音乐本地曲库，基于 `lib/fnmusic.lua`）、在线音乐源插件（获取在线音乐，可配置 Cookie/UA/每页条数；
播放只选普通 AAC 音轨，从不选杜比或无损音轨；无歌词）。
`fnos` 同步索引时跳过音箱 ffmpeg 解不了的格式（`skip_formats`，默认 ape/wma/dsf/dff/alac；依次看 `format`、`codec`、
路径扩展名，未知格式保留）。
管理器 `lib/plugins.lua`：加载/启停（写回 `plugins.enabled`）/保存（`loadstring`+`pcall` 校验、旧版本存 `.bak`、热重载、本地插件立即重建索引）/删除。

## Web UI 与 HTTP API

内置单线程 poll HTTP/1.1 服务（`src/httpd.cpp`），在主循环中与日志跟随交替运行，Lua 只在主线程被调用：
`on_http(method, path, query, headers, body)` → `{status, headers, body}` 或 `{proxy={url, headers, buffer_kb}}`。
路由在 `scripts/lib/web.lua`，页面为 `scripts/web/index.html`（状态 / 对话 / 配置 / 插件）。

| 路由 | 说明 |
|---|---|
| `GET /` | Web UI（无需令牌） |
| `GET /api/config` | `{config, defaults, effective, env_overrides, schema, path}`：`config` = 默认值合并配置文件，`effective` = 再叠加环境变量；密钥均显示为 `******`；`env_overrides` 为被环境变量覆盖的点号键（如 `llm.api_key`）；`schema` 为字段描述数组 `{key, label, type(string/number/bool/enum/text/secret/json), options?, min?, max?, help, restart?}` |
| `PUT /api/config` | 合并保存（返回同 GET 并加 `ok`）；提交 `******` 表示不修改，键设为 `null` 表示恢复默认（从文件删除）；按 schema 校验类型/范围/枚举，失败返回 400 `{error, key}` |
| `GET /api/status` | 运行时间、正在播放、索引大小、插件、`version{app,git,build_time,lua,curl,compiler}`、`mdns{enabled,name,ips}` |
| `GET /api/conversations[?since=<id>]` | `{conversations, last_id}`，新的在前；`since` 只返回 id 更大的已完成轮次；进行中的一轮总在最前（`status:"running"`）。轮询时用 `last_id` 作下次的 `since` |
| `GET /api/plugins` | `[{name,type,version,description,enabled,file,builtin,error?}]` |
| `POST /api/plugins {source}` 或 `{url}` | 安装（`url` 为在线添加，服务端 HTTP 下载）；同名已存在返回 409，除非 `overwrite:true` |
| `GET/PUT /api/plugins/:name/source` | 读源码 `{name,source}` / 保存 `{source}`：校验失败 400 `{error}`（含行号，如 `dummy.lua:3: ...`），文件不变；`name` 必须等于 `:name`；旧版本存 `<file>.bak` |
| `DELETE /api/plugins/:name` | 删除（备份为 `.bak`）；内置插件返回 400 |
| `POST /api/plugins/:name/enable\|disable` | 启停 |
| `GET /api/plugin-template` | `{source}` 新插件骨架 |
| `GET /api/tools` | `[{name, description(生效值), default_description, parameters, source:"builtin"\|"custom", enabled, editable(仅自定义为 true), file?, stats:{calls, errors, avg_ms, last_time?}}]`；内置在前，按名排序；`last_time` 从未调用时缺省；统计在内存中，重启清零 |
| `POST /api/tools/:name/enable\|disable` | 启停（存入 `tools.disabled`）；禁用的工具不发给 LLM |
| `PUT /api/tools/:name {description}` | 覆盖描述（存入 `tools.descriptions`）；`null` 或 `""` 恢复默认 |
| `POST /api/tools/:name/test {args}` | 直接运行 handler（禁用时也可） → `{result, ms, error?}`；不计入统计 |
| `GET/PUT /api/tools/:name/source` | 仅自定义工具：读 `{name,source}` / 保存 `{source}`（校验失败 400 `{error}` 含行号；`name` 须一致；旧版存 `.bak`；保存即重载）；内置工具 400 |
| `POST /api/tools {source}` 或 `{url}` [`overwrite`] | 安装自定义工具；同名已存在 409（与内置同名始终 409） |
| `DELETE /api/tools/:name` | 删除自定义工具（备份 `.bak`）；内置 400 |
| `GET /api/tool-template` | `{source}` 新工具骨架 |
| `POST /api/ask {text}` | 测试提问（不朗读） |
| `GET /stream/<plugin>/<id>` | 流代理 |
| `GET /api/save/jobs` | 边播边存任务（最近 20 个，新的在前）：`[{id, name, status:"queued"\|"running"\|"done"\|"skipped"\|"failed", reason?, bytes, total?, started, finished?, ms}]`；时间格式 `YYYY-MM-DD HH:MM:SS`；`total` 未知时缺省 |
| `POST /api/save/test` | 检查 WebDAV 连通性（对目录 PROPFIND Depth 0，不存在时 MKCOL）→ `{ok, status, error?}` |
| `GET /api/logs?lines=200` | 运行日志末尾 N 行（最多 1000）→ `{file, size, lines:[...]}`；未配置日志文件时返回内存中的最近行 |

**流代理**：Lua 先解析出上游 URL 与请求头，C++ fork 子进程用 libcurl 拉取并边收边转发（透传 `Range`、
`Content-Type/Length/Range`、`Accept-Ranges`；客户端慢时最多预读 `playback.buffer_kb`，之后阻塞上游）。
默认播放方式即 `ubus call mediaplayer player_play_url` 播放 `http://127.0.0.1:PORT/stream/...`；
`playback.mode="download"`（或 Web 服务未运行，如 `--once`）时回退为下载到 `/tmp/mico_play`（上限 `max_mb`，下载前与停止时删除旧文件）。
注意：在线音乐源返回的音频是 DASH m4a 片段，原厂播放器能否解码需在真机验证。

## 边播边存（`scripts/lib/saver.lua` + `src/saver.cpp`）

配置 `save.*`（默认 `enabled=false`）。在线音乐源的歌曲开始播放后（快路径或 `music_play`），依次检查：
时长（搜索结果已知时，`min_duration_s`–`max_duration_s`）、`skip_keywords`（原始标题，不区分大小写，按字节匹配），然后确定歌手/歌名（命名来源记录在对话 `save` 步骤与 `[save]` 日志：`llm` / `rule`，经曲库修正时加 `+library`，以及 LLM 耗时）：

1. **大模型**（`save.normalize`，默认开）：播放开始后用 `mico.complete{messages, max_tokens?, timeout_ms?}`（与对话相同的 llm 配置含 `extra`，不带工具、不写入对话历史；在主线程同步执行，超时 `normalize_timeout_ms` 默认 8000）
   提交用户原话、解析出的查询、在线结果原始标题、上传者、时长，要求只返回 `{"artist","title","confident"}`（去修饰、修正同音字、多歌手用“、”）。
   回复会去掉 ```json 围栏并取第一个 `{...}` 解析。`confident=false` 时跳过（“大模型判断不是原曲/不确定”）。
2. **规则**（大模型关闭或失败时）：`music_play` 的 `title` / `artist`，否则用查询；仅当结果标题不含整句、且“的”左侧是曲库已知歌手或出现在结果标题/上传者中时才按“歌手的歌名”拆分（“我的歌声里”不拆）。
   规则命名还要通过 `require_match`（结果标题须包含所点歌名/歌手，支持拼音模糊）。
3. **曲库修正**：索引同步时同时建立 `music_artists` 索引（去重歌手）；歌手与曲库歌手模糊匹配 ≥ 0.8 时采用曲库写法（如 BEYOND → Beyond）。
4. `require_artist`（默认开）：最终没有歌手时不保存。

文件名按 `filename` 模板生成（`{artist} {title} {ext}`，非法字符替换为 `_`，路径段按 UTF-8 百分号编码），扩展名由上游 Content-Type 决定（mp4→m4a、mpeg→mp3、flac、ogg，默认 m4a）。

通过检查后进入队列（同时只有一个任务在保存；排队上限 `queue_size`，0 表示正在保存时直接放弃）。
任务在 fork 出的子进程中运行（不触碰 Lua）：MKCOL 目录（405 忽略）→ 拉取上游响应头 → 大小超过 `max_size_mb` 跳过
→ HEAD 目标文件，已存在则跳过 → 上游数据经 `playback.buffer_kb` 大小的环形缓冲直接 PUT 到 `<名称>.part`
（上游有 Content-Length 时带长度，否则 chunked；不落盘）→ 校验大小 → `MOVE`（`Overwrite: F`）为最终文件名。
失败时 DELETE `.part`；大小未知时传输中超限即中止。子进程把进度写到 `/tmp/mico-save-*.st`（一行），主循环每秒回收子进程并读取。
成功后下次本地搜索未命中会立即重同步索引，60 秒后也会主动同步一次。所有决策写入运行日志（`[save]` 前缀，不记录密码和完整签名 URL）并在对话里记一条 `save` 步骤。

## 运行日志

C++ 与 `mico.log` 共用一个日志出口（`src/logger.cpp`）：配置 `log.file`（默认 `/tmp/mico-agent.log`，空串只写 stderr）、
`log.max_kb`（默认 512）、`log.keep`（轮转保留份数，默认 1）、`log.stderr`（同时写 stderr，默认 true）。
超过上限时 `file → file.1 → …`，总占用 ≤ `max_kb ×（keep+1）`。环境变量 `MICO_LOG_FILE` 可覆盖路径。
在音箱上请用 `>/dev/null 2>&1` 启动，不要把 stdout 重定向到 `/data`。

其他内存/磁盘占用均有上限：对话 100 轮、保存任务 20 个（队列 ≤ `queue_size`）、LLM 历史 `max_history`、
在线搜索结果缓存 200 条、工具统计按工具计数、`.bak` 每个文件一份；流代理与保存子进程都由主循环回收。

## Lua API（全局 `mico`）

| 函数 | 说明 |
|---|---|
| `mico.configure{llm={base_url,api_key,model,timeout_ms,extra}, system_prompt, max_steps, max_history}` | 配置 Agent |
| `mico.tool{name, description, parameters, handler=function(args) ... end}` | 注册工具；返回字符串或表（转 JSON） |
| `mico.ask(text)` → `reply` 或 `nil, err` | 运行一轮 Agent（含工具循环，保留多轮历史） |
| `mico.reset()` | 清空对话历史 |
| `mico.http{method,url,headers,body,timeout_ms}` → `{status, body, error}` | HTTP 请求 |
| `mico.exec(cmd [, {timeout_ms=10000, max_bytes=65536}])` → `output, code, timed_out` | 执行 shell 命令；独立进程组，超时整组 SIGKILL |
| `mico.json_encode(v)` / `mico.json_decode(s[, null])` | JSON（可选第二参数作为 JSON null 的替代值，默认 nil）；空表编码为 `{}`；非法 UTF-8 替换为 U+FFFD |
| `mico.md5(s)` / `mico.sha256(s)` | 十六进制摘要（内置实现，无 OpenSSL 依赖） |
| `mico.index_add(name, items)` / `mico.index_clear(name)` / `mico.index_size(name)` | 模糊索引；item 需含 `title`、`artist`（`/ , & 、` 分隔多歌手）、`album`，整表原样保存 |
| `mico.index_search(name, query [, {limit, min_score}])` → `{ {score, title_score, artist_score, album_score, query_score, item}, ... }` | 模糊搜索 |
| `mico.pinyin(text)` | 无声调拼音 |
| `mico.log(...)`、`mico.sleep(ms)` | 日志、休眠 |
| `mico.json_encode(v, true)` | 格式化 JSON |
| `mico.config_path()` / `mico.script_dir()` / `mico.web_port()` | `-c` 路径、脚本目录、Web 端口（未监听为 nil） |
| `mico.mdns()` | `{enabled, name, ips}` mDNS 状态 |
| `mico.listdir(dir)` / `mico.tool_remove(name)` | 列目录、注销工具 |
| `mico.version()` | `{app, git, build_time, lua, curl, compiler}` |
| `mico.now_ms()` | 单调时钟毫秒（计时用） |
| `mico.save_start{src_url, src_headers, dav_base, name, username, password, max_bytes, buffer_kb, status_path}` / `mico.proc_reap(pid)` / `mico.dav_test{url, username, password}` | 边播边存：启动子进程 / 非阻塞回收 / WebDAV 连通性检查 |
| `mico.log_config{file, max_kb, keep, stderr}` / `mico.log_tail(n)` | 日志出口配置 / 读取末尾 N 行 |
| 全局 `on_step(step)`（Lua 定义，可选） | `mico.ask` 每次 LLM 往返 `{kind="llm", name=model, ms, result|error}`、每次工具调用 `{kind="tool", name, args, result|error, ms}` 时回调 |
| `mico.json_encode(setmetatable({}, {__jsontype="array"}))` | 空表编码为 `[]` |

## 模糊搜索（`src/fuzzy.cpp`）

面向语音识别误差，按“单元”（汉字 / 英文单词）做加权最长公共子序列匹配：

| 单元关系 | 权重 | 例子 |
|---|---|---|
| 同字 | 1.0 | 晴 = 晴 |
| 同音（多音字取前两个读音） | 0.9 | 轮 = 伦，词 = 瓷 |
| 模糊音（zh/z、ch/c、sh/s、n/l、an/ang、en/eng、in/ing） | 0.75 | 兰 ≈ 蓝，三 ≈ 山 |
| 英文单词编辑距离 ≤ 1（≥4 字母） | 0.8 | |

分数 = 0.5×歌名覆盖 + 0.25×歌手覆盖 + 0.1×专辑覆盖 + 0.15×查询被解释比例；覆盖率乘以连续度，只共享一个字的多字字段记 0；
歌名中括号内容（`(Live)`）忽略。拼音表由 `tools/gen_pinyin.py` 从 mozillazg/pinyin-data 生成（U+4E00–9FFF，约 84 KB）。
本机 1 万首：建索引 32 ms，查询约 14 ms。

## 内置工具（`scripts/lib/tools.lua`）

| 工具 | 说明 |
|---|---|
| `run_shell` | 执行命令（默认 10 s 超时，最大 60 s，输出截断 4000 字节）；`MICO_ENABLE_SHELL=0` 关闭，`shell_allow` 可设白名单 |
| `http_request` | 类 curl 的 HTTP 请求 |
| `music_search` | 曲库模糊搜索（首次自动同步索引；无结果回退飞牛服务端搜索，仍无好结果时附带在线结果）；`online=true` 只搜在线音乐源插件；`kind="audio"` 搜播客/访谈等长音频 |
| `music_play` / `music_stop` / `music_now_playing` | 播放控制；`music_play` 接受本地与在线 id（`<插件名>:<id>`），裸 id 视为飞牛 guid |
| `get_time` | 时间（自定义工具示例：`scripts/tools/get_time.lua`） |

曲库索引在保存插件时自动重建，也可 `POST /api/index/sync` 手动重新同步。

自动同步（`index` 配置段）：

- `index.sync_on_start`（默认 `true`）：启动后第一次 tick（Web 已可用）即从启用的本地插件重建索引；
- `index.sync_interval_min`（默认 `360`，`0` 关闭，0–10080）：定时重建，由 C++ 主循环约每秒调用的 Lua 全局 `on_tick()` 驱动（`--once` 模式不调用）；
- `index.miss_resync_min`（默认 `10`，`0` 关闭）：本地搜索最佳分数低于 `fast_path.min_score` 且距上次同步超过该分钟数时，先重同步一次再搜。

同步失败保留旧索引并记录错误；每次同步作为 `info` 事件（`index_sync`）写入对话日志。状态见 `GET /api/status` 的 `index`
（`POST /api/index/sync` 也返回）：`{last_sync_time, last_sync_ms, tracks, last_error, next_sync_time, last_reason, syncing}`，
未发生时为 `false`；`last_reason` 为 `startup` / `interval` / `miss` / `lazy` / `manual`。

自定义工具：`tools.dir`（默认 `<脚本目录>/tools`，环境变量 `MICO_TOOLS_DIR`）下每个 `<name>.lua` 返回
`{name, description, parameters(JSON Schema 表), handler=function(args) ... end}`，启动时加载（与内置同名的跳过）。
handler 返回字符串或表（编码为 JSON）；`error()` 或返回 `{error=...}` 计为失败。
配置 `tools.disabled = {name=true}`、`tools.descriptions = {name="覆盖描述"}`；内置工具可禁用、改描述，不能编辑/删除。

快路径（`scripts/main.lua`）：“播放/我想听/来首/来点…”类请求先本地模糊搜索，结果明确时直接播放、不调用 LLM；
只匹配到歌手时随机播放该歌手的歌；有歧义交给 LLM 追问。“在线播放X”“网上找X”等前缀直接走在线搜索。

对话记录：每轮 `{id, time, source:"voice"|"web", user, route:"fast"|"llm", reply, error?, duration_ms, status,
steps:[{kind:"tool"|"llm"|"play"|"tts"|"info", name, args?, result?(截断 500 字节), ms, error?}]}`，
记录 LLM 往返、工具调用耗时、快路径决策（如 `快路径：匹配 七里香/周杰伦 0.97`）、播放 URL 与 TTS 文本。

飞牛音乐配置：编辑 `scripts/plugins/fnos.lua` 顶部 `M.config`（或网页「插件」页在线编辑），
也可用环境变量 `MICO_FN_URL`（如 `http://nas:5666`）、`MICO_FN_USER`、`MICO_FN_PASS`，可选 `MICO_FN_AUTHX_PREFIX` + `MICO_FN_CLIENT_KEY`（配置后为每个请求加 authx 签名）。

飞牛音乐的流地址必须带 Cookie，原厂播放器只接受裸 URL，因此经本地流代理播放（见上）。

脚本约定：全局 `config` 表（`instruction_log`、`poll_ms`（每轮读取）、`from_start`、`web.listen`）由 C++ 读取；全局 `on_input(text, dialog_id)` 处理每条最终识别结果。

语音接管（`scripts/main.lua`）：`on_input` 按 `takeover.mode` 分流——`off`（默认）只记录为 `route="ignored"`，不碰原生助手；`music` 先匹配 `takeover.keywords` 前缀（先把全角“，”换成“,”，跳过开头空格/标点，仅 ASCII 不区分大小写），命中则去掉关键词后走 快路径 → LLM，否则调用 `plan_fast_play`（只做搜索查找，无播报/播放）判断是否点歌，不是则直接返回交给原生助手；`all` 为接管全部。`speaker.pause_native()` 只在确定接管后调用。快路径拆成 `plan_fast_play`（决策）和 `exec_fast_play`（播报 + 播放）；`web.ask`（网页提问）不受模式影响。

`require` 会搜索脚本目录及其 `lib/`。

## 参考的 C/C++ Agent 项目

| 项目 | 语言 | 可借鉴点 |
|---|---|---|
| [heikki-laitala/ptrclaw](https://github.com/heikki-laitala/ptrclaw) | C++17 | 最接近目标：~1 MB 单二进制、插件式 provider/tool 自注册、编译期特性开关、历史压缩、mbedTLS SDK 构建 |
| [sqliteai/adam](https://github.com/sqliteai/adam) | C | 嵌入式 Agent 库：arena 分配、工具循环、SQLite 会话/记忆、guardrail 回调 |
| [ForestHubAI/fh-sdk](https://github.com/ForestHubAI/fh-sdk) | C++14 | 无异常/无 RTTI、HAL 抽象网络层，可跑在 ESP32（AGPL，仅参考设计） |
| [enkei0x/espai](https://github.com/enkei0x/espai) | C++17 | ESP32 上的多 provider 工具调用与内嵌根证书（老 OpenSSL 的 CA 问题可借鉴） |
| [solariun/easyai](https://github.com/solariun/easyai) | C++17 | Session/Tool API 设计、cpp-httplib Web UI、MCP |
| [Jimdrews/forgeant](https://github.com/Jimdrews/forgeant) | C++23 | 类型安全工具与 ReAct 循环；C++23 无法用于 GCC 6 目标，仅参考 API |

结论：没有可直接用于 GCC 6 / armv7 / 256 MB 目标的现成框架（多为 C++17–23 或依赖较重），因此自写一个很小的内核，设计上参考 ptrclaw（模块化、裁剪）与 adam（嵌入式内存习惯）。

## 下一步

1. 交叉编译：armhf GCC 6/7 + glibc ≤ 2.25 的 sysroot（取自固件 squashfs），验证 TLS 1.2 连通与 CA 证书。
2. 对话记录持久化（链接固件自带 libsqlite3），QuickJS 插件源（可选模块）。
