# mico-agent

运行在**小爱音箱内部**的轻量 AI Agent。不需要 NAS 上的额外服务、不需要中转服务器：一个约 470 KB 的 C++ 二进制 + 几个 Lua 脚本，
直接在音箱里听懂你的话、调用大模型和工具、从飞牛 NAS 或在线音乐源点歌播放。

仓库：<https://github.com/BBDXF/mico-agent>

## 和传统 AI Agent 有什么不同

| | 传统 AI Agent（LangChain / Dify / 各类 claw…） | mico-agent |
|---|---|---|
| 运行位置 | 服务器、PC 或 NAS 上的容器，音箱只是麦克风和喇叭 | **音箱本身**（armv7，256 MB 内存，`/data` 只有约 10 MB） |
| 体积与依赖 | Python/Node 运行时，几百 MB 起 | 单个 C++14 二进制，只链接固件自带的 glibc / libstdc++ / libcurl |
| 语音入口 | 需要额外的语音桥接或抓包 | 直接跟随固件的语音识别日志（`instruction.log`） |
| 点歌 | 每句话都走大模型 | **快路径**：“播放 X”在本地拼音模糊搜索后直接播放，毫秒级、不消耗 token；只有歧义或闲聊才交给大模型 |
| 识别误差 | 依赖大模型纠错 | 内置同音字 / 模糊音（zh/z、n/l、an/ang）匹配：“周杰轮的七里香”“兰莲花”都能找到 |
| 扩展 | 改代码、重新部署 | Lua 插件与工具，可在网页里在线编辑、上传、启停，保存即生效 |
| 播放 | 下载到本地或依赖云端 | 内置流代理边下边播（缓冲可调，默认 1 MB），不占用音箱存储 |

一句话：**把 Agent 塞进音箱，而不是把音箱接到 Agent 上。**

## 使用场景

- 用自然语言在音箱上点播飞牛 NAS（fnOS 飞牛音乐）里的本地曲库，口音、同音字也能找对。
- 本地没有的歌，说“在线播放 稻香”，由在线音乐源插件获取在线音乐播放。
- 让音箱回答问题、查时间、调用任意 HTTP 接口，或在音箱 Linux 上执行命令（可关闭）。
- 通过网页查看对话的每一步（快路径决策、大模型往返、工具调用耗时、播放地址），在线改配置、插件和工具。

## 功能

- **语音接管**（`takeover.mode`，默认 `off` 关闭）：`off` 不接管任何语音，小爱原生助手（闹钟、智能家居等）照常工作；`music` 只接管点歌（快路径能直接播放的请求）和以接管关键词（`takeover.keywords`，默认“请问,问问AI,小爱AI”）开头的话；`all` 接管所有语音。只有真正接管时才暂停原生助手；网页提问不受模式影响。
- **Agent**：OpenAI 兼容接口（默认 SiliconFlow `Qwen/Qwen3-8B`），多轮工具调用。
- **内置工具**：`run_shell`、`http_request`、`music_search`、`music_play`、`music_stop`、`music_now_playing`；自定义工具放在 `scripts/tools/`。
- **音乐插件**：`fnos`（本地源，飞牛音乐曲库，自动跳过音箱解不了的 APE/WMA/DSD/ALAC）、在线音乐源插件（获取在线音乐，只选普通 AAC 音轨）。
- **曲库索引**：启动时同步、定时同步、搜不到时自动补同步，也可在网页上手动同步。
- **边播边存**（默认关闭）：播放在线音乐源的歌曲时，同时经 WebDAV 保存到 NAS（按时长 / 关键词过滤，自动去重；保存前由大模型规范歌手/歌名并修正同音字，歌手按本地曲库写法校正，非原曲或无法确定歌手时不保存），之后本地曲库即可直接播放。
- **Web 控制台**（默认 `:8080`）：状态 / 对话 / 配置 / 工具 / 插件，可设访问令牌。
- **局域网域名**：内置 mDNS 应答（音箱固件没有 mDNS 服务），可直接用 `http://mico.local:8080` 访问，并发布 `_http._tcp` 服务供服务发现工具查看。

