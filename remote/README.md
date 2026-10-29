# remote/ —— 远程接入

本地功能不依赖这个目录。**删掉 `remote/`，本地行为一字不变**（`scripts/check-decoupling.py` 守着这条界）。

> **这台软件是纯本地的**：不提供任何后端或托管服务，也**不需要**你申请任何云资源。
> 远程接入只依赖企业微信/飞书自己的开放平台凭据，仓库里不含任何人的账号或令牌。

## 四个文件

| 文件 | 作用 | 什么时候用 |
|---|---|---|
| `platform.pl` | 企业微信 / 飞书 **回调服务**：验签、AES 解密、把回复推回手机 |
| `gateway.pl` | 远程入口：白名单 / 审计 / 驱动 agent | 要远程派活时 |
| `notify.pl` | 档① 出站通知（企微群机器人 / 飞书自定义机器人） | 只想"跑完了喊我一声" |
| `wecom-ws.pl` | 企微智能机器人 **长连接**（API 模式）：本机连出去，不收回调 | **没有公网域名**、又不想开 Cloudflare 时，首选这个 |

## 配置 `~/.claude-agent/remote.conf`

```
ALLOW = alice, ou_xxxxxxxx          # 白名单。不配 = 谁也不许（fail-closed）
NOTIFY = 1                          # 处理完推一条通知（默认 1）
LANG = zh                           # 回复语言 zh/en/ja（默认 zh）
AGENT_ENV_FILE = ~/.claude-agent-env # agent 的模型/密钥来源

# 远程历史（两个都配才会真的写；只配一个会退化为不写历史）
HIST_PASS = 一串口令
HIST_RECOVERY = 你养的第一只宠物叫什么|旺财

# 档① 通知（企微群 → 群机器人；飞书群 → 自定义机器人）
WECOM_WEBHOOK = https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
FEISHU_WEBHOOK = https://open.feishu.cn/open-apis/bot/v2/hook/...
```

这个文件建议 `chmod 600` —— 里面有 webhook 和令牌。

## 怎么跑

```bash
# 只验通知（10 秒）
perl remote/notify.pl --test

# 一次性处理一条（调试用；白名单外的人不会有任何输出）
perl remote/gateway.pl --once --from alice --text "列一下当前目录"

# 从标准输入读 JSON 行（脚本化/调试）
echo '{"from":"alice","text":"你好"}' | perl remote/gateway.pl --stdin
```

## 安全边界（写死的，不是开关）

- 远程只能用 `read_file` / `list_dir`。远程没有人在旁边按 y/n，所以写文件和跑命令
  **不存在**。改这条要动 `gateway.pl` 的 `@REMOTE_TOOLS` 并过 review —— 卡口会红。
- 白名单为空 = 全部丢弃。白名单外的人**不回任何内容**（不回"无权限"，避免暴露
  机器人存在），只留审计。
- 审计 `~/.claude-agent/audit.log`：只追加、`0600`。记录入站/丢弃/工具/超时/结果。
- 远程历史目录固定 `~/.claude-agent/history-remote`，与本地历史分开；口令独立。
- webhook URL 是凭据：一律走 `curl -K -` 的 stdin，不进 argv、
  不进 `ps`、不进日志；输出里只打名字（如 `WECOM_WEBHOOK`）。
- 单轮 180 秒超时：子进程沉默就杀掉重建，不会永久卡住。

## 验证到什么程度（诚实版）

| 部件 | 自动化测试 | 真机 / 真实平台 |
|---|---|---|
| `gateway.pl`（白名单 / 审计 / 只读） | `scripts/test-remote.py` 20 项 | 本地假模型 + 假 webhook 全过 |
| `platform.pl`（企微 / 飞书回调收 + 发） | `scripts/test-platform.py` **46 项** | **一次都没连过真实平台** |
| `notify.pl`（档① 出站通知） | `scripts/test-remote-notify.py` **22 项** | 同上：只对假 webhook 发过 |
| `wecom-ws.pl`（长连接收 + 发） | `scripts/test-wecom-ws.py` **35 项**（本机假服务端，逐个字段对协议） | 除 wss/TLS 那一段外全验；真连需你的 BotID + Secret |

自动化覆盖到的是**确定性部分**：验签（企微 `sha1(sort(token,ts,nonce,encrypt))`、飞书
`sha256(ts+nonce+key+body)`）、AES-256-CBC 解密、PKCS#7 去填充、企微 ReceiveId 完整性、
时间戳防重放、按 MsgId 去重、超长回复按字节切分、报文形态、凭据 0600、默认只听 127.0.0.1、
以及"密钥不外泄到日志"。

