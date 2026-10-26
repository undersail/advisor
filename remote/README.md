# remote/ —— 远程接入

本地功能不依赖这个目录。**删掉 `remote/`，本地行为一字不变**（`scripts/check-decoupling.py` 守着这条界）。

> **这台软件是纯本地的**：不提供任何后端或托管服务。`relay/` 里的 Cloudflare
> Worker 只是一个**可选**的中继，**必须用你自己的 Cloudflare 账号部署**。
> 仓库里不含任何人的账号、令牌、KV 命名空间 id 或 workers.dev 子域。

## 三个文件

| 文件 | 作用 | 什么时候用 |
|---|---|---|
| `gateway.pl` | 远程入口：白名单 / 审计 / 驱动 agent | 要远程派活时 |
| `notify.pl` | 档① 出站通知（企微群机器人 / 飞书自定义机器人） | 只想"跑完了喊我一声" |
| `relay/` | 档② 轮询中继（Cloudflare Worker + KV） | 老 Mac 在 NAT 后、手机要在外面派活 |

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

## 已知未完成（档② 的最后一公里）

Worker 只负责「收下消息 / 交出去 / 收回结果」。**把结果真正推回手机**需要平台
自建应用的发送凭据（企微 corp secret + agentid，或飞书 app id/secret + 权限），
并且接收端要处理平台的回调签名与 AES 解密。这部分没做，原因：

1. 需要你的企业主体 / 应用凭据，我这边没有，也无法替你申请；
2. 回调验签与解密各家的算法细节不同，要拿真凭据联调才有意义，mock 验不出问题。

所以当前能用的形态是：**Mac 主动拉取 → 处理 → 结果进 `/outbox`**。
要打通手机端，先确认平台侧的自建应用能拿到凭据，再补这一层。
