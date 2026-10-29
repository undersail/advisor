# 远程服务操作手册（企业微信长连接）

一句话：**只有一个服务** —— `remote/wecom-ws.pl --serve`。命令行和 GUI 都只是启动它的入口，
写的是同一份配置（`~/.claude-agent/wecom-ws.conf`），状态看的是同一个 pid 文件
（`~/.claude-agent/wecom-ws.pid`）。不存在「GUI 版服务」和「命令行版服务」两套东西。

---

## 1. 先配凭据（两种入口，二选一）

- **GUI**：菜单 **工具 → 远程接入…** → 填 BotID / Secret（掩码）→ 保存
- **命令行**：`perl remote/wecom-ws.pl --init`（隐藏输入）

凭据来自：企业微信 → 工作台 → 智能机器人 → 创建机器人 → **API 模式 → 使用长连接**。
只需要 `BotID` + `Secret`，不需要公网地址、不需要域名、不需要云端资源。

验证凭据：`perl remote/wecom-ws.pl --check`（20 秒内给结论，`--check` 只排队订阅一次，不进消息循环）。

---

## 2. 启动

```bash
# 只读（默认，最安全）
perl remote/wecom-ws.pl --serve

# 允许改文件：只能在这台 Mac 上、启动时指定
perl remote/wecom-ws.pl --serve --mode=accept-edits --allow-write=/Users/Jack/proj

# 更放开：普通命令也自动（危险命令仍要确认）
perl remote/wecom-ws.pl --serve --mode=bypass --allow-write=/Users/Jack/proj
```

GUI 入口：**工具 → 远程接入… → 启动服务**（用面板里保存的档位与可写目录）。
GUI 起的和命令行起的是**同一个服务**，看到的 pid 文件、审计、日志都是同一份。

**档位只能在启动时定**，起来之后手机端改不了（agent 用 `--no-config` 起，
`/mode`、`/allow-write`、`/key` 一律被拒）。要换档位：停掉服务，用新参数再启动。

| 档位 | 手机能干的事 |
|---|---|
| `default`（默认） | 只能看：`read_file` / `list_dir` |
| `accept-edits` | 可写目录内自动写文件；跑命令每次要确认 |
| `bypass` | 普通写与命令都自动；**危险命令仍要确认** |

---

## 3. 需要确认时（手机上回 y / n）

agent 要做需要确认的操作时，手机收到：

```
⚠ 危险操作，需要你在手机上确认：删除 /Users/Jack/proj/tmp.log ？
回复 y 允许 / n 拒绝（不回则超时按拒绝处理）
```

- 回 `y` → 放行
- 回 `n` → 拒绝
- **不回** → 默认 120 秒后按拒绝（`--confirm-wait=秒` 可调）
- 回的是别的话 → 先按拒绝收尾，再把这句话当新指令，不会把人卡住

---

## 4. 多启动保护（防重复回复 / 防重复操作）

服务启动时会在 `~/.claude-agent/wecom-ws.pid` 上加 `flock` 独占锁：

- 第二个 `--serve` **会立刻被拒绝，退出码 3**，并告诉你已有实例的 pid 与档位：

  ```
  已经有一个远程服务在跑（pid=51234 档位=accept-edits）。要重启就先停掉它：kill 51234
  ```

- 为什么必须挡：两个实例各起一个 agent，同一条消息会被处理两遍 —— 用户看到重复回复，
  文件和钱都可能被操作两次。

pid 文件内容（**不含任何密钥**）：

```
pid=51234
mode=accept-edits
allow_write=/Users/Jack/proj
started=Thu Oct 29 11:58:55 2026
version=0.3.0
```

---

## 5. 保活