**覆盖不到、必须真连的**：平台侧凭据是否真的有效、回调地址是否真的公网可达、白名单里的
UserID / open_id 是否真的对、平台错误码在实际配额/权限下的表现、以及 CF 账号上的真实部署。
这几项的准备与逐条验收步骤写在 `docs/manual_test_mac.md` §12。

## 平台端收发（`platform.pl`）

手机 → 平台回调 → `platform.pl` → `gateway.pl`（白名单/审计/只读都在这里）→ 回复推回手机。

```bash
perl remote/platform.pl --init                  # 录入凭据（存 ~/.claude-agent/platform.conf，0600）
perl remote/platform.pl --check                 # 只校验配置
perl remote/platform.pl --serve                 # 起回调服务（默认 8099）
perl remote/platform.pl --test-push "测试" --to <你的ID>   # 验凭据与网络
```

- 回调地址：`https://<你的域名或穿透地址>/wecom`（企微）或 `/feishu`（飞书），
  **必须公网可达**，本机 NAT 后需要内网穿透
- 白名单仍然只在 `~/.claude-agent/remote.conf` 的 `ALLOW` 里配（企微填 UserID，飞书填 open_id），
  platform.pl 自己不判白名单 —— 判定与审计只有一处
- 企微要核对明文尾部的 ReceiveId 是否等于本企业 CorpID（规范里的完整性校验），对不上就拒绝
- 凭据只在这台机器上；仓库里不含任何人的 corp id / secret / AESKey

## 企微智能机器人长连接（API 模式 · 使用长连接）

HTTP 回调模式在解决一个难题：**平台要主动 POST 到你机器上，而家里的 Mac 没有公网 IP**。
长连接把方向反过来——**本机主动连出去**，所以：不用域名、不用内网穿透、不用云服务，
凭据只有 **BotID + Secret**，也没有 AES / 验签那些活。

```
手机 ──(企业微信长连接)──> wecom-ws.pl ──(--stdin)──> gateway.pl ──> agent
                              ↑ 只有传输：握手、帧、心跳、重连
```

**GUI 里也能配**（推荐给不习惯终端的人）：菜单 **工具 → 远程接入…**，
填 BotID / Secret（掩码输入，保存后不回显旧值）、白名单，点「保存」写的就是下面这同一个文件，
点「测试连接」会把 `--check` 的真实结果（含 errcode）打在面板上。重启后会从文件读回状态，
**不需要重填**。

命令行等价写法：

```bash
perl remote/wecom-ws.pl --init     # 录入 BotID / Secret（隐藏输入，写 ~/.claude-agent/wecom-ws.conf 0600）
perl remote/wecom-ws.pl --check    # 只连一次：验凭据能不能订阅成功（不启动 agent）
perl remote/wecom-ws.pl --serve    # 常驻：收消息 → 跑 agent → 回消息（Ctrl-C 结束）
```

- 凭据位置在 **企业微信 → 工作台 → 智能机器人 → 创建机器人 → API 模式 → 使用长连接**
  （给你的就是 BotID + Secret 两个值）
- 配置 `~/.claude-agent/wecom-ws.conf`（0600）：`BOT_ID` / `BOT_SECRET` / `WS_URL`
  （默认 `wss://openws.work.weixin.qq.com`）/ `HEARTBEAT`（默认 30 秒）/ `TEXT_LIMIT`（默认 1900 字节）/
  `ACK_AFTER`（超过这么多秒没出结果就先回一句「正在处理」）
- **协议**：握手后先发 `aibot_subscribe`（带 BotID + Secret）→ 收到 `aibot_msg_callback` →
  回 `aibot_respond_msg`（沿用回调的 `req_id`，否则平台不知道你在回哪条消息）→
  每 30 秒发一次 `ping` 心跳，连续两次没回执判死重连（退避 1→30 秒）
- **白名单、审计、只读工具集一律仍由 `gateway.pl` 负责**，本文件不自己判任何人
  （`scripts/check-decoupling.py` 会拦住"在这里读 ALLOW"的写法）
- 只做文本消息；图片/文件等先回一句「暂只支持文本消息」，不静默吞
- 超长回复按字节分片，每片带「（n/m）」前缀
- 零 CPAN：perl 核心没有 TLS，wss 走 `openssl s_client` 子进程当管道，WebSocket 帧在本文件里手写编解码
- 想开机常驻：用 `launchd`（macOS）或 `nohup ... &`，路径写绝对路径即可；本工具不写任何系统配置
