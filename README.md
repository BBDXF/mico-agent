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

- **Agent**：OpenAI 兼容接口（默认 SiliconFlow `Qwen/Qwen3-8B`），多轮工具调用。
- **内置工具**：`run_shell`、`http_request`、`music_search`、`music_play`、`music_stop`、`music_now_playing`；自定义工具放在 `scripts/tools/`。
- **音乐插件**：`fnos`（本地源，飞牛音乐曲库，自动跳过音箱解不了的 APE/WMA/DSD/ALAC）、在线音乐源插件（获取在线音乐，只选普通 AAC 音轨）。
- **曲库索引**：启动时同步、定时同步、搜不到时自动补同步，也可在网页上手动同步。
- **Web 控制台**（默认 `:8080`）：状态 / 对话 / 配置 / 工具 / 插件，可设访问令牌。

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
./mico-agent -c /data/mico-agent/config.json
```

打开 `http://<音箱IP>:8080`，在网页里继续配置。确认可用后，把启动命令加入开机脚本（例如 `/data/` 下的自启动脚本，按你的 root 方案而定），建议设置 `web.token`。

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

## 文档

- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：配置项、HTTP API、Lua API、插件/工具协议、模糊搜索算法。
