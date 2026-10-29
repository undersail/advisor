# Advisor 设计文档

> 轻量级 AI 智能体，目标是让抽屉里的旧 Intel Mac（Snow Leopard ~ High Sierra 世代）
> 重新变成一台能用的机器。命令名 `advisor`，刻意取中性名，让用户不必在意背后是
> Claude 还是 Gemini。
>
> 本仓是 [`watermark-hd/advisor`](https://github.com/watermark-hd/advisor) 的 fork，
> 以 `upstream` remote 跟踪上游。上游 MIT 授权，日英双语。

**版本基线**：`advisor (high_sierra_claude) 0.1` · 上游 HEAD `7ab0b24`（2026-09-21）

---

## 1. 设计约束（一切的出发点）

这四条决定了后面所有取舍，改动代码前先读：

| 约束 | 含义 | 违反后果 |
|---|---|---|
| **零依赖** | 智能体是单文件 Perl，**不允许任何 CPAN 模块**；GUI 只用 Python 标准库 tkinter | 老机器装不上 / 安装链断裂 |
| **老 OS 兼容** | 目标机 perl 5.8.6+、bash 3.2、LibreSSL 无 `-pbkdf2`、High Sierra 的 VSCode 只到 1.85 | 用了新语法 = 整台机器用不了 |
| **完全离线可用** | 除 API 调用外不联网、不装包、不依赖 CDN | 内网/断网场景失效 |
| **隐私默认开启** | 对话历史必须加密落盘，家人共用一台 Mac 也读不到 | 核心卖点丢失 |

一句话：**「能在 2010 年的机器上双击跑起来」比「代码漂亮」优先。**

---

## 2. 架构总览：单后端 + 双前端

```
        ┌──────────────────────────────┐
        │  agent/claude-agent.pl       │  ← 唯一的智能体实现（2172 行）
        │  单文件 / 零 CPAN / Perl     │
        └───────┬──────────────┬───────┘
                │              │
     终端模式（默认）      GUI 模式（--gui）
     print / STDIN        STDOUT 输出 1 行 1 个 JSON
                │              │ STDIN  读入 1 行 1 个 JSON
                ▼              ▼
        ┌──────────┐    ┌─────────────────────┐
        │ Terminal │    │ gui/advisor_gui.py  │  tkinter（1796 行）
        │  .app     │    │ 子进程 + 队列 + 主题 │
        └──────────┘    └─────────────────────┘
```

**关键设计：智能体本身完全不知道前端是谁。**

所有输出都经过 `emit_*` 抽象层，会话循环和 `run_tool` 里没有一个 `$GUI` 判断：

| 函数 | 终端模式 | GUI 模式 |
|---|---|---|
| `emit_text` | `print "\n$PROVIDER> $text"` | `{"t":"text","text":...}` |
| `emit_tool` | `[tool_use] name({...})` | `{"t":"tool","name":...}` |
| `emit_status` | `... $text` | `{"t":"status","text":...}` |
| `emit_error` | 原文打印 | `{"t":"error","text":...}` |
| `emit_note` | 原文打印 | `{"t":"note","text":...}` |

新增一种输出时，**必须同时补终端与 GUI 两条路径**，否则某个前端会静默丢消息。

---

## 3. 进程与通信协议

GUI 通过 `subprocess.Popen` 拉起后端，`stderr` 直接丢弃（`DEVNULL`），只走
STDOUT/STDIN 的 JSON 行协议：

```python
# gui/advisor_gui.py::_start_backend
subprocess.Popen(cmd, env=env, stdin=PIPE, stdout=PIPE,
                 stderr=DEVNULL, bufsize=1,
                 universal_newlines=True, encoding="utf-8")
```

> 之所以用「子进程 + JSON 行」而不是 import 或 socket：Perl 与 Python 之间没有
> 共享库，JSON 行是这个约束下最省事的 IPC，且天然支持流式输出。

### 3.1 后端 → GUI

| `t` | 载荷 | GUI 行为 |
|---|---|---|
| `ready` | `provider`, `model`, `models[]`, `history` | 填充模型菜单、置空闲、写状态栏 |
| `text` | `text` | 含 ``` 走 `_render_reply` 一次性着色；否则 `_stream_append` 逐字流式 |
| `tool` | `name`, `input` | 灰色显示"正在使用工具" |
| `status` | `text` | 更新底部状态栏 |
| `error` | `text` | 红色追加 |
| `note` | `text` | 灰色追加（模型切换完成等） |
| `model` | `provider`, `model` | 更新菜单「← 使用中」标记 |
| `confirm` | `prompt` | 弹 yes/no，回 `{"t":"reply","value":"y"/"n"}` |
| `need_passphrase` | `prompt`, `recover` | 弹口令框 |
| `need_recovery` | `mode`, `question` | 弹合言葉框 |
| `need_key` | `provider` | 弹内嵌 API key 注册页 |
| `history_list` | `items[]` | 历史选择对话框 |
| `history_loaded` | `entries[]` | 重绘历史对话 |

### 3.2 GUI → 后端

| `t` | 载荷 | 说明 |
|---|---|---|
| `user` | `text` | 用户提问 |
| `reply` | `value` | `y` / `n`，回答确认提示 |
| `passphrase` | `value` | 历史口令 |
| `recovery` | `value` | 合言葉答案 |
| `key` | `provider`, `value` | 新注册的 API key |
| `cwd` | `path` | 切换工作目录 |
| `resume` | `index` | 继续某条历史 |
| `list_history` | — | 请求历史列表 |
| `quit` | — | 退出（后端所有 `gui_read_typed` 都把它当作终止信号）|

**协议不变量**：`gui_read_typed($want)` 会**跳过**所有非期望类型的行，并在遇到
`quit` 时立即返回 undef。因此新增事件类型时，必须确认没有哪个等待方会被它卡住。

---

## 4. 智能体核心（Perl）

### 4.1 工具集

| 工具 | 是否需要确认 | 说明 |
|---|---|---|
| `read_file` | 否 | 读文件 |
| `list_dir` | 否 | 列目录 |
| `write_file` | **是** | 写文件前 y/n 确认 |
| `run_shell` | **是** | 执行命令前 y/n 确认 |

系统提示里有一条**专门写给模型的行为约束**（见 `$SYSTEM_PROMPT`）：确认被拒
**只代表这一次被拒**，不代表环境禁用了工具，不许因此宣称"写文件/执行被禁用"，
而应停下来说明打算做什么、问用户想怎么调整、然后再试一次。

> 这是踩过的坑写进 prompt 的典型例子。改 prompt 时不要删掉这段。

### 4.2 多提供商：内部格式统一

**内部对话历史永远用 Anthropic 的 content blocks 格式**，只有在调用 Gemini 的
前后做一次边界转换。因此工具执行、输入处理、历史渲染的代码完全不需要感知提供商。

```
内部（Anthropic content blocks）
        │
        ├── provider=anthropic ──→ POST https://api.anthropic.com/v1/messages
        └── provider=gemini    ──→ POST .../v1beta/models/$MODEL:generateContent
                                    （contents / parts 转换）
```

> **已实现（M3）**：分派点已收敛到 `agent/claude-agent.pl` 的 `my %PROVIDERS` 注册表。
> 每个条目声明 `key_env / auth / model_prefix / default_model / url|url_template /
> api_version / build / parse`，`configure_provider`、`build_headers`、
> `build_request`、`parse_response` 四处都改成「查表 + 调用」。
> 新增提供商 = 注册表加一个条目 + 一对 `build_*`/`parse_*` 函数，
> 不再需要在 4 个地方同步改 if/elsif。
> 辅助函数：`provider_spec($name)`（未注册即 die）、`provider_for_model($id)`
> （按 `model_prefix` 反查，都不匹配时回落 `anthropic`）、
> `provider_from_command($cmd)`（`/claude` `/qwen` 等命令名 → provider，别名见
> `%PROVIDER_ALIAS`）。

**M4 起扩到 7 个（2026-10）**：`anthropic` / `gemini` / `openai` / `deepseek` /
`dashscope`（通义千问）/ `moonshot`（Kimi）/ `zhipu`（GLM）。后五家都走 OpenAI
兼容协议，**共用同一对 `build_request_openai` / `parse_response_openai`**，
彼此只差 `key_env`、`default_model`、`base_url`。新增厂商 = 注册表加一条目 +
`models.txt` 加一行。

OpenAI 兼容格式与内部格式（Anthropic content blocks）的对应关系：

| 内部（始终用这个） | OpenAI 兼容请求 |
|---|---|
| `system` 参数 | `messages[0] = {role:'system'}` |
| `{type:'text'}` | 同一条消息的 `content`（多段用 `\n` 拼接）|
| `{type:'tool_use', id, name, input}` | `assistant.tool_calls[]`，`arguments` 是 **JSON 字符串** |
| `{type:'tool_result', tool_use_id, content}` | 独立的 `{role:'tool', tool_call_id, content}` 消息 |
| `tools[].name/description/input_schema` | `{type:'function', function:{name, description, parameters}}` |

两个一定要记住的坑：
- **`tool_result` 不能像 Anthropic 那样塞进 user 消息数组**，必须是独立的
  `role:'tool'` 消息，靠 `tool_call_id` 关联。
- **`reasoning_content`（DeepSeek-R1 等的思考日志）不能回传**，否则 API 返回 400。
  适配器在解析阶段就丢弃，历史里不会存在。

其他机制：
- `base_url` 的优先级：`models.txt` 该行的 base_url → `CLAUDE_BASE_URL` → 注册表默认。
- `notools` 旗标（`models.txt` 第 7 列）会让请求不带 `tools`，用于不支持函数调用的模型。
- API 端点默认是 `<base_url>/chat/completions`，末尾斜杠会被吃掉。

**四个数据面的分工（M4 起）**：

| 文件 | 管什么 | 谁读 |
|---|---|---|
| `agent/claude-agent.pl` `%PROVIDERS` | 协议实现：鉴权方式、URL 形态、build/parse 函数 | Perl |
| `providers.txt` | 厂商数据：`key_env`、`default_model`、`key_url`、三种语言的显示名 | Perl（菜单）+ Python（GUI 首启/菜单）+ CI |
| `models.txt` | 模型清单：id、三种语言的说明、所属 provider、base_url、flags | Perl + Python + CI |
| `scripts/check-models.py` | 三者一致性卡口 | CI |

`key_env` / `default_model` **只写在 `providers.txt`**。把它们同时留在注册表里
就等于两处各写一份，改一处忘一处时程序不会报错、只会去读一个空环境变量然后
说「请设置 undefined_API_KEY」。CI 现在会拦下这种重复。

**两级模型菜单（终端与 GUI 各自实现，语义一致）**：

- 终端：`/model` → 按 `providers.txt` 的**文件顺序**列厂商 → 输数字 → 列该厂商
  的模型 → 输数字切换。只按回车取消；输非法编号给出提示并停在同一层。
  段位状态只活一轮 —— 任何其它输入都会把它清掉，避免「上一个菜单留下的号码
  把后面的普通发言当成选择」。
- GUI：菜单栏里按厂商分 `cascade` 子菜单，**点击时发 `/model <id>` 而不是编号**
  （编号依赖列表顺序，插一条模型就会错位）。
- 两级菜单只是显示层的变化：`/model 3`、`/model <id>` 这两种老写法照旧可用。

**setup.sh 也读同一张表（M4 收尾）**：安装脚本原来只有「1) Gemini / 2) Anthropic」
两个写死的分支，加上两套厂商专属的「点哪里」步骤和密钥前缀检查。现在改成：

- 厂商清单 / 密钥变量名 / 默认模型 / 密钥页 URL 全部从 `providers.txt` 取
- 厂商专属的「第 1 步、第 2 步……」删掉了 —— 各社控制台改版频繁，7 家 × 3 语言
  的手写步骤必然腐坏。只给密钥页 URL，详细说明留给 README
- 密钥前缀检查（`AIza` / `sk-ant-api`）删掉 —— 那是对两家的刻意外推，对第三家
  起就是无意义的警告
- 连通性测试按「认证形状」分三支：gemini（模型 ID 嵌 URL）/ anthropic（专属头）/
  其余（Bearer + `<base_url>/chat/completions`），base_url 从 `models.txt` 取
- 包装脚本 `advisor` 里的 `provider_of()` 原本是「gemini 开头→gemini，其余→
  anthropic」，现在查 `models.txt` 的 provider 列；新增 `keyvar_of()` 查
  `providers.txt`

⚠️ `setup.sh` 里**不能用 bash 4 特性**（`mapfile`、关联数组）—— macOS 自带的是
bash 3.2，用了在真机上直接报错。厂商表用普通索引数组读。

需要注意的 Gemini 特例：
- **`thoughtSignature`**：Gemini 3 系在回传 `functionCall` 时必须原样带上，
  否则 400。转换层要保住这个字段。
- **thinking 默认 `LOW`**，可用 `CLAUDE_GEMINI_THINKING=high` 调深 —— Gemini 对
  简单问题也爱长时间思考，默认值是为体验调的。

`MAX_TOKENS = 4096`（两个提供商共用）。

### 4.3 不用模块的实现

- **JSON**：`MiniJSON` 包（`encode` / `decode` / `_decode_*`）是自研递归下降
  解析器。**没有 JSON::PP**。改它要同时跑通 encode/decode 双向往返。
- **HTTP**：`curl` 子进程（`call_api`）。TLS 不放在 Perl 侧 —— 这正是能在
  High Sierra 的旧 curl 上跑通的原因，也是 Tier A 能靠换 `CLAUDE_CURL` 解决的前提。
- **加密**：`openssl enc -aes-256-cbc` 子进程。密钥通过**环境变量**传给 openssl，
  绝不出现在命令行参数、`ps` 输出或磁盘上。

### 4.4 输入编码的坑（不要"优化"掉）

`STDIN` **故意保持生字节**，不加 `:encoding` 层。原因写在源码注释里：

> Perl 5.8.6 的 `PerlIO :encoding(UTF-8)`，在键盘逐字节到达的交互式读取下，
> 会在多字节字符中间截断缓冲区，报 `utf8 does not map to Unicode`。
> 管道整体输入不重现。所以改成读完一行、字节齐全后再统一 decode。

同理，`STDOUT` 加了 encoding 层后自动 flush 会失效，所以有显式 `$| = 1` 和手动
flush；`read_line_interactive` 会把终端切 raw 模式，因此 `restore_tty` 要保证
任何退出路径都还原终端（否则用户终端会瞎掉）。

---

### 4.6 平台端收发（M6 第二批）

```
手机 ──(平台回调, 验签+AES)──> platform.pl ──(--stdin)──> gateway.pl ──> agent
     <──(平台发消息 API)──────────┘
```

- `platform.pl` 只做三件事：**验签、解密、把回复推回平台**。
- 白名单、审计、只读工具集、独立历史全部在 `gateway.pl` —— 判定只有一处，
  平台端不重复实现（`scripts/check-decoupling.py` 守着 `run_shell` 不进远程工具）。
- 企微：回调签名 `sha1(sort(token,timestamp,nonce,encrypt))`；明文 = 随机16 + 长度4 +
  消息 + **ReceiveId(=CorpID)** + 32 字节块填充，IV = AESKey 前 16 字节。
  ReceiveId 必须等于本企业 CorpID —— 这是规范里的完整性校验，只做 PKCS#7 判断不够
  （密文被改时填充仍可能合法）。
- 飞书：签名 `sha256(timestamp + nonce + EncryptKey + body)`；密文
  `base64(IV + AES-256-CBC(sha256(EncryptKey)))`。
- AES 走系统 `openssl`（与用系统 curl 一致），零 CPAN。
- 平台要求 5 秒内应答，所以先回 200 再 `fork` 后台跑 agent，结果异步推回。
- 凭据由使用者 `--init` 录入，存 `~/.claude-agent/platform.conf`（0600）。

### 4.5 远程接入的分层（M5）

远程功能**不写在核心里**。核心里只有两个通用能力，远程用它俩搭起来：

| 通用能力 | 参数/环境变量 | 语义 |
|---|---|---|
| 能力收窄 | `--tools=read_file,list_dir` | 只允许列出的工具；未知名字直接报错退出。只能收窄，不能扩权。 |
| 历史目录覆盖 | `CLAUDE_HISTORY_DIR` | 指定历史落盘位置；核心不关心为什么。 |

在这之上是 `remote/` 三个文件：

- `remote/gateway.pl`：唯一的远程入口。白名单（`ALLOW`，为空即全部丢弃）、
  审计（`~/.claude-agent/audit.log`，只追加、0600）、每个发送者一个常驻
  agent 子进程（保持上下文）、工具集**写死** `read_file,list_dir`、历史目录
  **写死** `~/.claude-agent/history-remote`、单轮 180 秒超时熔断。
- `remote/notify.pl`：档① 出站通知。企微用 `markdown`、飞书用 `text`；
  平台返回 HTTP 200 但 `errcode != 0` 也算失败（企微对无效 key 就是 200）。
- 会话协议：网关 ↔ agent 走 `--rpc`（与 `--gui` 同一套 JSON 行协议）。

### 4.5.1 第三种入站形态：企微长连接（`remote/wecom-ws.pl`）

回调模式（`platform.pl --serve`）在绕一个前提：**家里的 Mac 没有公网可达地址**。企微智能机器人的「API 模式 · 使用长连接」把方向反过来——**本机连出去**：

```
手机 ──(企微长连接 wss)──> wecom-ws.pl ──(--stdin)──> gateway.pl ──> agent
```

于是：不需要公网域名、不需要内网穿透、不需要 Cloudflare 账号，凭据只有 BotID + Secret，
也没有 AES 与验签。分层的做法与前两种完全一致——这个文件**只做传输**（握手、帧编解码、
心跳、重连、按 req_id 回包），白名单 / 审计 / 只读工具集仍然只由 `gateway.pl` 决定，
`check-decoupling.py` 会拦住任何「在这里读 `ALLOW`」或「在这里自己起 agent」的写法。

代价写在明处：零 CPAN 约束下 perl 核心没有 TLS，wss 借用 `openssl s_client` 子进程当管道，
WebSocket 帧（mask / 分片 / ping-pong / close）手写实现。这一段无法在 CI 里连真平台，
所以自动化只覆盖协议与业务（本机假服务端 35 项），真连验收放到 `manual_test_mac.md` §9.8。

### 4.5.2 飞书长连接：方案已记录，**暂不实现**

飞书开放平台同样提供「使用长连接接收事件」：与开放平台建一条 WebSocket 全双工通道，
**建连时鉴权一次，之后的事件是明文**，不需要公网 IP、不需要 EncryptKey 解密、不需要验签。
方向与企微长连接完全一致。

**为什么先不做**：

1. 飞书把它定义为「**SDK 内提供的能力**」，没有发布独立的协议规范（企微相反：文档 101463
   直接把 `cmd` / `headers` / `body` 逐字段写死，照文档就能实现）。
2. 零 CPAN 意味着不能用官方 SDK，只能照着某个 SDK 的源码反向实现握手、鉴权与帧格式。
   一旦哪天飞书改了内部细节，我们没有文档可依，只能靠读新版 SDK 猜。
3. 企微这一条已经覆盖了「手机 → 家里 Mac」的主场景；飞书目前仍可用回调模式（`platform.pl`，
   需要公网域名）。

**真要做时怎么落**（保持同一套分层）：

```
飞书长连接 wss ──> remote/feishu-ws.pl ──(--stdin)──> gateway.pl ──> agent
                        ↑ 只做传输：握手、鉴权、帧、心跳、重连
```

- 配置独立：`~/.claude-agent/feishu-ws.conf`（0600，App ID + App Secret）
- 复用现成零件：TLS 管道（`openssl s_client`）、WebSocket 帧编解码、心跳与重连退避、
  pending 回执表 —— 这些在 `wecom-ws.pl` 里已经验证过，可以抽成 `remote/lib/` 共享，
  **但抽之前要先确认企微那条仍然全绿**（先抽再改是最容易把两条都弄坏的顺序）
- 判定一律仍然只在 `gateway.pl`；`check-decoupling.py` 里那条断言同样适用于新文件
- 验收步骤照 §9.8 的形状写一份，第一条仍然是「只验凭据、不启动 agent」

**为什么只读是硬编码而不是开关**：远程没有人在旁边按 y/n。一个"临时打开"
的开关，迟早会被常开。所以 `check-decoupling.py` 把"远程工具只能是
read_file / list_dir"和"工具集不可配置"变成 CI 卡口。

**凭据处理**：webhook URL 本身即凭据（带 key/hook token）。`notify.pl` 用
`curl -K -` 从标准输入喂配置，URL 不进程命令行、不进 `ps`、不进日志；输出
里只打目标名（`WECOM_WEBHOOK` / `FEISHU_WEBHOOK`）。

### 4.5.3 远程权限：档位在 Mac 上选好，确认在手机上回（2026-10 口径）

**规则（用户定）**：远程不是「只能看」。权限管控跟本机一样，在 Mac 上启动远程服务时选好
档位（如可编辑），**启动之后手机端改不了**；遇到需要确认的操作，由用户在手机端回 y/n。

```
Mac 启动时：wecom-ws.pl --serve --mode=accept-edits --allow-write=/Users/Jack/proj
                              ↓ 只在启动参数里（命令行 > wecom-ws.conf）
                        gateway.pl  --mode / --allow-write / --confirm-wait
                              ↓ 透传
                 agent --rpc --no-config --tools=… --mode=… --allow-write=…
                              ↑ {t:"confirm"} ↓ {t:"reply"}
                     gateway 转成一行 ask → 手机 「需要你确认：…（y/n）」
                              ↑ 用户回的 y/n 当答案；超时 120 秒按拒绝
```

**四条不变量**

| 不变量 | 守住它的地方 |
|---|---|
| 档位只来自启动参数（不认配置、不认环境变量、更不认聊天消息） | `check-decoupling.py`：gateway 里出现 `$conf->{REMOTE_MODE}` / `CLAUDE_MODE` / `$j->{mode}` 立刻红 |
| 判定只有一处：`writable_mode()` 只认 `accept-edits` / `bypass`，其余一律只读 | 卡口断言这两个字面量必须存在 |
| 确认必须转给手机，不许静默拒绝（否则写操作会一路超时） | 卡口断言 `sub ask_remote` 存在 |
| 回应键必须是 `reply`，超时按拒绝 | 单测 `test-gateway-write` 里 y / n / 超时 三条 |

**单实例与退出**：`--serve` 在 `~/.claude-agent/wecom-ws.pid` 上加 `flock` 独占，
第二个实例立刻以退出码 3 被拒（两个实例会把同一条消息各处理一遍，文件和钱都可能动两次）；
pid 文件里写 `pid` / `mode` / `allow_write` / `started`（不含密钥），GUI 的状态行只读它。
INT / TERM / HUP 都走优雅退出：审计 `ws_stop`、删 pid、放锁。细节见 `docs/ops_remote.md`。

**代价（写在这里，别忘）**：开 `accept-edits` 之后，手机 = 一份能改代码的凭据（白名单内的人）。
手机丢了的风险从「只能读」变成「能改」。所以默认仍是只读，放宽必须显式在启动时写出来；
危险命令三档都还要确认（`bypass` 也不豁免），审计里记 `mode=` / `roots=` / `confirm_asked` /
`confirm_answered`（含 `timeout=1`）。

**顺带修掉两个此前藏着的 bug**：①网关回应确认用的键是 `confirm_answer`，agent 只认 `reply`
—— 只读模式下看不出来，一旦放开写就会一路等到超时；②网关 STDOUT 没自动刷出，确认问题会
卡在缓冲区里到不了手机。

## 5. 加密历史：密钥层级

```
        master key（随机，AES-256-CBC 用它加密每条会话）
          ├── key.enc          ← 用【口令】包起来
          └── key.recovery.enc ← 用【合言葉答案】包起来（可选）
                                 问题明文存在 key.recovery.q
```

两条恢复路径都能取出同一把 master key，所以忘记口令还能用合言葉救回来。

| 路径 | 内容 |
|---|---|
| `~/.claude-agent/history/<时间戳>.json.enc` | 单次会话（加密） |
| `~/.claude-agent/history/key.enc` | 口令包裹的 master key |
| `~/.claude-agent/history/key.recovery.enc` | 合言葉包裹的 master key |
| `~/.claude-agent/history/key.recovery.q` | 合言葉**问题**（明文） |
| `~/.claude-agent/history/.check` | 旧格式遗留；存在则走 `migrate_check_file` 迁移 |
| `~/.claude-agent/session.log` | 运行日志（chmod 0600） |
| `~/.claude-agent/gui.json` | GUI 配置（主题、上次模型等） |
| `~/.claude-agent-env` | 环境持久化（`CLAUDE_PROVIDER` / 模型 / key） |

### 已知弱点（承重，不要假装不存在）

- High Sierra 的 LibreSSL **不支持 `-pbkdf2`**，键导出只能用 MD5 派生 → 强度偏弱。
  定位是"远好于明文躺着"，不是"军事级"。
- 合言葉答案通常可猜 → 这是整个方案最薄的一环。UI/文档都应引导用户别用
  「第一辆车的名字」这类问题。
- **口令与合言葉同时丢失 = 历史不可恢复**。这是设计，不是 bug。
- `CLAUDE_NO_HISTORY=1` 时根本不问口令。

---

## 6. GUI 层（tkinter）

- **三主题**：`note`（带横线的笔记本）、`coding`、`hacker`（黑底绿字）。
  `THEMES` 字典集中管理，`_apply_theme` 统一切换。
- **横线/网格背景**用 Canvas 画洞和格子（`_draw_holes` / `_draw_grid`），
  通过 `_request_draw_*` 增量重绘，避免整窗重画造成卡顿。
- **流式输出**：`_stream_append` / `_stream_step` 逐字入文本框；但**含代码围栏
  的回复走一次性 `_render_reply`**，否则着色器会在未闭合的 ``` 上反复出错。
- **线程模型**：`_reader` 线程只做 `stdout → json → queue`，绝不碰控件；
  `_pump` 用 `root.after(80, ...)` 在主线程消费队列。**所有 UI 操作都在主线程。**
- **内嵌 key 注册**：首次启动无 key 时，不弹终端，直接在窗口里选提供商 →
  打开取 key 页面 → 粘贴 → 后台线程 `validate_api_key` → 通过后进主界面。
- **i18n**：`_detect_lang()` 读 macOS 的 `defaults read -g AppleLocale`（而不是
  `LANG`，因为 GUI 应用启动时 `LANG` 可能是空的）。文案集中在 `_S` 字典，
  用 `L(key, **kw)` 取。原生菜单栏用 pyobjc 本地化（`_localize_native_app_menu`）。
- **输入框**：避开 Terminal.app 的双字节输入问题，直接用 OS 的日文输入法。

---

## 7. 安装与分发

两条路，对应两类用户：

### ① 普通用户：standalone zip（不碰终端）

`release/build_standalone_app.sh` 用 **py2app** 打包成 `Advisor.app`，塞进 zip，
附带 `ReadMe_JP.txt` / `ReadMe_EN.txt`（讲清 Gatekeeper 首次右键「打开」的流程）。
未做 Apple Developer ID 签名 → 首次启动必有"未确认的开发者"警告，这是**预期**
行为，不是 bug。构建失败时自动降级为简化版 app，保证 `advisor` 命令一定可用。

### ② 开发者：`bash setup.sh`

`setup.sh`（702 行）负责：选择 Gemini/Anthropic → 引导并保存 key → 装
`~/bin/advisor`（bash 包装器）→ 装 bash 补全 → 生成 `Advisor.app` → 跑一次
连通性自检。首次会装 Xcode CLT（签名用，~190MB）、py2app、pyobjc（~7MB）。

> **职责划分**：参数解析、模型选择菜单都在 `~/bin/advisor` 这个 bash 包装器里；
> `agent/claude-agent.pl` 只保持**纯粹的对话循环**。新增 CLI 选项优先加在包装器。

### Tier 分层

| Tier | OS | 状态 | 关键点 |
|---|---|---|---|
| **B** | 10.9 Mavericks ~ 10.13 High Sierra+ | ✅ 已实现 | 标准 curl 已支持 TLS1.2，开箱可用 |
| **A** | 10.6 Snow Leopard ~ 10.8 Mountain Lion | ❌ 未实现（维护者已决定先不做） | 需在别的机器上编译 OpenSSL/curl 再传过去 |

Tier A 的接口已经预留：`CLAUDE_CURL` / `CLAUDE_CACERT` 可指向自建 toolchain；
`setup.sh` 若发现 `~/claude-toolchain` 会优先使用它。

---

## 8. 环境变量一览

### 8.0 密钥的写入与读取（不变量）

**密钥只有两个入口：安装流程，或会话中的专门命令 `/key`。除这两处之外，任何流程
都不问密钥、也不接收密钥。**

- 入口一（安装）：`setup.sh` 交互录入 → 写 `~/.claude-agent-env`（0600）；契约是
  「装的时候配好」。启动时仍缺密钥 → `configure_provider` 一行提示后 `die` 退出
  （无人值守场景不能弹提问）。
- 入口二（会话内）：`/key` 列出 7 家厂商的配置状态；`/key <厂商>` 隐藏输入 →
  写入同一文件（0600）→ 立即对当前会话生效。**GUI 不给这条路径**（首启页/设置里配）。
- **受限会话（`--no-config`）没有第二个入口**：远程/嵌入式进来的消息只能对话，
  `/model`、`/mode`、`/allow-write`、`/key` 与 `/claude` 这类厂商命令一律拒绝，
  回一句「本次会话不能修改配置……这些请在本机配置；对话本身照常可用」。
  理由有两条：① 远程的厂商/模型/模式本来就该在本机定好，会话中途被聊天端改掉会
  让本机行为莫名其妙地变；② 密钥绝不能经第三方聊天平台转一圈（那是明文过人家服务器）。
  实现上核心只多一个通用开关，`remote/gateway.pl` 起 agent 时带上它并记
  `session_start … no_config=1` 审计；`check-decoupling.py` 守着这条边界。
- 切换模型（`/model`、`/claude` `/deepseek`…）**与密钥完全解耦**：缺密钥时只打印
  「X 还没有配置密钥（KEY_ENV）。密钥用专门的命令配置：/key x」，并**停在原模型**。
- 密钥失效（HTTP 401/403 或各家等价的报文）：单独识别成「密钥被拒绝（HTTP 401）」，
  指出该检查哪个环境变量、要求退出会话后重配（会话内也可以用 `/key` 覆盖），
  不把原始 JSON 甩给用户。
- 对齐对象：Claude Code 的做法是「会话内 `/login` + `/model` 不碰认证 + 失效只提示
  `Please run /login`」。这三条同构，`/key` 就是 `/login` 的对位物。
- 理由：密钥输入夹在切换流程里，用户无法区分「我要换模型」和「我的 key 坏了」——
  实际发生过「回车取消 → 以为原来的 key 失效 → 重跑安装又因厂商被改而报
  Incorrect API key」的事故。判断与录入分离之后，会话里只剩「能用 / 不能用 + 去哪里修」。
- 卡口：`scripts/test-key-policy.py`（20 项，PTY 真喂输入 + 假端点造 200/401）。

| 变量 | 作用 |
|---|---|
| `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` | 密钥（代码里绝不含任何 key） |
| `CLAUDE_PROVIDER` | `anthropic` / `gemini` |
| `CLAUDE_MODELS_FILE` | 覆盖 `models.txt` 路径 |
| `CLAUDE_CURL` / `CLAUDE_CACERT` | 替换 curl / CA（Tier A） |
| `CLAUDE_OPENSSL` | 替换 openssl |
| `CLAUDE_NO_HISTORY` | `1` = 不保存历史（不问口令） |
| `CLAUDE_LANG` | `ja` / `en` 强制语言，否则自动检测 |
| `CLAUDE_GEMINI_THINKING` | `high` 加深 Gemini 思考 |
| `CLAUDE_MODE` | **计划中（§10）**：`default` / `accept-edits` / `bypass`；命令行 `--mode=` 等效 |
| `CLAUDE_SHELL_TIMEOUT` | **计划中（§10）**：`run_shell` 超时秒数，默认 120，`0` = 不限 |
| `CLAUDE_CONFIRM_TIMEOUT` | **计划中（§10）**：危险操作确认等待秒数，默认 60，超时即拒绝 |
| `CLAUDE_ALLOW_WRITE` | **计划中（§10）**：额外可写目录，冒号分隔，可多个 |

`models.txt` 格式：`<model_id>|<日本語>|<English>|<中文>|<provider>|<base_url>|[flags]`，一行一条。只有前两列必需，第 3 列起可省（老的三列表仍可直接用）。
CI 里有格式卡口，改格式必须同步改 CI。

---

## 9. 已知限制 / 技术债

1. **Tier A 完全未实现** —— 需要交叉编译 toolchain；维护者已决定暂不做（保留接口，不算待办）。
2. **CI 覆盖不到真实 API** —— 无密钥、要计费，只做语法/一致性/启动冒烟。
3. **GUI 无法在无显示器环境验证** —— 本仓的 Linux 开发机只能静态审代码。
4. **`Advisor.app` 打包只能在 macOS 上验证** —— py2app + Gatekeeper 流程跑不了。
5. **MD5 键派生偏弱** —— 受 High Sierra 的 LibreSSL 限制，短期无解。
6. **单文件 2172 行** —— 与"零依赖单文件"的约束绑死，拆分需谨慎（见 §1）。
7. **macOS 自带 bash 3.2 与 Linux 的 bash 5 行为不同** —— 两类都踩过真故障：
   `$var` 紧跟中文/全角字符时 3.2 把该字符的首字节算进变量名（名字凭空消失）；
   `case … in x) continue ;; esac` 在 3.2 上是语法错误（放进 pre-commit hook 等于 hook 从不执行）。
   写 shell 时变量一律 `${var}`、分支一律 `if/else`，卡口 `scripts/check-shell-var-glue.py`。
8. **`.app` 启动器的弹窗必须有超时** —— `osascript display dialog` 不带 `giving up after`
   会一直等人点击，在无人值守环境（CI / 远程登录）就是永久挂住；且文字提示要先写 stderr。

---

## 10. 交互模式（权限模式：default / accept-edits / bypass）

> **状态：已实现**（本节 v0.3，2026-10-27）· 确认记录见 §10.11 · **实现偏差见 §10.13**
> 测试：`scripts/test-modes.py`（60 项）+ `scripts/test-gui-modes.py`（14 项），均已进 CI。
> 维护者确认的三个关键取舍：三档都做 / 危险命令弹确认（不硬拒）/ 可写目录会话级多目录。

### 10.1 现状：确认是唯一的安全边界

代码事实（`agent/claude-agent.pl`）：

| 事实 | 位置 | 含义 |
|---|---|---|
| 四个工具：`read_file` / `write_file` / `list_dir` / `run_shell` | 2383–2420 | 无沙箱、无路径限制，能力就是进程自己的权限 |
| 只有 `write_file` 与 `run_shell` 会确认 | 2829 / 2846 | 读类（`read_file` / `list_dir`）从不确认 |
| `confirm()` 两条通道 | 2445 | GUI：发 `{t:'confirm'}` 等 `{t:'reply'}`；终端：y/n 循环，非 y/n 重问，空回车=取消 |
| `run_shell` 执行 `$command 2>&1` | 2849 | **无超时、无输出上限** |
| `--tools=<a,b>` 只能收窄 | 2425–2441 | 未知工具名直接 die；远程网关靠它只给 `read_file,list_dir` |
| 系统提示词告诉模型「会弹 y/n」 | 1379–1390 | 改模式必须同步改这段，否则模型反复说「我先问你」 |

结论：**当前每一次写文件、每一次 shell 执行都要人点一次**。做小改动可以，但连续多步任务
（建项目、跑测试、批量改文案）会变成几十次确认，实际体验是用户闭眼按 y ——
比自动执行更不安全。这是加模式的真实动机。

### 10.2 模式定义（三档）

| 模式 | 普通 `write_file` | 普通 `run_shell` | **危险命令** | 定位 |
|---|---|---|---|---|
| `default`（默认，现状） | 确认 | 确认 | 确认 | 全程可见 |
| `accept-edits` | **自动**（可写范围内）；范围外 → 确认 | 确认 | 确认 | 改文件不烦人，跑命令仍把关 |
| `bypass` | **自动**（可写范围内）；范围外 → 拒绝并提示如何加白名单 | **自动** | **确认** | 连续作业；只放宽「要不要问」，不新增能力 |

「危险命令」判定见 §10.3①。三档都**不提供**完全无约束的放行：

- 读类工具永不需要确认（现状不变）
- 危险命令在三档里都确认 —— 区别只在「普通操作要不要问」
- bypass 下危险命令的确认**同样生效**（这是 Q2 的结论：宁可多问一次，也不静默执行）

### 10.3 三条边界

**① 危险命令清单 → 一律弹确认（三档通用）**

命中清单时无论如何都要人确认一次，`bypass` 也不例外：

- 破坏性：递归删除根目录 / 家目录、文件系统格式化工具、直写块设备、重定向覆盖 `/dev/sd*`
- 系统控制：`shutdown`、`reboot`、`halt`、`systemsetup`、`csrutil`、`launchctl unload`
- 提权：`sudo`、`su`、`chown -R root`
- 下载即执行：远端脚本直接管道给 shell（`curl … | sh` 形态）
- 权限放开：递归 `chmod 777` 作用于根
- 自毁：fork bomb 形态
- 交互式（会永久阻塞）：`vi`/`vim`/`nano`/`less`/`more`/`top`/`man`（无 `-c` 或管道形态时）、
  交互式 `ssh` 登录、直接 `read`

> 具体正则写进代码，本节只定原则。清单**写死在代码里**，不做配置开关 ——
> 可配置的危险清单等于可以被关掉，与远程只读硬关同一风格。

**★ 无人可确认时 fail-closed（由 Q2 派生的硬约束）**

危险命令要确认，而 bypass 的典型场景是「人不在跟前」。所以：

- 确认等待 **60 秒**（`CLAUDE_CONFIRM_TIMEOUT`，仅作用于危险命令）
- **超时 = 拒绝**，并在结果里说明「危险操作需要确认，60 秒内无人应答，已拒绝」
- 非交互环境（`stdin` 不是 tty 且 GUI 未连接）**直接拒绝**，不进等待循环
- 判据：**绝不把「没人回答」当成「同意」**，也绝不因此把会话挂死

**② 写入范围：会话可指定多个白名单目录（Q3 结论）**

- 默认允许：**当前工作目录子树** + 临时目录
  （临时目录优先用 `$TMPDIR`，未设置时才用 `/tmp`；**不把两者都算作可写** ——
  同时算两个会让「范围外」的含义随环境变化，测试和用户都说不清）
- 会话内可追加**多个**目录：
  - 启动参数 `--allow-write=<dir>`（**可重复**，也接受逗号分隔）
  - 环境变量 `CLAUDE_ALLOW_WRITE=<dir>[:<dir>…]`
  - 会话内命令 `/allow-write <dir> [<dir>…]` 追加、`/allow-write` 查看、`/allow-write clear` 清空
- 生效范围：`write_file` 与命令里的写目标判定用的是**同一份列表**（单一来源，避免两处不一致）；
  命令侧的识别是保守的 best effort，详见 §10.13.1
- 永远拒绝（即使显式加入也拒绝）：`/etc`、`/usr`、`/bin`、`/sbin`、`/System`、`/Library`、
  `~/.ssh`、**`~/.claude-agent`（含密钥、历史、审计日志本身）**、`/dev/*`
- 目录校验：展开 `~`、解析符号链接（按真实路径判定）、不要求已存在但会在首次写入时报错
- 越界时：`bypass` 拒绝 + 提示「目标不在可写范围，用 `/allow-write <dir>` 加入」；
  `accept-edits` 弹确认（临时放行本次）；`default` 本来就确认

**③ 执行层面：超时与输出上限（bypass 的前置条件）**

现状 `run_shell` 既无超时也无输出上限，无人盯着时一条等输入或长跑的命令会挂死会话、
或把上下文刷爆。所有模式都补：

- 命令超时：默认 **120 秒**（`CLAUDE_SHELL_TIMEOUT` 可调，`0` = 不限，需显式设置）
- 输出上限：**64 KB**，超出截断并注明「输出已截断（原 1.2 MB）」

### 10.4 切换入口与可见性

| 入口 | 形态 | 说明 |
|---|---|---|
| 启动参数 | `--mode=default\|accept-edits\|bypass` | 也认 `CLAUDE_MODE`（环境变量优先于 conf） |
| 会话内 | `/mode` 查看 · `/mode <名字>` 切换 | **切入 bypass 需再输一次 `yes`**（一次性警告）；切到 accept-edits / default 不需 |
| 可写目录 | `--allow-write=` / `CLAUDE_ALLOW_WRITE` / `/allow-write` | 见 §10.3② |
| GUI | 设置菜单三选一 + 状态栏徽标 | `accept-edits` 显示蓝色 `✎ edits`，`bypass` 橙色 `⚠ bypass`；不显示等于偷偷改行为 |
| 持久化 | `~/.claude-agent-env`：`CLAUDE_MODE` / `CLAUDE_ALLOW_WRITE` | 下次沿用；启动横幅必须打印当前模式与可写目录 |

**可见性铁律**：bypass / accept-edits 下每次自动批准都在消息流插一行系统提示
（`已自动批准：write_file  /path/to/x.py`），否则用户会以为什么都没发生 ——
静默自动执行最容易引发「你是不是乱改我东西」这类质疑。

### 10.5 审计

- 自动批准与**危险操作确认结果**都追加到 **`~/.claude-agent/approvals.log`**（0600，只追加）
- 每行：`时间 · 模式 · 工具 · 目标（路径或命令）· 结果 · 退出码/字节数`
- `/approvals` 显示最近 10 条；启动处于非 `default` 模式时，横幅给出日志路径
- 与远程 `audit.log` 分两个文件：一个记「远程谁在问」，一个记「本地自动做了什么」

### 10.6 与远程接入的关系（硬关，不给开关）

- 远程网关 `remote/gateway.pl` 只给 `read_file,list_dir`，**永远没有写/执行能力**
- gateway / platform 启动时不接受也不转发 `--mode` 与 `--allow-write`：收到就忽略并审计 `mode_ignored`
- `scripts/check-decoupling.py` 增加断言：核心不得从 `remote/` 读取模式；
  `remote/` 下的启动参数里不得出现 `bypass` / `--allow-write`
- 理由：模式是「本地有人承担后果」的取舍；远程是「白名单里任何人拿手机发一句话」，
  风险量级差一个数量级，不共用同一套放宽策略

### 10.7 与其它提示的关系（模式不管它们）

以下照旧出现，不因模式放宽：保存 API key 的 `[y/N]`（300 行）、设置口令 / 恢复口令（430 / 505 行）、
历史口令解锁、切入 bypass 本身的那一次确认。

### 10.8 三语文案与卡口

- 新增 `%S` 条目约 14 条（三个模式名、切换警告、危险确认文案、超时拒绝、写越界提示、
  自动批准提示、截断提示、可写目录列表、`/allow-write` 帮助等），三种语言都要写；
  `scripts/check-i18n.py` 校验占位符一致性
- `--help` 三语版本（824 / 855 行附近）各加 `--mode=`、`--allow-write=` 两行
- 新增 `scripts/test-modes.py` 并进 CI，至少包含：
  - `default`：`write_file` / `run_shell` 必弹确认（回归）
  - `accept-edits`：范围内写入不确认、**范围外仍确认**、`run_shell` 仍确认
  - `bypass`：普通写/执行不确认，且消息里出现「已自动批准」
  - `bypass`：危险命令**仍然确认**；模拟无人应答 → 60 秒（测试里可把超时调到 1 秒）→ 拒绝
  - `bypass`：写范围外 → 拒绝；`/allow-write` 加入后 → 放行
  - 多目录白名单：允许两个目录同时生效，且「永远拒绝」的目录即使加入也不放行
  - 输出截断与命令超时各一条
- `check-decoupling.py` 加「远程不出现模式/白名单参数」断言

### 10.9 分阶段建议

| 阶段 | 内容 | 为什么这个顺序 |
|---|---|---|
| M0 | `run_shell` 超时 + 输出上限（三档都生效） | 前置条件；单独也值得做 |
| M1 | 模式骨架：三档枚举 + `--mode` / `CLAUDE_MODE` + 系统提示词随模式变化 | 先把「能选」做出来，行为默认仍是 `default` |
| M2 | 危险命令清单 + 确认 + **无人应答 fail-closed** | 安全核心，先于「放开普通操作」 |
| M3 | 可写范围（多目录 + 永远拒绝 + 校验）与 `/allow-write` | 写路径的第二道边界 |
| M4 | 自动批准开关（`accept-edits` / `bypass` 真正生效）+ `approvals.log` + 消息流提示 + `/approvals` | 到这一步才真正放宽，且有可见性与回溯 |
| M5 | `/mode` 会话内切换 + 持久化 + GUI 三档控件 + `test-modes.py` 进 CI | 收尾 |

### 10.10 验收清单

- [ ] `default` 下 `write_file` 与 `run_shell` 仍然每次都问（回归：不能顺手改掉）
- [ ] `accept-edits` 下写可写范围内文件不确认；写范围外**仍确认**；`run_shell` 仍每次确认
- [ ] `bypass` 下写范围内文件、跑普通命令都不确认，且消息流出现「已自动批准」一行
- [ ] **`bypass` 下危险命令仍然弹确认**；无人应答 60 秒后拒绝，会话不挂死
- [ ] 非交互环境（无 tty、无 GUI）下危险命令**直接拒绝**，不进等待
- [ ] `vi` 之类交互命令被危险清单拦下并确认/拒绝，不会永久阻塞
- [ ] `/allow-write /tmp/a /tmp/b` 后两个目录都能写；`/allow-write` 能看到当前列表
- [ ] 把 `~/.claude-agent` 或 `/etc` 加进白名单也**不生效**（永远拒绝）
- [ ] 一条长 `sleep` 命令在 120 秒后被终止，结果说明是超时
- [ ] 超大输出被截断到 64 KB 并注明原大小
- [ ] `approvals.log` 有对应记录（含危险确认结果），权限 0600，内容不含 key
- [ ] 远程网关收到 `--mode` / `--allow-write` 时忽略并审计 `mode_ignored`，能力仍只有两个只读工具
- [ ] 三语文案齐全，`check-i18n.py` 通过

### 10.11 需求确认表

| # | 问题 | 结论 | 落实方式 |
|---|---|---|---|
| Q1 | 两档还是三档 | **三档都做** | 枚举 `default` / `accept-edits` / `bypass`；§10.2 矩阵；GUI 三选一；`/mode` 三值；提示词三套措辞 |
| Q2 | 危险命令：硬拒还是弹确认 | **弹确认** | 危险清单命中后三档都走 `confirm()`；新增 `CLAUDE_CONFIRM_TIMEOUT`（默认 60s）与无人应答 fail-closed；非交互环境直接拒绝 |
| Q3 | 写入范围 | **会话可指定多个白名单目录** | `--allow-write` 可重复 + `CLAUDE_ALLOW_WRITE`（冒号分隔）+ `/allow-write` 增/查/清；`write_file` 与命令写目标共用同一份列表；「永远拒绝」目录不可被加入 |
| Q4 | 会话内切换 | **允许，切入 bypass 需输 `yes`** | `/mode <名字>` 命令；切入 bypass 弹一次性警告并要求输入 `yes`；切回不需 |
| Q5 | 持久化 | **持久化 + 启动横幅明示** | 写 `~/.claude-agent-env` 的 `CLAUDE_MODE` / `CLAUDE_ALLOW_WRITE`；启动横幅打印模式与可写目录 |
| Q6 | 审计 + 消息流提示 | **两个都做** | `approvals.log`（0600 追加）+ `/approvals`；每次自动批准与每次危险确认都写；消息流插系统提示行 |
| Q7 | 超时 / 输出上限 | **120s / 64KB** | `CLAUDE_SHELL_TIMEOUT` 默认 120（0=不限）；输出截断 64 KB 并在结果里注明原大小 |

### 10.12 由确认派生的补充设计

**A. `accept-edits` 的精确语义（Q1 派生的最大未知项）**

- 只放宽 `write_file`，`run_shell` 一行不放宽 —— 否则与 `bypass` 没有区别
- 范围内：自动批准 + 消息流提示；不写 `approvals.log`？**要写**（两种自动批准都记，否则无法审计）
- 范围外：**弹确认**（不是拒绝）—— 这个档位的定位是「介于两者之间」，拒绝会让人以为坏了
- 若用户选择 `accept-edits` 但一次 `run_shell` 都没用过，横幅提示「本模式不改变命令确认」

**B. 危险命令确认的交互细节（Q2 派生）**

| 场景 | 行为 |
|---|---|
| 终端有 tty | 复用现有 `confirm()` 的 y/n 循环，提示里标明「危险操作」 |
| GUI 已连接 | 复用 `{t:'confirm'}`，弹窗标题区分危险操作 |
| 无人应答 | 60 秒后拒绝，结果里写清原因（不重试、不降级为放行） |
| 无 tty 且无 GUI | 直接拒绝，不进等待循环 |
| 用户拒绝 | 结果回给模型「已拒绝」，模型按既有提示词重述方案而不是重试同一命令 |

**C. 多目录白名单的细则（Q3 派生）**

- 存储形态：内存里 `@WRITE_ROOTS`（已解析的真实路径，去重后保序）；持久化为
  `CLAUDE_ALLOW_WRITE=<dir1>:<dir2>`（冒号分隔，路径内含冒号属极端情况，文档注明不支持）
- 判定函数单一入口 `write_allowed($path)`：`default` 不看它（照旧确认），另外两档读它
- 命令里的写目标判定：只做**明显形态**的识别（重定向 `>`/`>>`、`tee`、`cp/mv/rm` 的目标参数），
  不做 shell 语法完整解析 —— 文档写明这是**尽力而为**，真正兜底仍是危险清单与确认。
  **已实现，见 §10.13.1**
- 每次 `/allow-write` 变更都写一条 `approvals.log`（谁在什么时候扩大了可写范围，必须留痕）

**D. 系统提示词的三档差异（Q1 派生）**

| 模式 | 提示词增量 |
|---|---|
| `default` | 现状不变（写明会弹 y/n） |
| `accept-edits` | 「写文件通常已获批准；执行命令仍会询问」 |
| `bypass` | 「写文件与执行命令通常已获批准；危险操作与可写范围外仍会被拦或询问」+ 要求模型**事先用一两句话说明要做什么** |

**E. 与 `--tools=` 的关系**

`--tools` 是能力收窄、模式是确认策略，两者正交：`--tools=read_file` + `--mode=bypass`
等于「只能用只读工具，且都不问」。远程网关就是靠这两者组合保证「只读且无交互」。

**F. 失败与回退**

- 任一新增判定（清单匹配、路径解析、确认超时）出错时，**一律按保守方向处理**：确认、不清单、
  不放行；禁止「解析失败就当安全」
- 模式值非法（`--mode=xxx`）→ 报错退出，不回落成默认（静默回落会让用户以为在用 bypass）

---

### 10.13 实现记录与偏差（交付时如实登记）

**落地顺序**：M0 → M5 一次做完（未分批发布；版本号由维护者定）。

| 阶段 | 实际交付 |
|---|---|
| M0 | `run_shell` 改为 fork + 独立进程组 + 输出落文件：超时 120s（`CLAUDE_SHELL_TIMEOUT`，0=不限），打断走 TERM → 0.5s → KILL **整组**（`npm` 的孙进程也停）；输出上限 64 KB，超出注明原大小；输出按 UTF-8 解码并替换非法字节（原来是裸字节，可能把 API 请求搞坏） |
| M1 | `--mode=` / `CLAUDE_MODE`；**非法值 exit 2**（不静默回落）；系统提示词按模式三套；启动横幅打印模式与可写目录 |
| M2 | 危险命令 15 条形态规则 + 交互式命令首 token 判定（按 `\|` `;` `&&` 分段，`cat x \| less` 也拦）；三档都确认；GUI/终端确认 60s 超时（`CLAUDE_CONFIRM_TIMEOUT`）→ 拒绝；无 tty 且无 GUI → 直接拒绝；`echo sudo` 这类无害形态也拦（宁可多问一次） |
| M3 | 可写范围：`--allow-write`（可重复，也认 `--allow-write x`）/ `CLAUDE_ALLOW_WRITE`（冒号分隔）/ `/allow-write` 增·查·清；路径展开 `~` 后按真实路径判定；永久禁止目录优先于范围判定；每次扩范围写审计 |
| M4 | `~/.claude-agent/approvals.log`（0600 只追加）+ `/approvals` 取最近 10 条；每次自动批准在消息流插一行 |
| M5 | `/mode` 查改 + **切 bypass 需再输一次 `yes`**；持久化到 `~/.claude-agent-env`；GUI 页眉「模式 ▾」菜单 + 常驻徽标（bypass 用主题危险色），GUI 切 bypass 也先确认一次 |

**偏差 1（已按 (b) 修复，见 §10.13.1）**

设计 §10.12 C 写了「命令里的写目标也做明显形态识别」，首次交付时**没有实现**
（当时只有 `write_file` 受可写范围约束）。已按维护者「按推荐继续」补上，
具体见下面的 §10.13.1。

**偏差 2**：`--help` 实际只有日/中两套（英文走日文回退，这是上游原有行为），
设计里写的「三语各加两行」按两套落地。

**偏差 3（安全相关的补强）**：拒绝原因除了回给模型，**同时打进消息流**。
只回给模型时，模型完全可能不转述 —— 那用户看到的就是「什么都没发生」。

**偏差 4**：`/allow-write` 的持久化用单引号包住冒号列表（`persist_env` 不转义）。
路径里带空格或冒号仍然不支持，已在提示里回避（不做特殊处理）。

**新增的卡口与测试**

- `scripts/test-modes.py`（60 项）：假 OpenAI 端点喂 `tool_call`，走 `--rpc` 断言
  「问没问 / 批没批 / 拒得对不对」。用 rpc 而不是真终端的理由：fail-closed 只在
  无人应答时出现，终端里造不出来。
- `scripts/test-gui-modes.py`（14 项）：Xvfb 里建窗口，用 Tk API 内省徽标文字与
  颜色、菜单三项、换主题后是否仍跟随；没有 `DISPLAY` 自动跳过（不让 macOS 假红）。
- `check-decoupling.py` 新增断言：`remote/` 三个脚本里不得出现
  `--mode` / `--allow-write` / `CLAUDE_MODE` / `CLAUDE_ALLOW_WRITE`。
  **已做反向探针**：往 `gateway.pl` 里插一行 `--mode=bypass`，检查变红；删掉后变绿。

**数字变化**：Perl `%S` 102 → **135**（模型菜单标注 +2）；GUI `_S` 57 → **64**；CI 25 → **27 步 × 2 平台**；
测试 199 → **273 项**。

**仍未验（只能真机或下一轮）**

- macOS 真机上徽标在暗色主题 / Retina 下的可读性；
- GUI 切 bypass 那个确认框的措辞是否够清楚（现在是复用 `confirm` 弹窗，正文是一长段警告）；
- `sleep`/长命令超时在真机上打断子进程树的实际效果（Linux 已验，macOS 的
  `setpgrp` 语义需实机确认）。

---

#### 10.13.1 命令写入目标纳入可写范围（补偏差 1）

**做了什么**：`run_shell` 执行前先扫一遍命令文本，把「写到哪里」保守地捡出来，
再按与 `write_file` **同一套**判定处理（`shell_scope_violation()`）：

| 形态 | 捡什么 |
|---|---|
| 重定向 | `>` `>>` `2>` `&>` 后面的目标（去掉引号） |
| `tee` | 所有非选项参数（含 `-a`） |
| `cp` / `mv` / `ln` / `install` | **最后一个**非选项参数（目的地） |
| `rm` / `touch` / `mkdir` | 所有非选项参数 |

判定结果分三种：

| 情形 | bypass 下 | accept-edits / default 下 |
|---|---|---|
| 命中**永久禁止**目录（`/etc`、`~/.claude-agent` 等） | **直接拒绝**（不问，因为问了也不允许） | 照旧确认（不额外拦） |
| 在**可写范围外**、非永久禁止 | **升级为确认**（带 `strict`：60 秒无人应答即拒绝） | 本来就要确认 |
| 在可写范围内 / 识别不到 | 照常自动执行 | 照常确认 |

**为什么是「升级为确认」而不是直接拒**：识别是 best effort，直接拒会误伤
（比如把 `>` 看成写入、实际是 `2>&1` 之类）。误报的代价只是多问一次，
而且 `strict` 保证无人值守时它不会把会话挂住。

**顺带修掉的判定环境依赖**：原来可写根同时包含 `$TMPDIR` 与 `/tmp`，导致
「范围外」在 macOS（`TMPDIR` 是 `/var/folders/.../T`）和 Linux（`/tmp`）上含义不同，
CI 上就出现过同一用例本机绿、CI 红。现在临时目录只取一个根（`$TMPDIR` 优先），
测试也自己指定 `TMPDIR`，判定不再依赖宿主环境。

**已知不完整**：不做 shell 语法完整解析。会被漏掉的例子：`cat x | sudo tee /etc/y`
（`sudo` 已经在危险清单里，仍会确认）、变量拼出来的路径（`$DEST/x`）、
`find -exec`、`xargs`、脚本/管道里再套一层。文档层面明确写：**兜底是危险清单 + 确认**，
可写范围负责挡住「能看出来」的那部分。

**测试**（`scripts/test-modes.py` 新增 `case_cmd_write_scope`，10 项）：

- 重定向到范围外 → 弹确认；按 n 不写；按 y 写成功
- `cp` 到范围外 → 弹确认
- `/allow-write` 加进去之后 → 不再问
- 写 `/etc/...` → **不弹确认，直接拒绝**，且文件真的没出现
- 不带写目标的命令 → 照旧不问、真的执行了（防误伤回归）


## 11. 改动规则

- 提交信息格式：`TYPE(scope) 中文描述`，例如 `FIX(gui) 修正流式输出重复追加`、
  `FEAT(agent) 增加 xxx 工具`。TYPE 用 `FEAT` / `FIX` / `DOCS` / `STYLE` /
  `CHORE` / `CI` / `UI`。
- 改 `agent/claude-agent.pl` 前必须确认：**没引入 CPAN 依赖**、**没用到 perl 5.8.6
  之后的语法**、`perl -c` 通过。
- 改 GUI↔后端协议时，同步更新本文 §3 的两张表。
- 改 shell 脚本（`setup.sh` / `scripts/*.sh` / hooks）后跑 `python3 scripts/check-shell-var-glue.py`：
  macOS 的 bash 3.2 有两类只在它上面出现的坑（见 §9.7）。
- 新增任何脚本都要同时加进 `ci.yml`，否则它只是"本地手工跑过一次"。
- 动确认/权限相关代码（`confirm()`、`run_tool`、`--tools`、`--mode`）前先读 §10：
  读类工具从不确认、写/执行默认确认、bypass 只放宽「要不要问」而不新增能力，
  硬拒绝清单写死在代码里、不做配置开关。
- 任何降低确认门槛的改动，必须同时补一条**反向断言**（例如「bypass 下危险命令仍会弹确认」
  「可写范围外写入仍被拒」），没有反向断言的安全改动一律视为未完成。
- 模式的三个判定（危险清单 / 可写范围 / 确认超时）出错时必须按**保守方向**处理：
  确认、不放行；禁止「解析失败就当安全」，也禁止把模式值非法静默回落成 `default`。
- 版本号 / tag 由维护者决定，不自动打。
- 发布说明写进 `docs/releases/<tag>.md`。
