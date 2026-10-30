# Advisor 用户手册

Advisor 是一个跑在自己电脑上的 AI 助手：终端里能用，图形界面也能用；
手机上通过企业微信 / 飞书把活派给它，结果再发回手机。

全部在本机运行 —— 不需要服务器、不需要公网域名、不需要注册任何云资源。
只有两类外部凭据：**模型厂商的 API 密钥**，以及（用远程接入时的）**企微/飞书机器人凭据**。

---

## 目录

1. [安装](#1-安装)
2. [首次配置：模型与密钥](#2-首次配置模型与密钥)
3. [终端里使用](#3-终端里使用)
4. [图形界面使用](#4-图形界面使用)
5. [交互模式与可写目录](#5-交互模式与可写目录)
6. [长期记忆与技能](#6-长期记忆与技能)
7. [远程接入：手机派活](#7-远程接入手机派活)
8. [配置与数据放在哪](#8-配置与数据放在哪)
9. [出问题怎么查](#9-出问题怎么查)
10. [安全与隐私](#10-安全与隐私)
11. [命令行速查](#11-命令行速查)

---

## 1. 安装

**要求**：macOS 10.13（High Sierra）或更新 + 系统自带的 `perl` 与 `python3`。
打独立 App 包才需要 Xcode Command Line Tools，日常使用不需要。

```bash
git clone <仓库地址> advisor && cd advisor
bash setup.sh
```

安装向导会做四件事：

1. 检查本机 perl 能不能编译程序（编译不过就停下，不写任何配置）
2. 问你要用哪家模型（7 家可选），输入该家的 API 密钥
3. 把配置写进 `~/.claude-agent-env`（权限 0600）
4. 实测一次 API 连通性，并生成 `~/Applications/Advisor.app`（双击可用）

装完后终端里 `advisor` 就是命令，`~/Applications/Advisor.app` 双击就是图形界面。

> 之后想换厂商/换密钥：终端里 `/key <厂商>`，或在图形界面里用「登记 API 密钥」。
> 密钥只存本机，只有这两个入口，**不会**在对话中问你密钥。

---

## 2. 首次配置：模型与密钥

支持的厂商（`models.txt` 里列了各自的可用模型）：

| 厂商 | 说明 |
|---|---|
| Gemini | Google |
| Anthropic | Claude 系列 |
| OpenAI | GPT 系列 |
| DeepSeek | 便宜、中文好 |
| 通义千问 | 阿里云 |
| Kimi | 月之暗面 |
| GLM | 智谱 |

- 没配密钥时进不了会话，程序会直接告诉你「请设置 <厂商> 的密钥」
- `/key`（不带参数）→ 列出 7 家，标「已配置 / 未配置」
- `/model` → 先选厂商（7 项），再选该厂商的模型；换厂商不要求重填密钥

---

## 3. 终端里使用

```bash
advisor                       # 用上次的厂商/模型
advisor -m deepseek-chat      # 指定模型起一轮
advisor --list-models         # 列出全部模型（12 条）
advisor --version
```

会话里的常用命令：

| 命令 | 作用 |
|---|---|
| `/model` | 换厂商 / 换模型（两级选择） |
| `/key <厂商>` | 配置或更换某家的密钥（隐藏输入） |
| `/mode` | 查看/切换交互模式（见第 5 节） |
| `/allow-write` | 查看或增删可写目录 |
| `/memory` | 查看长期记忆（见第 6 节）；`/remember <事实>` 记一条 |
| `/skills` | 列出本机技能（见第 6 节） |
| `/name <名字>` | 给这场对话起名；以后 `--continue 名字` 就能接着它 |
| `/history` | 列出已保存的对话（带名字、时间、首句） |
| `/search <词>` | 在已保存的对话里全文搜索，结果显示在对话里 |
| `/help` | 中文帮助 |

这三条（`/name` `/history` `/search`）在**手机远程会话里不允许**，和 `/mode` `/key` 同一条规矩：
手机上不能改本机的东西。远程的「自动接上一场」不受影响。

**历史与会话**（**默认明文保存，不问口令**）：

```bash
advisor --list-history          # 列出历史会话（明文/加密的都列，带名字）
advisor --resume                # 从列表里挑一场继续
advisor --continue              # 直接接着最近一场（等价 -c）
advisor --continue 名字         # 接着叫这个名字的那场
advisor --name 名字             # 给这场起个名字，以后好接
advisor --search 关键词         # 在历史里全文搜索（明文直读；加密的就先给口令）
advisor --encrypt-history       # 改成口令加密保存（也可 CLAUDE_ENCRYPT_HISTORY=1）
advisor --change-passphrase     # 改口令（只在加密历史下有意义）
advisor --set-recovery          # 设置/修改恢复用的密保（同上）
advisor --no-history            # 本次不保存（等价 CLAUDE_NO_HISTORY=1）
```

- **默认是明文**：`~/.claude-agent/history/<时间戳>.json`，文件权限 `0600`、目录 `0700`。
  启动不问口令，也不会因为忘记口令而丢掉历史。
- **想要加密**就用 `--encrypt-history` 启动：走口令流程，存成 `*.json.enc`，
  口令丢了里面的历史打不开（程序不会假装能恢复）。
- **不会悄悄切换**：目录里已经有 `key.enc`（也就是说你以前设过口令）时，即使不加参数
  也还是走口令流程 —— 程序不会把加密历史变成明文。
- 两种格式可以混在：切到加密之后，只有新会话是加密的，旧的明文会话照样能列出和续聊。
- **接续的三种方式**：`--resume`（列出来挑一场）、`--continue`（不问，直接接最近一场）、
  `--continue 名字`（按名字接，适合「项目甲/项目乙」分开聊）。
- **找回旧内容**：`--search 关键词` 会把命中的会话和前后片段列出来。加密历史里搜不到时，
  先按 `--encrypt-history` 启动一次（输入口令），再搜。
- 明文意味着：**同一台 Mac 上的其他用户账号、iCloud/备份、送修**都可能看到这些文件。
  在意的话就用 `--encrypt-history`，或者用完 `--no-history`。

---

## 4. 图形界面使用

- 双击 `~/Applications/Advisor.app`，或 `python3 gui/advisor_gui.py`
- 首次打开让你选厂商 + 粘密钥，校验通过即进主界面
- 顶部标签显示当前「厂商 / 模型」，菜单栏「切换」里按厂商分组选模型
- 工具 → **登记 API 密钥**：换密钥
- 工具 → **远程接入…**：配置企微长连接、权限档位、可写目录，并能启动/停止远程服务
- **会话**菜单（不用手敲参数）：
  - **接着上次的对话**：自动接着最近一场（等价 `--continue`）
  - **接着指定的对话…**：输入名字，接那一场
  - **列出现有对话**：等价 `/history`
  - **给本会话起名…**：等价 `/name 名字`
  - **搜索历史…**：等价 `/search 词`
  - 注意：「接着…」是**重新启动后端**（会话在启动时决定），所以上面已经显示的内容不会被重放，
    只有模型记得的内容接上了；原来的对话已经存盘，不会丢。
- 输入框在启动后、每轮回复后都会自动获得焦点，打开就能打字

如果双击打不开，先看第 8 节的「双击 Advisor.app 没反应」。

---

## 5. 交互模式与可写目录

Advisor 可以读写文件、执行命令，**默认每一类操作都会先问你**。三种模式：

| 模式 | 读文件 | 写文件 | 执行命令 |
|---|---|---|---|
| `default`（默认） | 直接做 | 每次确认 | 每次确认 |
| `accept-edits` | 直接做 | 可写目录内直接做，范围外确认 | 每次确认 |
| `bypass` | 直接做 | 直接做（**不受可写范围限制**） | 直接做，**危险命令和文件/目录操作仍确认** |

- 切换：会话内 `/mode`，或启动时 `--mode=accept-edits`
- **可写范围（白名单）只服务于 `accept-edits`**：`--allow-write=<目录>`（可多次），
  会话内 `/allow-write <目录>`、`/allow-write clear`。`bypass` 下这个名单**不参与判定**
  —— 想写哪里就写哪里。
- `bypass` 里仍然要确认的两类：
  - **危险命令**：递归删除、`sudo`、改权限、关机/重启、下载后执行、交互式程序等
  - **文件/目录操作**：`rm`、`rmdir`、`mv`、`cp`、`ln`、`mkdir`、`chmod`、`chown`、`dd`、
    `truncate`、`rsync`、`tar`、`zip`/`unzip`、`gzip`、`install`、`find -delete`、`git clean`
- **永久禁止的位置**（`/etc`、`/usr`、`~/.ssh`、`~/.claude-agent` 等）在任何模式下都直接拒绝，
  连确认都不给
- 没人回答确认（比如远程会话手机没回）→ 超时按**拒绝**处理，不会放行

`accept-edits` / `bypass` 请只在你信任的项目目录里用。

---

## 6. 长期记忆与技能

两件都是**纯本地文本文件**，不需要联网、不需要额外安装。

### 6.1 长期记忆（它记得住你）

默认文件：`~/.claude-agent/memory.md`（明文，0600）。每次对话开始时，内容会被放进系统提示词，
所以「你是谁、你不喜欢什么、你的机器是什么型号」这类事不用每次重说。

```
/remember 我用中文，回答请简短     记下一条（你自己打，不用确认）
/memory                          看现在记了什么（带行号、路径、字符数）
/memory rm 3                     删掉第 3 行
/memory clear                    全部清空（会问一次）
```

模型自己也可以记（工具名 `remember`），但它**每次都会先问你**、你回 `y` 才写，任何模式都不例外。

规则与上限：

- **一个文件最多 2000 字符**。超过就只把前面一段放进提示词，并且会告诉模型「被截断了」；
  再想写新的一条会被拒绝，提示你去编辑文件删掉一些。
- 记忆是**明文**的（对话历史默认也是明文；两者想加密都各自有开关）。理由：每次启动都要
  输口令才能加载记忆，不值当。
  它放在 `~/.claude-agent/` 下（不进 git），权限 0600。
- 记忆里的话**不是命令**。当它与本次对话的要求冲突时，以本次对话为准。
- 想彻底关掉：删掉这个文件即可；想换位置：设置环境变量 `CLAUDE_MEMORY_FILE`。

### 6.2 技能（它学得会套路）

技能就是一个 Markdown 文件，写「遇到这类任务，第一步做什么、第二步做什么」。
**只有名字和一行描述会进提示词**，正文等内容真的用上时模型才自己 `read_file` 去读 ——
所以放二三十个技能也不会把提示词撑爆。

放法二选一（目录：`~/.claude-agent/skills/`）：

```
~/.claude-agent/skills/备份笔记本/SKILL.md      ← 目录式
~/.claude-agent/skills/备份笔记本.md            ← 单文件式
```

描述从哪里取（按顺序）：frontmatter 里的 `description` → 第一个 `#` 标题 → 第一行非空文本。
最长显示 80 字符。

```markdown
---
description: 把工作目录打包备份到外接盘
---

# 备份

1. 先 `ls` 看目录内容
2. 确认外接盘挂载点
3. 用 `tar -czf` 打包，文件名带日期
```

```
/skills        列出本机技能（名字 / 描述 / 文件路径）
```

- 想看模型到底拿到了什么：`/skills` 里列的就是它看到的（名字 + 描述 + 路径）。
- 想换目录：设置 `CLAUDE_SKILLS_DIR`。
- **远程（手机）会话里不能查看/修改记忆与技能**（`/memory` `/remember` `/skills` 会被拒），
  但注入照常生效 —— 也就是说手机上派活时，它仍然记得你、仍然会用你写的技能。

---

## 7. 远程接入：手机派活

三种方式，按推荐排序：

| 方式 | 需要什么 | 适合 |
|---|---|---|
| **企业微信智能机器人（长连接）** | BotID + Secret | 家里普通宽带，**不需要公网**（推荐） |
| 企业微信/飞书自建应用（HTTP 回调） | 公网 HTTPS 地址 + 应用凭据 | 有公网域名或内网穿透 |
| 出站通知（只发不收） | 群机器人 webhook | 长任务跑完提醒你 |

### 7.1 企业微信长连接（推荐）

**准备**：企业微信 → 工作台 → 智能机器人 → 创建机器人 → **API 模式 → 使用长连接**，
记下 `BotID` 和 `Secret`（Secret 只显示一次）。

**配置**（两种入口，二选一）：

- 图形界面：工具 → 远程接入… → 填 BotID / Secret（掩码）→ 保存
- 终端：`perl remote/wecom-ws.pl --init`

先验证凭据：`perl remote/wecom-ws.pl --check`（20 秒内给结论）。

**白名单**：哪些人能指挥这台电脑。写到 `~/.claude-agent/remote.conf`：

```
ALLOW = 你的企微UserID
```

不在白名单的人发消息，**不回复任何内容**（连「无权限」都不回，避免暴露机器人存在），
只在审计日志里记一行。

**启动**：

```bash
# 只读（默认，最安全）
perl remote/wecom-ws.pl --serve

# 允许改文件：可写目录内自动写，跑命令仍要确认
perl remote/wecom-ws.pl --serve --mode=accept-edits --allow-write=~/proj
```

图形界面里也能一键启动/停止（工具 → 远程接入… → 启动服务），起的是同一个服务。

**权限在启动时定死**：起来之后手机上改不了（`/mode`、`/allow-write`、`/key` 一律被拒）。
要换档位就停掉，用新参数重启。

**手机上确认**：需要确认的操作会发到手机：

```
⚠ 危险操作，需要你在手机上确认：删除 ~/proj/tmp.log ？
回复 y 允许 / n 拒绝（不回则超时按拒绝处理）
```

回 `y` 放行、回 `n` 拒绝、不回 120 秒后按拒绝（`--confirm-wait=秒` 可调）。

**只能跑一个**：重复启动会被立刻拒绝（退出码 3），并告诉你已有实例的 pid 与档位 ——
两个实例会把同一条消息处理两遍。状态文件：`~/.claude-agent/wecom-ws.pid`
（含 pid / 档位 / 可写目录 / 启动时间，**不含密钥**）。

**保活**（参数与官方 SDK 默认一致）：每 **30 秒**发 `{"cmd":"ping"}`；**连续 2 次**没回执就判连接已死、
强制断开重连；退避 1→2→4→8→16→30 秒（上限 30 秒），**连通过一次就从头算**；断网恢复后自动连回。
凭据错（订阅被拒）连续 **5 次**后停下不再重试。

**同一个机器人只能有一处在连**：如果这个机器人在别处（另一台机器、企微客户端）连上了，
服务端会通知本连接「被新连接取代」，本服务收到后**主动退出（退出码 4）且不反复重连** ——
否则两边会互相抢线。要换回来就把那边关掉，再重新启动本服务。

**退出**：Ctrl-C、`kill <pid>`、或图形界面的「停止服务」→ 写审计 `ws_stop`、清理 pid 文件。

**开机自启**（可选）：`~/Library/LaunchAgents/cc.advisor.wecomws.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>cc.advisor.wecomws</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/perl</string>
    <string>~/advisor/remote/wecom-ws.pl</string>
    <string>--serve</string>
    <string>--mode=accept-edits</string>
    <string>--allow-write=~/proj</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>~/.claude-agent/wecom-ws.log</string>
  <key>StandardErrorPath</key><string>~/.claude-agent/wecom-ws.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/cc.advisor.wecomws.plist     # 装上并启动
launchctl unload ~/Library/LaunchAgents/cc.advisor.wecomws.plist   # 停掉并取消
```

（plist 里不能写 `~`，实际使用时换成你自己的绝对路径。）

### 7.2 自建应用（HTTP 回调）

需要公网可达的 `https://` 地址（域名、或内网穿透都行）。

```bash
perl remote/platform.pl --init     # 录入 CorpID / AgentId / Secret / Token / EncodingAESKey
perl remote/platform.pl --check    # 显示：配置齐全：platform=wecom port=8099
perl remote/platform.pl --serve    # 监听 127.0.0.1:8099（默认只听本机，这是故意的）
```

企微后台「应用 → 接收消息 → API 接收」填 URL / Token / EncodingAESKey，保存应当通过。
飞书同理，`--init` 时选飞书，事件订阅地址填 `/feishu`，白名单填 `open_id`（`ou_` 开头）。

### 7.3 出站通知（只发不收）

适合「长任务跑完了提醒我」：

```
# ~/.claude-agent/remote.conf
WECOM_WEBHOOK = https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
```

```bash
perl remote/notify.pl --test              # 发一条连通性测试
echo "构建完成" | perl remote/notify.pl -  # 发任意文本
```

---

## 8. 配置与数据放在哪

| 路径 | 内容 | 权限 |
|---|---|---|
| `~/.claude-agent-env` | 厂商、模型、API 密钥 | 0600 |
| `~/.claude-agent/history/*.json` | 对话历史（**明文**，默认） | 0600（目录 0700） |
| `~/.claude-agent/history/*.json.enc` | 对话历史（`--encrypt-history` 的加密形式） | 0600 |
| `~/.claude-agent/remote.conf` | 白名单 `ALLOW`、通知 webhook、远程历史口令 | 0600 |
| `~/.claude-agent/platform.conf` | 企微/飞书回调凭据 | 0600 |
| `~/.claude-agent/wecom-ws.conf` | 企微长连接 BotID / Secret / 档位 / 可写目录 | 0600 |
| `~/.claude-agent/wecom-ws.pid` | 远程服务状态（pid / 档位 / 启动时间） | 0600 |
| `~/.claude-agent/memory.md` | 长期记忆（**明文**，见 §6.1） | 0600 |
| `~/.claude-agent/skills/` | 技能目录（每个技能一个 `SKILL.md` 或一个 `.md`） | — |
| `~/.claude-agent/audit.log` | 远程会话审计（只追加） | 0600 |
| `~/.claude-agent/wecom-ws.log` | 远程服务运行日志 | 0600 |
| `~/Applications/Advisor.app` | 双击入口（安装时生成） | — |

图形界面与命令行写的**是同一份文件** —— 在一边改，另一边立刻生效；重启程序会读回，不用重填。

---

## 9. 出问题怎么查

### 8.1 常见症状

| 现象 | 多半是 | 怎么办 |
|---|---|---|
| 启动就提示要密钥 | `~/.claude-agent-env` 里缺 `CLAUDE_PROVIDER`，或 key 变量名为空 | 重新 `bash setup.sh` 或 `/key <厂商>` |
| 提示「密钥被拒绝（HTTP 401）」 | key 无效 / 过期 | 换 key |
| 提示 403 | 这家厂商在你的地区不提供服务 | 换厂商 |
| 提示 000 / 超时 | 网络不通（需要能访问该厂商接口） | 换网络或代理 |
| 双击 App 没反应 | macOS 对未签名 App 的限制 | 右键 → 打开；或在终端里 `python3 gui/advisor_gui.py` 看报错 |
| 手机上发消息没反应 | 远程服务没跑 / 发送者不在白名单 | 看 `wecom-ws.pid` 与 `audit.log` |

### 8.2 远程排错

| 现象 | 看哪里 | 常见原因 |
|---|---|---|
| 远程服务启动即退出码 3 | 提示里给了 pid | 已经有一个在跑，先 `kill` 旧的 |
| 退出码 4 | 「同一机器人已在别处建立了新连接」 | 另一台机器/客户端正连着，关掉那边再启动 |
| 退出码 5 | 「TLS 证书校验失败」或「找不到可用的根证书包」 | 见 8.3 |
| 手机发消息没反应 | 审计里有 `ws_inbound` 但没有 `ws_sent` | 白名单没放行：把 `from=` 的 id 写进 `remote.conf` 的 `ALLOW` |
| 审计里 `ws_send_err … errcode=40008` | 「invalid message type」 | 已修；若复现说明回复体不是 stream，报给我 |
| 审计里连 `ws_inbound` 都没有 | 消息没推到服务端 | 群里要 `@机器人`；确认机器人开的是「API 模式 / 长连接接收」 |
| 手机发中文，AI 说「你的消息像是乱码」 | 中文被双重编码（历史缺陷，已修） | 更新到最新版即可；若仍复现，把审计里那条 `ws_inbound` 的 `len=` 发我 |
| 配置自检说「存在但当前用户读不到」 | `~/.claude-agent-env` 属主是 root（以前用 `sudo` 写过/配过） | `sudo chown $(whoami) ~/.claude-agent-env && chmod 600 ~/.claude-agent-env`；同目录也一起 `ls -l` 看一眼 |
| 报「请设置 ANTHROPIC_API_KEY」但你配的是国产模型 | `~/.claude-agent-env` 里 `CLAUDE_PROVIDER` 缺失或**值为空**，agent 回退到 Anthropic | 写成 `export CLAUDE_PROVIDER=deepseek`（可选：anthropic/dashscope/deepseek/gemini/moonshot/openai/zhipu）。启动时现在会打「配置自检」直接点名 |
| 审计里 `session_not_ready` | 本机的 AI 会话没起来（密钥失效 / 模型名不对 / 配置没写好） | 看同一行后面的 `err=`，它带着子进程的原话；手机那边现在也会收到一句话而不是干等 |
| `--check` 报 `errcode` | 提示原文 | BotID / Secret 不对，或机器人没开「使用长连接」 |
| 手机发了没反应、日志无 `ws_inbound` | `audit.log` | 服务没跑 / 白名单没写对 |
| 有 `ws_inbound` 但没有 `gateway_done` | `audit.log` | 本机模型不通（先在终端跑一次 `advisor`） |
| 一直「正在处理」 | `audit.log` 的 `turn_timeout` | 模型太慢或网络断了 |
| 让它写文件没写 | `audit.log` 的 `confirm_refused` | 档位是只读（要 `--mode=accept-edits`） |
| 回调模式：后台保存 URL 失败 | `audit.log` 的 `wecom_verify_fail` / `wecom_receiveid_fail` | Token 或 EncodingAESKey 不一致 |
| 回调模式：有 `gateway_done` 但手机没收到 | `wecom_send_fail` / `feishu_send_fail` | 没开发送权限，或 ID 不是 UserID / open_id |

### 8.3 证书校验失败怎么办

连企业微信长连接走的是 `wss://`，必须能校验服务端证书。如果本机没有根证书包，
程序**不会**降级成「不校验」—— 那等于把密钥交给可能的中间人。它会直接停下并告诉你原因：

```
TLS 证书校验失败：verify error:num=20:unable to get local issuer certificate（证书包：…）
找不到可用的根证书包。任选一种办法：
  1) macOS：重新执行一次本命令（会自动从钥匙串导出到 ~/.claude-agent/ca-bundle.pem）
  2) 指定已装好的证书包：export SSL_CERT_FILE=/etc/ssl/cert.pem
  3) Homebrew：brew install ca-certificates
```

自己核对用的命令（不会打印任何密钥）：

```bash
openssl s_client -connect openws.work.weixin.qq.com:443 -servername openws.work.weixin.qq.com   -CAfile ~/.claude-agent/ca-bundle.pem </dev/null 2>&1 | grep -E 'Verify return code|verify error'
```

看到 `Verify return code: 0 (ok)` 就没问题。这条**只在启动时判一次**，失败即退出（退出码 5），
不会每 30 秒重试 —— 证书问题重试一万次也不会变好。

### 8.4 自查命令

```bash
advisor --version                        # 版本
perl remote/wecom-ws.pl --check          # 长连接凭据
tail -30 ~/.claude-agent/audit.log       # 远程审计
tail -20 ~/.claude-agent/wecom-ws.log    # 远程服务日志
grep -o '^export [A-Za-z0-9_]*' ~/.claude-agent-env   # 只看变量名，不打印密钥值
```

---

## 10. 安全与隐私

- **密钥只存本机**：`~/.claude-agent-env`（0600）；不进日志、不进命令行参数、不进对话
- **不进 Git**：仓库里没有你的密钥、路径、账号
- **远程白名单**：只有 `ALLOW` 里的人能指挥；其他人发消息**零回复**，只记审计
- **远程权限自己定**：默认只读；放开要显式在启动时指定；手机上改不了
- **确认不会被绕过**：危险操作在任何模式都要人确认，没人确认就按拒绝处理
- **审计只追加**：`audit.log`（0600）记录谁在什么时候让这台机器做了什么
- **历史存储**：默认明文（`0600`，目录 `0700`），启动不问口令；要防同机他人/备份带走，
  用 `--encrypt-history` 上口令（口令丢了就打不开，程序不假装能恢复）

---

## 11. 命令行速查

```bash
# 日常
advisor                              # 进入会话
advisor -m deepseek-chat             # 指定模型
advisor --list-models                # 全部模型
advisor --resume                     # 继续上次会话
advisor --encrypt-history            # 口令加密保存历史（默认明文，不问口令）
advisor --no-history                 # 本次不保存历史
advisor --mode=accept-edits --allow-write=~/proj   # 带可写范围启动

# 远程：企微长连接（推荐）
perl remote/wecom-ws.pl --init                 # 录 BotID / Secret
perl remote/wecom-ws.pl --check                # 验证凭据
perl remote/wecom-ws.pl --serve [--mode=...] [--allow-write=...]   # 启动

# 远程：回调模式
perl remote/platform.pl --init / --check / --serve

# 远程：出站通知
perl remote/notify.pl --test
echo "完成" | perl remote/notify.pl -

# 网关单次调试
perl remote/gateway.pl --once --from <UserID> --text "列一下当前目录"
```
