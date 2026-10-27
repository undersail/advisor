# remote/ —— 远程接入

本地功能不依赖这个目录。**删掉 `remote/`，本地行为一字不变**（`scripts/check-decoupling.py` 守着这条界）。

> **这台软件是纯本地的**：不提供任何后端或托管服务。`relay/` 里的 Cloudflare
> Worker 只是一个**可选**的中继，**必须用你自己的 Cloudflare 账号部署**。
> 仓库里不含任何人的账号、令牌、存储 id 或 workers.dev 子域。

## 四个文件

| 文件 | 作用 | 什么时候用 |
|---|---|---|
| `platform.pl` | 企业微信 / 飞书 **回调服务**：验签、AES 解密、把回复推回手机 |
| `gateway.pl` | 远程入口：白名单 / 审计 / 驱动 agent | 要远程派活时 |
| `notify.pl` | 档① 出站通知（企微群机器人 / 飞书自定义机器人） | 只想"跑完了喊我一声" |
| `relay/` | 档② 轮询中继（Cloudflare Worker + Durable Object 队列） | 老 Mac 在 NAT 后、手机要在外面派活 |

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

# 档② 中继
RELAY_URL = https://advisor-relay.<子域>.workers.dev
RELAY_TOKEN = 与 Worker 的 secret 同一个值
POLL_INTERVAL = 4
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

# 档②：一直轮询中继
perl remote/gateway.pl --poll
perl remote/gateway.pl --poll --max-msgs 5     # 处理 5 条就退出（测试用）
```

## 安全边界（写死的，不是开关）

- 远程只能用 `read_file` / `list_dir`。远程没有人在旁边按 y/n，所以写文件和跑命令
  **不存在**。改这条要动 `gateway.pl` 的 `@REMOTE_TOOLS` 并过 review —— 卡口会红。
- 白名单为空 = 全部丢弃。白名单外的人**不回任何内容**（不回"无权限"，避免暴露
  机器人存在），只留审计。
- 审计 `~/.claude-agent/audit.log`：只追加、`0600`。记录入站/丢弃/工具/超时/结果。
- 远程历史目录固定 `~/.claude-agent/history-remote`，与本地历史分开；口令独立。
- webhook URL 与 RELAY_TOKEN 都是凭据：一律走 `curl -K -` 的 stdin，不进 argv、
  不进 `ps`、不进日志；输出里只打名字（如 `WECOM_WEBHOOK`）。
- 单轮 180 秒超时：子进程沉默就杀掉重建，不会永久卡住。

## 验证到什么程度（诚实版）

| 部件 | 自动化测试 | 真机 / 真实平台 |
|---|---|---|
| `gateway.pl`（白名单 / 审计 / 只读） | `scripts/test-remote.py` 20 项 | 本地假模型 + 假 webhook 全过 |
| `platform.pl`（企微 / 飞书回调收 + 发） | `scripts/test-platform.py` **46 项** | **一次都没连过真实平台** |
| `notify.pl`（档① 出站通知） | `scripts/test-remote-notify.py` **22 项** | 同上：只对假 webhook 发过 |
| `relay/worker.js`（Worker + DO 队列） | `test-relay.py` 7 项 + `test-relay-do.mjs` 21 项 | 只跑过 `wrangler dev --local`，**没在你的 CF 账号上部署过** |

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
