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
6. [远程接入：手机派活](#6-远程接入手机派活)
7. [配置与数据放在哪](#7-配置与数据放在哪)
8. [出问题怎么查](#8-出问题怎么查)
9. [安全与隐私](#9-安全与隐私)
10. [命令行速查](#10-命令行速查)

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
| `/help` | 中文帮助 |

**历史与会话**（默认加密保存）：

```bash
advisor --list-history        # 列出历史会话
advisor --resume              # 继续上次的会话
advisor --change-passphrase   # 改历史口令
advisor --set-recovery        # 设置/修改恢复用的合口令
```

历史口令只有你自己知道；口令丢了里面的历史打不开（程序不会假装能恢复）。

---

## 4. 图形界面使用

- 双击 `~/Applications/Advisor.app`，或 `python3 gui/advisor_gui.py`
- 首次打开让你选厂商 + 粘密钥，校验通过即进主界面
- 顶部标签显示当前「厂商 / 模型」，菜单栏「切换」里按厂商分组选模型
- 工具 → **登记 API 密钥**：换密钥
- 工具 → **远程接入…**：配置企微长连接、权限档位、可写目录，并能启动/停止远程服务
- 输入框在启动后、每轮回复后都会自动获得焦点，打开就能打字

如果双击打不开，先看第 8 节的「双击 Advisor.app 没反应」。

---

## 5. 交互模式与可写目录

Advisor 可以读写文件、执行命令，**默认每一类操作都会先问你**。三种模式：

| 模式 | 读文件 | 写文件 | 执行命令 |
|---|---|---|---|
| `default`（默认） | 直接做 | 每次确认 | 每次确认 |
| `accept-edits` | 直接做 | 可写目录内直接做 | 每次确认 |
| `bypass` | 直接做 | 直接做 | 直接做，**危险命令仍确认** |

- 切换：会话内 `/mode`，或启动时 `--mode=accept-edits`
- 可写范围：`--allow-write=<目录>`（可多次），会话内 `/allow-write <目录>`、`/allow-write clear`
- **删除、改权限、系统级操作**在任何模式下都要确认（`bypass` 也不例外）
- 没人回答确认（比如远程会话手机没回）→ 超时按**拒绝**处理，不会放行

`accept-edits` / `bypass` 请只在你信任的项目目录里用。

---

## 6. 远程接入：手机派活

三种方式，按推荐排序：

| 方式 | 需要什么 | 适合 |
|---|---|---|
| **企业微信智能机器人（长连接）** | BotID + Secret | 家里普通宽带，**不需要公网**（推荐） |
| 企业微信/飞书自建应用（HTTP 回调） | 公网 HTTPS 地址 + 应用凭据 | 有公网域名或内网穿透 |
| 出站通知（只发不收） | 群机器人 webhook | 长任务跑完提醒你 |

### 6.1 企业微信长连接（推荐）

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

### 6.2 自建应用（HTTP 回调）

需要公网可达的 `https://` 地址（域名、或内网穿透都行）。

```bash
perl remote/platform.pl --init     # 录入 CorpID / AgentId / Secret / Token / EncodingAESKey
perl remote/platform.pl --check    # 显示：配置齐全：platform=wecom port=8099
perl remote/platform.pl --serve    # 监听 127.0.0.1:8099（默认只听本机，这是故意的）
```

企微后台「应用 → 接收消息 → API 接收」填 URL / Token / EncodingAESKey，保存应当通过。
飞书同理，`--init` 时选飞书，事件订阅地址填 `/feishu`，白名单填 `open_id`（`ou_` 开头）。

### 6.3 出站通知（只发不收）

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

## 7. 配置与数据放在哪

| 路径 | 内容 | 权限 |
|---|---|---|
| `~/.claude-agent-env` | 厂商、模型、API 密钥 | 0600 |
| `~/.claude-agent/remote.conf` | 白名单 `ALLOW`、通知 webhook、远程历史口令 | 0600 |
| `~/.claude-agent/platform.conf` | 企微/飞书回调凭据 | 0600 |
| `~/.claude-agent/wecom-ws.conf` | 企微长连接 BotID / Secret / 档位 / 可写目录 | 0600 |
| `~/.claude-agent/wecom-ws.pid` | 远程服务状态（pid / 档位 / 启动时间） | 0600 |
| `~/.claude-agent/audit.log` | 远程会话审计（只追加） | 0600 |
| `~/.claude-agent/wecom-ws.log` | 远程服务运行日志 | 0600 |
| `~/Applications/Advisor.app` | 双击入口（安装时生成） | — |

图形界面与命令行写的**是同一份文件** —— 在一边改，另一边立刻生效；重启程序会读回，不用重填。

---

## 8. 出问题怎么查

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

## 9. 安全与隐私

- **密钥只存本机**：`~/.claude-agent-env`（0600）；不进日志、不进命令行参数、不进对话
- **不进 Git**：仓库里没有你的密钥、路径、账号
- **远程白名单**：只有 `ALLOW` 里的人能指挥；其他人发消息**零回复**，只记审计
- **远程权限自己定**：默认只读；放开要显式在启动时指定；手机上改不了
- **确认不会被绕过**：危险操作在任何模式都要人确认，没人确认就按拒绝处理
- **审计只追加**：`audit.log`（0600）记录谁在什么时候让这台机器做了什么
- **历史加密**：会话历史用你的口令加密；口令丢了就打不开（不假装能恢复）

---

## 10. 命令行速查

```bash
# 日常
advisor                              # 进入会话
advisor -m deepseek-chat             # 指定模型
advisor --list-models                # 全部模型
advisor --resume                     # 继续上次会话
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