| 机制 | 行为 |
|---|---|
| 心跳 | 每 30 秒发 `ping`；连续两次无回执判死，主动断开重连 |
| 断线重连 | 退避 1 → 2 → 4 → 8 → 16 → 30 秒（上限 30 秒），无上限重试 |
| 对端突然断开 | 立刻重连（不等心跳才发现） |
| 写已关闭的连接 | 忽略 `SIGPIPE`，不会被信号杀掉，重连逻辑一定跑得到 |
| 订阅被拒 | `errcode≠0`（BotID/Secret 不对）连续 3 次就停下，不无脑重试 |
| 电脑重启 / 睡眠唤醒 | 不会自动恢复，需要重新启动服务（见 §8 开机自启） |

---

## 6. 退出

- **Ctrl-C** 或 `kill <pid>`（SIGTERM）/ `kill -HUP <pid>`：优雅退出 ——
  写审计 `ws_stop`、删 pid 文件、放掉锁
- **GUI**：工具 → 远程接入… → 停止服务（先 SIGTERM，6 秒不退再 SIGKILL）
- `kill -9` 强杀：锁会随进程消失自动释放；残留的 pid 文件下次启动会被接管
  （判活看进程在不在，不看文件在不在）

---

## 7. 看状态与排错

```bash
cat ~/.claude-agent/wecom-ws.pid              # pid / 档位 / 可写目录 / 启动时间
tail -20 ~/.claude-agent/wecom-ws.log         # 连接日志
tail -30 ~/.claude-agent/audit.log            # 审计（只追加，0600）
```

关键审计行：

| 行 | 含义 |
|---|---|
| `ws_start` | 服务启动，带 `mode=` 与可写目录 |
| `ws_inbound` / `ws_sent` | 收到 / 回复消息 |
| `confirm_asked` / `confirm_answered` | 手机上问过 / 答过（`timeout=1` 表示超时按拒绝） |
| `confirm_refused` | 只读档收到确认请求，直接拒 |
| `ws_reconnect` / `ws_session_end` | 重连 / 断开原因 |
| `ws_stop` | 优雅退出 |

| 现象 | 多半是 |
|---|---|
| 启动即退出码 3 | 已经有一个在跑（按提示 kill 旧 pid） |
| `--check` 报 `errcode` | BotID / Secret 不对，或机器人没开「使用长连接」 |
| 手机发消息没反应 | 服务没跑 / 发送者不在 `ALLOW` 白名单（非白名单**不回任何话**，只记日志） |
| 回复里没有写文件的动作 | 档位是 `default`（只读） |
| 一直在「正在处理」 | agent 那一轮超时或模型不可达，看 `audit.log` 的 `turn_timeout` |

---

## 8. 开机自启（可选，macOS launchd）

`~/Library/LaunchAgents/cc.advisor.wecomws.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>cc.advisor.wecomws</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/perl</string>
    <string>/Users/Jack/claude-build/remote/wecom-ws.pl</string>
    <string>--serve</string>
    <string>--mode=accept-edits</string>
    <string>--allow-write=/Users/Jack/proj</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/Jack/.claude-agent/wecom-ws.log</string>
  <key>StandardErrorPath</key><string>/Users/Jack/.claude-agent/wecom-ws.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/cc.advisor.wecomws.plist     # 装上并启动
launchctl unload ~/Library/LaunchAgents/cc.advisor.wecomws.plist   # 停掉并取消
```

注意：`KeepAlive` 会让 launchd 在你手动 kill 后自动重启 —— 想彻底停就先 `unload`。

---

## 9. 验收清单（对应 `manual_test_mac.md` §9.8）

1. `--check` 通过（凭据可用）
2. `--serve` 起来后 `cat wecom-ws.pid` 看到 pid 与档位
3. 再起第二个 → 退出码 3 且提示已有 pid
4. 手机发消息 → 有回复；非白名单用户 → 无任何回复
5. 只读档：让它写文件 → 被拒（`confirm_refused`）
6. `accept-edits` 档：让它写 → 手机收到确认 → 回 `n` 不落盘、回 `y` 落盘
7. 一条确认不回 → 120 秒后回「超时按拒绝」，审计 `timeout=1`
8. 拔网 40 秒再插回 → 自动重连，审计有 `ws_reconnect`
9. Ctrl-C 退出 → 审计有 `ws_stop`、pid 文件被删