## 部署

### 1. 准备

- 已 root 并开启 SSH 的小爱音箱 Pro（LX06 / L06A，固件 1.77.6 已验证依赖兼容）。
- 一个 OpenAI 兼容的大模型 API Key。
- 可选：飞牛 NAS 上的飞牛音乐账号。

### 2. 下载

从 [Releases](https://github.com/BBDXF/mico-agent/releases) 下载 `mico-agent-<版本>-armhf.tar.gz`（`x86_64` 包用于在 PC 上试用）。

### 3. 安装到音箱

```sh
scp mico-agent-*-armhf.tar.gz root@<音箱IP>:/data/
ssh root@<音箱IP>
cd /data && tar xzf mico-agent-*-armhf.tar.gz && mv mico-agent-*/ mico-agent && cd mico-agent
cp config.example.json config.json
vi config.json                      # 填 llm.api_key，可改 model / base_url
vi scripts/plugins/fnos.lua         # 顶部 M.config 填 NAS 地址、账号、密码（也可稍后在网页里改）
./mico-agent -c /data/mico-agent/config.json >/dev/null 2>&1 &
```

运行日志写到 `/tmp/mico-agent.log`（内存盘，按 `log.max_kb` 自动轮转，有上限），可通过 `GET /api/logs?lines=200` 查看。
不要把输出重定向到 `/data` 下的文件，否则会无限增长占满空间。

打开 `http://mico.local:8080`（或 `http://<音箱IP>:8080`），在网页里继续配置。
**语音接管默认关闭**（启动日志会提示 `takeover: off`）：在网页“配置”页把“语音接管模式”（`takeover.mode`）改为 `music`（推荐，只接管点歌和关键词开头的话）或 `all`，保存即生效；也可在 `config.json` 写 `"takeover": {"mode": "music"}`。
主机名可在配置 `mdns.hostname` 修改；部分 Android 浏览器不能解析 `.local`，此时请用 IP 访问。确认可用后，把启动命令加入开机脚本（例如 `/data/` 下的自启动脚本，按你的 root 方案而定），建议设置 `web.token`。

> `/data` 空间很小且可能被系统清理，请自行备份 `config.json` 和改过的插件。

### 4. 在 PC 上试用

```sh
make && make test                    # 依赖 g++、libcurl 开发包
python3 tools/mock_fnos.py ~/Music --port 5666 &   # 用本地音乐目录模拟飞牛（账号 test/test）
MICO_DRY_RUN=1 MICO_FN_URL=http://127.0.0.1:5666 MICO_FN_USER=test MICO_FN_PASS=test \
MICO_LLM_API_KEY=sk-xxx build/mico-agent
```

`MICO_DRY_RUN=1` 只打印音箱命令、不执行。打开 <http://localhost:8080>，在“对话”页发送“播放晴天”试试。

### 5. 自己编译 armhf 版

```sh
make CROSS=arm-linux-gnueabihf- dist  # 需要 GCC 6 / glibc ≤ 2.25 的交叉环境，CI 使用 debian:stretch
```

推送 `v*` 标签时 GitHub Actions 会自动编译、检查 ABI 并发布 Release。

## 已知限制

- 原厂播放器基于精简版 FFmpeg：支持 MP3 / FLAC / AAC(m4a) / OGG / Opus / WAV，不支持 APE、WMA、DSD、ALAC、杜比音轨。
- 在线音乐源的音频格式（分段 m4a）的真机播放、飞牛是否强制 authx 签名，仍待更多设备验证。
- 边播边存：fnOS WebDAV 是否接受分块上传（源未给出文件大小时）、保存的 m4a 能否被飞牛音乐识别，待真机验证。
- 边播边存的歌名规范化在主线程同步调用大模型（默认超时 8 秒），期间新的语音指令会稍有延迟。

## 更新记录

### v0.2.2

- **语音接管模式**：新增 `takeover.mode`（`off` 默认 / `music` / `all`）与 `takeover.keywords`（逗号分隔，中英文逗号均可，英文不区分大小写）。此前每句话都会暂停原生助手并交给本程序，导致闹钟、智能家居等失效；现在默认不接管，需在配置页开启。`music` 模式先无副作用地判断是否为点歌（快路径），只有接管时才暂停原生助手；未接管的话在对话记录中标为 `ignored`。`GET /api/status` 新增 `takeover`。
- **局域网域名（mDNS）**：内置精简 mDNS 应答器，`http://mico.local:8080` 即可打开控制台；同时发布 `_http._tcp` 服务（TXT 含 `path=/`、`version`）。启动时广播两次，Wi-Fi 重连 / 地址变化后自动重新广播，退出时发送下线通知。配置 `mdns.enabled` / `mdns.hostname` / `mdns.instance`，保存后约 1 秒生效；环境变量 `MICO_MDNS=0` 可关闭。`GET /api/status` 新增 `mdns{enabled,name,ips}`。

### v0.2.1

- **在线音乐源只放单曲**：在线搜索歌曲只取短视频并优先音乐分区，按时长（`online.song_min_s`–`online.song_max_s`，默认 90–480 秒）和关键词（`online.skip_keywords`，合集 / 串烧 / 循环 / 伴奏等）过滤，按名称匹配度和播放量排序；绝不播放超长的合集。
  - 没有单曲时从分 P 视频和合集里挑出歌名匹配的那一集播放（只额外查看前 3 个候选）。
  - “在线播放阿杜的歌”这类只说歌手的请求：随机播放该歌手的一首单曲（不建播放队列）；本地曲库有该歌手时仍优先本地。
- **非歌曲内容**：播客、访谈、讲座、相声、评书、有声书、节目、脱口秀、新闻等直接在线搜索长音频（上限 `online.audio_max_s`，默认 4 小时，短于 60 秒的不放），`music_search` 新增 `kind="audio"` 参数；这类内容不会边播边存。
- 对话记录里能看到每次在线筛选的条数、选中的分集与类型。
- 与边播边存兼容：从分集中挑出的歌只保存该集（按该集自身的标题与时长判断），只说歌手时由大模型整理歌名后保存；新增对应测试。

### v0.2.0

- **边播边存**（默认关闭）：在线音乐源的歌曲边播放边经 WebDAV 流式保存到 NAS，不占音箱存储，支持大文件。
  - 先上传为 `.part`，校验大小后重命名，失败自动清理；同名文件跳过。
  - 可配置时长范围、文件大小上限、过滤关键词、排队数量（`save.queue_size`）。
  - 保存前由大模型规范歌手 / 歌名（修正同音错字、去掉 MV / Live / 无损等修饰，判断是否原曲），歌手按本地曲库写法校正；不确定或缺歌手时不保存，大模型不可用时回退规则命名。
  - 保存成功后自动重新同步曲库，之后同一首歌直接走本地。
  - 状态页显示最近保存记录与进度，配置页可测试 WebDAV 连接，`[save]` 日志记录每一步。
- **日志有上限**：写入 `/tmp/mico-agent.log` 并按大小轮转（默认 512 KB × 2 份），新增 `GET /api/logs`；终端输出不会再阻塞程序。
- 新增 Lua `mico.complete`（不带工具、不进历史的一次性大模型调用）。
- 修复：过滤关键词按中文逗号拆分时误伤中文歌名。

### v0.1.0

- 首个版本：C++14 + Lua 5.1 内核、拼音模糊搜索与点歌快路径、飞牛本地源与在线音乐源插件、流代理播放、Web 控制台（状态 / 对话 / 配置 / 工具 / 插件）、曲库自动同步、armhf 交叉编译与 CI 发布。

## 文档

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：配置项、HTTP API、Lua API、插件/工具协议、模糊搜索算法。
