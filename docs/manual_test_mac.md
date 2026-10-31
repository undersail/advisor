# Mac 真机验收手册

自动化只能验到「协议构造 + 逻辑分支 + 控件结构」这一层。只有 macOS 真机能确认的是：
**真密钥能不能通、真回调/长连接能不能连上、双击能不能打开、观感对不对**。

全部走一遍约 40 分钟；只验本地部分约 15 分钟，远程部分按需做。

**通则**

- 每一步都写了「应该看到什么」；不符就是缺陷，别自我说服
- 报错时把**消息原文 + HTTP 状态码**发我：401 = 密钥无效、403 = 该地区不可用、000 = 网络不通
- 扫一眼再发：**不要贴密钥**，贴到 `****` 之后的即可

---

## 目录

| 部分 | 章节 | 需要多久 |
|---|---|---|
| 准备与安装 | §1 准备 · §2 安装 | 5 分钟 |
| 本地功能 | §3 终端版 · §4 GUI | 10 分钟 |
| 模式与安全 | §5 交互模式与可写目录 · §6 密钥与隐私 | 8 分钟 |
| 远程接入 | §7 远程接入（7.1～7.9） | 按需 |
| 真机专属 | §8 真机才可能暴露的坑 · §9 出问题怎么查 | — |
| 收工 | §10 收工勾选表 | 1 分钟 |

---

# 1. 准备

```bash
git clone <仓库地址> advisor && cd advisor
```

- macOS 10.13（High Sierra）或更新；系统自带 `perl`、`python3`
- 打包分发才需要 Xcode Command Line Tools
- 一条模型厂商的 API 密钥（7 家任选）

---

# 2. 安装

## 2.1 跑安装向导

```bash
bash setup.sh
```

**应该看到**

- 中文向导；厂商列表 **7 项**（Gemini / Anthropic / OpenAI / DeepSeek / 通义千问 / Kimi / GLM）
- 选一家后：`需要 <厂商名> 的 API 密钥` + 密钥页地址
- 粘贴后：`→ 使用 ...` + `已保存到 ~/.claude-agent-env`
- 最后 `检查 API 连通性` → `API 连接正常`
- 生成 `~/Applications/Advisor.app`

**不对时**：`API 错误(HTTP xxx)` 里的数字就是原因（401 / 403 / 000，见通则）。

## 2.2 打可分发的 zip（可选）

```bash
xcode-select --install                  # 若没装过
bash release/build_standalone_app.sh
```

产物在 `release/` 下。这一步在开发机上验不到（没有 py2app），失败就把完整报错发我。

> 本地 `setup.sh` 生成的 App 是 alias 模式，依赖本机 python3 与源码目录，**不能拷给别的 Mac**；
> 要分发就用上面这条命令产出的独立包。

---

# 3. 终端版验收

```bash
advisor
```

**应该看到**

- `=== high_sierra Advisor ===` + 历史记录提示
- 没配密钥时：`请设置 <厂商> 的密钥`（按界面语言显示）
- 配好后：`有什么需要？>`

| 操作 | 应该看到 |
|---|---|
| `/model` | 先列 **7 家厂商**（不是 12 个模型） |
| 接着输 `4` | 列出该厂商的模型 |
| 接着只按回车 | `已取消`，回到对话 |
| `/deepseek`（该家已配 key） | `已切换到 [deepseek / deepseek-chat]` |
| `/foo` | 当成普通发言发出去，不报「未知命令」 |
| `/help` | 中文帮助 |
| `advisor --list-models` | 12 条，带中文说明 |
| `advisor --version` | 版本号与 `VERSION` 文件一致 |

**最容易露的两处**：`/model` 是否真是两级；切换厂商后顶部模型标签是否跟着变。

**协议深度验证（可选，10 项断言，只打 PASS/FAIL，不含 key）**

```bash
export DEEPSEEK_API_KEY=你的key
python3 scripts/live-check.py deepseek      # 也可 openai / dashscope / moonshot / zhipu
```

---

# 4. GUI 验收

## 4.1 首启画面

```bash
open ~/Applications/Advisor.app
# 或
python3 gui/advisor_gui.py
```

想重看首启：`mv ~/.claude-agent-env /tmp/env.bak` 再打开。

- 一个厂商下拉，**7 项**，中文环境显示中文厂商名
- 切换下拉 → 蓝色「获取密钥」按钮的跳转地址跟着变（点开确认域名）
- 粘 key → 校验通过 → 进主界面
- **不用先点输入框，直接就能打字**

**重点看观感**：下拉宽度、厂商名有没有被截断、按钮与输入框间距、整体是否居中。

## 4.2 模型菜单两级

菜单栏「切换」→ 7 个分组，悬停展开子菜单，当前在用的那条后面带「使用中」。
点一条 → 顶部模型标签跟着变 → 下一句话由新模型回答。

## 4.3 双击打不开怎么办

Finder 双击时 stderr 没地方显示，失败表现是「弹一下就没了」或完全没反应。

```bash
# ① 直接跑包内可执行文件：Finder 看不到的报错会全部打出来
~/Applications/Advisor.app/Contents/MacOS/Advisor

# ② 逐条体检（包结构 / python3 与 Tk / Gatekeeper / 真跑一次 / 崩溃日志）
bash scripts/doctor-macos.sh
```

| 检查 | 应该看到 |
|---|---|
| 解释器/源码不可用 | stderr **先**打出 `Advisor: …`、`解释器: …`、`程序: …` 三行，之后才可能弹窗 |
| 弹窗行为 | 最多停留 **10 秒**自动消失（`giving up after 10`），不需要点「好」 |

| 现象 | 原因 | 处理 |
|---|---|---|
| `exec: /usr/bin/python3: No such file or directory` | macOS 12.3 起 `/usr/bin/python3` 需装 Xcode CLT | 装 python.org 的 Python 3 后重跑 `setup.sh` |
| 图标跳一下就消失 | python3 缺 Tk（Homebrew 版常见） | 装 python.org 版（自带 Tk）；`setup.sh` 会提示缺 Tk 并跳过生成 |
| 弹「无法验证开发者」 | 未签名 + 隔离属性 | 系统设置 → 隐私与安全性 → 「仍要打开」；或 `xattr -dr com.apple.quarantine ~/Applications/Advisor.app` |

```bash
open https://www.python.org/downloads/macos/      # 推荐：安装包自带 Tk
python3 -c "import tkinter; print('tkinter ok')"  # 必须打印 tkinter ok
brew install python python-tk                     # 或者 Homebrew（两件都要装）
```

---

# 5. 交互模式与可写目录验收

三档只改「要不要问」，不改「能做什么」。危险命令在三档里**都会问**。

```bash
advisor                      # 默认 default：写文件/跑命令每次都问
advisor --mode=accept-edits  # 可写范围内写文件不问，命令仍问
advisor --mode=bypass        # 普通写/命令不问，危险命令仍问
/mode                        # 会话内看当前模式；/mode bypass 需再确认一次
/allow-write ~/work/notes    # 追加可写目录；/allow-write 看列表；/allow-write clear 清空
/approvals                   # 最近 10 条自动批准记录
```

逐条勾：

- [ ] `advisor --mode=xxx`（乱写）→ **退出码 2** 并打印「模式名不正确」，**不是**退回 default 继续跑
- [ ] default 下写文件 / 跑命令仍然每次都问（不能为了新功能把旧行为改掉）
- [ ] accept-edits 下在工作目录里写文件不问，但跑命令**仍然问**
- [ ] bypass 下普通写 / 普通命令不问，且消息里出现一行「· 已自动批准：…」
- [ ] bypass 下递归删除类危险命令（**别真按 y**）仍弹确认，确认框里有「★ 这是危险操作」；带 `sudo` 同理
- [ ] 危险确认**放着不管到时限（默认 5 分钟，可把 `CLAUDE_CONFIRM_TIMEOUT` 调成 5 秒来测）** → 自动拒绝并说明「确认无人应答」，会话不卡死
- [ ] 把命令用管道喂进去（没有终端）时，危险命令直接拒绝，不等人
- [ ] bypass 下写 `~/.claude-agent/任意文件` 被拒，理由写「该位置永远不允许写入」
- [ ] bypass 下写工作目录外的文件被拒，并提示 `/allow-write <dir>`；加上之后能写
- [ ] bypass 下用**命令**写到范围外（`echo hi > /tmp/xxx`）也会弹确认；写 `/etc/...` 直接拒绝
- [ ] 不涉及写入的命令（`echo hi`、`ls`）在 bypass 下照旧不问（别被写目标识别误伤）
- [ ] 一条 `sleep 200` 的命令在 120 秒后被中断，结果里说明是超时（不是无声消失）
- [ ] `/allow-write` 显示的「临时目录」就是 macOS 的 `$TMPDIR`（`/var/folders/.../T`），写 `/tmp` 不算默认可写
- [ ] 输出很大的命令只回前 64 KB，并注明原大小
- [ ] `~/.claude-agent/approvals.log` 能看到刚才的自动批准，权限 `-rw-------`，不含 API key
- [ ] GUI：页眉有「模式 ▾」，切换后徽标跟着变（默认=灰、写免确认=强调色、Bypass=**红色**）
- [ ] GUI：Bypass 下写文件不弹窗，但对话里有一行「已自动批准」
- [ ] GUI：从菜单选 Bypass 会先弹一次确认；取消后徽标仍是原来的模式
- [ ] 换主题（笔记 / 编程 / 黑客）后，Bypass 徽标**仍然是红色**
- [ ] 退出再启动，模式沿用上次选择（`~/.claude-agent-env` 里的 `CLAUDE_MODE`）
- [ ] 远程会话**也不能改模式**（档位在 Mac 上启动时定，见 §7.9）

---

# 6. 密钥与隐私验收

- [ ] 装好之后正常用 `advisor`：普通对话、`/model` 换厂商都**不出现「粘贴密钥」的提示**
      （密钥只有两个入口：安装流程、`/key <厂商>`）
- [ ] `/key`（不带参数）→ 列 7 家，标「已配置 / 未配置」，并给一行用法
- [ ] `/key anthropic`（挑没配过的）→ 隐藏输入 → 询问是否保存 → `y` →
      「已保存：<配置文件路径>」；`ls -l ~/.claude-agent-env` 必须是 `600`；
      重启 `advisor` 后 `/key` 列表里那家变成「已配置」
- [ ] `/key 不存在的厂商` → 只报「不认识的厂商」并给用法，不索要输入、不写文件
- [ ] 切到没配密钥的厂商：列表里该行带 `[未配置密钥]`；选中后只提示「要配置请用 /key <厂商>」，
      并**停留在原来的模型上**，继续对话不受影响
- [ ] 把 `~/.claude-agent-env` 里的 key 改坏一个字符再启动 → 说一句话后应看到
      「<厂商> 的密钥被拒绝（HTTP 401）」+「退出后检查/重配」，**不会**在会话里突然索要密钥，
      也不会把原始 JSON 甩到屏幕上
- [ ] 同样改坏 key 后打开 GUI → 对话区出现「后端进程已退出」+ 后端错误原文 + 处理办法；
      不允许「窗口能开但打不进字、也没有任何提示」
- [ ] `~/.claude-agent-env` 若是 sudo 建的、首启页保存密钥失败：弹窗要写清
      「路径 / 属主 / 权限 / `sudo rm <路径>` 再试」；同目录可写时即使文件是 0400 也应能写入
- [ ] 换过厂商后重跑 `setup.sh`：若 env 里留着上一家的模型名，应看到
      「已把模型从 … 改成 <本家默认> …」，连通性检查用**本家**模型名
- [ ] `advisor --resume` 恢复会话后**不再弹厂商编号列表**，只打一行 `[厂商 / 模型]` +
      「要换 AI 请输入 /model」
- [ ] `grep -c "sk-" ~/.claude-agent/audit.log` → 0（审计只有事件名与长度）

---

# 7. 远程接入验收

三种方式互相独立，按需要挑一条验。**先确认本地能跑**再做这一步。

## 7.1 出站通知（最快，1 分钟）

1. `~/.claude-agent/remote.conf` 写一行（企微群 → 群机器人 → 复制 webhook 地址）：
   ```
   WECOM_WEBHOOK = https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
   ```
2. `perl remote/notify.pl --test`
3. 应看到 `通知已发送：WECOM_WEBHOOK`，群里收到「advisor 通知连通性测试 —— 收到即成功。」
4. 长任务收尾：`echo "构建完成" | perl remote/notify.pl -` → 群里收到 markdown，中文与换行正常
5. 不对时：`errcode 93000` = key 无效或地址抄错；`url must start with https` = 粘成了 http

## 7.2 网关（本机直连，验白名单与档位）

1. `~/.claude-agent/remote.conf` 写白名单：
   ```
   ALLOW = alice
   ```
2. `perl remote/gateway.pl --once --from alice --text "列一下当前目录"` → 正常中文回答
3. 换不在白名单的人：`--from bob` → **什么都不输出**，但 `audit.log` 有一行 `drop_sender from=bob`
4. 只读档让它写文件（「在 /tmp 建个文件」）→ 被拒，`/tmp` 下不会出现文件
5. 可写档：

   ```bash
   perl remote/gateway.pl --once --from alice --mode=accept-edits \
        --allow-write=/tmp --text "在 /tmp 建个文件"
   ```

   → 终端里会要你按 y/n 确认

## 7.3 企微长连接：凭据与启动

**准备**：企业微信 → 工作台 → 智能机器人 → 创建机器人 → **API 模式 → 使用长连接**，
记下 `BotID` 与 `Secret`（只显示一次）。不需要公网地址、域名、云资源。

- [ ] 录入：GUI 工具 → 远程接入…（推荐）或 `perl remote/wecom-ws.pl --init`
- [ ] `perl remote/wecom-ws.pl --check` → **20 秒内**给出「订阅通过，凭据可用」
      失败：`errcode≠0` 说明 BotID/Secret 不对（含多粘了空格），或机器人没开「使用长连接」
- [ ] `perl remote/wecom-ws.pl --serve` → 打印「远程服务已启动：pid=… 档位=…」
- [ ] `cat ~/.claude-agent/wecom-ws.pid` → 有 pid / mode / allow_write / started，**没有密钥**
- [ ] 手机给机器人发「列一下当前目录」→ 几秒内回复；先收到「正在处理，请稍等…」也正常
- [ ] 用不在 `ALLOW` 里的账号发 → **零回复**（不是「无权限」），`audit.log` 有 `drop_sender`

## 7.4 远程权限与手机确认

**只读（默认）**

- [ ] 手机发「在目录里新建 hello.txt」→ 被拒，回答里说明不能写，`audit.log` 有 `confirm_refused`

**可写**：`perl remote/wecom-ws.pl --serve --mode=accept-edits --allow-write=~/proj`

- [ ] 手机发「在 proj 里新建 hello.txt」→ 手机收到「需要你确认：…」→ 回 `y` → 文件被创建
- [ ] 再发一次 → 回 `n` → 应回「已拒绝」，文件没有被创建
- [ ] 发一条**不回**的确认 → 等两分钟 → 回「超时按拒绝」，`audit.log` 里 `timeout=1`
- [ ] 手机发 `/mode bypass` → 被拒（远程改不了档位），本机档位不变
- [ ] 写可写范围外的路径（如 `~/Desktop/x`）→ 仍被拒

## 7.5 单实例与退出

- [ ] 服务跑着时再开一个终端跑 `--serve` → 打印「已经有一个远程服务在跑（pid=… 档位=…）」
      并以**退出码 3** 结束
- [ ] 服务窗口按 **Ctrl-C** → 打印「收到 INT，正在退出」；pid 文件消失；`audit.log` 有 `ws_stop`
- [ ] 拔网 40 秒再插回 → 自动重连（`audit.log` 有 `ws_dead` / `ws_reconnect`），不用重启服务
- [ ] `tail -20 ~/.claude-agent/audit.log` 能看到 `ws_start`（带 `mode=`）/ `ws_inbound` / `ws_sent`
- [ ] 审计里能看到 `ws_ca bundle=…`：它写的是实际用的根证书包。
      若为空或报「找不到可用的根证书包」，按 `user_manual` §8.3 处理（退出码 5，不会反复重试）
- [ ] 同一个机器人在另一处也连上（比如另一台机器跑同一份配置）→ 本服务应打印
      「被服务端断开：同一机器人已在别处…」并以**退出码 4** 结束、不再重连；
      审计里有 `ws_kicked`、pid 文件被清理

## 7.6 回调模式：企微（需要公网地址）

- [ ] `perl remote/platform.pl --init` 录凭据 → `--check` → `配置齐全：platform=wecom port=8099`
- [ ] `--serve` → `监听 127.0.0.1:8099（platform=wecom）` + 「默认只监听本机」提醒
- [ ] `remote.conf` 写 `ALLOW = <你的 UserID>`
- [ ] 穿透把 `https://<你的地址>/wecom` 转到 `127.0.0.1:8099`
- [ ] 企微后台「应用 → 接收消息 → API 接收」填 URL / Token / EncodingAESKey，**保存应通过**
      失败看 `audit.log`：`wecom_verify_fail`（Token 不对）、`wecom_receiveid_fail`（AESKey 抄错）
- [ ] 手机给应用发「列一下当前目录」→ 3 秒内先「收到，正在处理…」，随后收到结果
- [ ] 关掉 `--serve` 窗口后手机再发 → 不通（没做守护，这是现状，不是 bug）

## 7.7 回调模式：飞书

- [ ] `--init` 选飞书 → `--check` 显示 `platform=feishu`
- [ ] 飞书开放平台「事件订阅」填 `https://<你的地址>/feishu` → challenge 校验通过
      （明文与加密两种都要能过；填了 Encrypt Key 就走加密）
- [ ] 应用权限加「接收消息」与「以应用身份发消息」，手机私聊该应用 → 先「处理中」再结果
- [ ] 白名单填 `open_id`（`ou_` 开头，不是手机号/邮箱）

## 7.8 边界与安全

- [ ] **白名单外的人**：零回复，`audit.log` 有 `drop_sender from=<那个人>`
- [ ] **重投不会跑两遍**：手机发一条后立刻断网再恢复（平台会重投）→ agent 只跑一次，
      `audit.log` 有 `duplicate_drop`
- [ ] **超长回答**：让它输出 3000 字以上 → 拆成多条，每条开头有「（1/3）」，内容不丢字
- [ ] **凭据不落地**：`grep -c "<你的 Secret\|<你的 AESKey>" ~/.claude-agent/audit.log` → 0
- [ ] **凭据文件权限**：`ls -l ~/.claude-agent/platform.conf` → `-rw-------`
- [ ] **审计只追加**：`ls -l ~/.claude-agent/audit.log` → `-rw-------`

## 7.9 手机端为什么改不了配置

远程 agent 是以「不许改配置」的方式起来的（`--no-config`），所以在手机上试：

- [ ] 发 `/mode bypass` → 回「本次会话不能修改配置（厂商、模型、模式、可写范围、密钥）」；
      本机模式与 `~/.claude-agent-env` 都不变
- [ ] 发 `/model 1`、`/key deepseek` → 同样被拒；`/key` 不会在聊天里索要密钥
- [ ] 发一句正常问题 → 照常回答
- [ ] `audit.log` 里有 `session_start … no_config=1`，以及每次拒绝时的 `reply`

档位与可写目录**只在 Mac 上启动远程服务时**指定；想改就停掉服务带新参数重启。

---

# 8. 真机才可能暴露的坑

| 怀疑点 | 怎么验 | 出问题的表现 |
|---|---|---|
| 某家的真调用形状 | 选那家问一句 | 400/422 → 请求体它不认；`tool_calls` 不返回 → 函数调用不可用 |
| 工具调用闭环 | 让它「读一下 ~/.zshrc」 | 卡住不动 / 报 `tool_result` 相关错误 |
| `max_tokens` 上限 | 让它写长一点的东西 | 报参数非法（各家字段名与上限不一致） |
| 上下文与限流 | 连续问 5 轮 | 429 限流（错在限速，不是功能） |
| `setup.sh` 的 bash 3.2 | 跑一遍安装 | `mapfile: command not found` 之类 → 误用了 bash 4 特性 |
| 包装脚本 | `advisor --list-models` | 报错说明取不到 provider |
| 长连接 TLS | `--check` 连真服务端 | 证书 / SNI 问题只在真机出现 |
| py2app 打包 | `bash release/build_standalone_app.sh` | 需要 Xcode CLT；只分发时做 |

---

# 9. 出问题怎么查

## 9.1 本地

| 现象 | 多半是 | 处理 |
|---|---|---|
| 一启动就要密钥 | `~/.claude-agent-env` 缺 `CLAUDE_PROVIDER`，或 key 变量为空 | 重跑 `setup.sh` 或 `/key <厂商>` |
| `HTTP 401` | 密钥无效 / 过期 | 换 key |
| `HTTP 403` | 该地区不可用 | 换厂商 |
| `000` / 超时 | 网络不通 | 换网络或代理 |
| 双击 App 没反应 | 未签名 / 缺 Tk | 见 §4.3 |
| 模式或可写目录不生效 | 参数用错了入口 | 会话内用 `/mode`、`/allow-write`；或写在启动参数里 |

## 9.2 远程

| 现象 | 看哪里 | 常见原因 |
|---|---|---|
| 启动即退出码 3 | 提示里的 pid | 已有一个在跑，先 kill |
| `--check` 报 `errcode` | 提示原文 | BotID / Secret 不对，或没开「使用长连接」 |
| 手机发了没反应、无 `ws_inbound` | `audit.log` | 服务没跑 / 白名单没写对 |
| 有 `ws_inbound` 无 `gateway_done` | `audit.log` | 本机模型不通（先在终端跑一次 `advisor`） |
| 一直「正在处理」 | `turn_timeout` | 模型太慢或网络断了 |
| 让它写文件没写 | `confirm_refused` | 档位是只读 |
| 过一段时间就断 | `ws_session_end` | 心跳被中间设备掐了，把 `HEARTBEAT` 调小（如 20 秒）再试 |
| 回调：保存 URL 失败 | `wecom_verify_fail` / `wecom_receiveid_fail` | Token 或 AESKey 不一致 |
| 回调：有 `gateway_done` 手机没收到 | `wecom_send_fail` / `feishu_send_fail` | 没开发送权限，或 ID 类型不对 |

## 9.3 自查命令

```bash
advisor --version
perl remote/wecom-ws.pl --check
tail -30 ~/.claude-agent/audit.log
tail -20 ~/.claude-agent/wecom-ws.log
grep -o '^export [A-Za-z0-9_]*' ~/.claude-agent-env    # 只看变量名，不打印值
```

---

# 10. 收工勾选表

**本地（必验）**

- [ ] `setup.sh` 走通，连通性检查通过，`Advisor.app` 生成
- [ ] 终端：`/model` 两级、`/key`、`/help`、`--list-models` 12 条
- [ ] GUI：首启 7 家厂商、密钥校验、模型菜单两级、直接能打字
- [ ] 三档交互模式与危险命令确认（§5 全勾）
- [ ] 密钥与隐私（§6 全勾）
- [ ] 长期记忆：`/remember` 记一条 → **退出重进**还在；`/memory` 能增删；模型自己要记时会先问
- [ ] 技能：放一个 `SKILL.md` 进 `~/.claude-agent/skills/` → `/skills` 能看到 → 派个匹配的任务，
      看它是否先 `read_file` 读那个技能再照着做

**远程（按需）**

- [ ] 出站通知能收到
- [ ] 白名单内外行为正确（零回复 + `drop_sender`）
- [ ] 长连接 `--check` 通过、`--serve` 能收发
- [ ] 手机确认 y / n / 超时三条都对
- [ ] 单实例被拒（退出码 3）、Ctrl-C 优雅退出
- [ ] 远程用中文提问，回复**和工具调用旁的进度说明**都是中文（不应出现日文）
- [ ] 手机端改不了档位与配置
- [ ] 远程面板「启动服务」能起来（不再报「找不到 wecom-ws.pl」；真缺文件时会列出找过的路径）
- [ ] 面板档位名称与主界面完全一致（默认 / 写文件免确认 / Bypass），字体与别处一致
- [ ] 启动后光标直接在输入框里，能立刻打字（若窗口没成为前台，状态栏会提示「点一下输入框」）
- [ ] 输入框与会话区的底色、分隔线看得出是两块
- [ ] 有旧 `key.enc` 的机器：`--make-plain-history` 输一次口令后，**再启动不问口令**

验完把「哪一条不符 + 你看到的消息原文」发我即可。

## 远程确认出问题时，先抓这三行审计

```bash
grep -E "confirm_asked|confirm_drain|gateway_asked|gateway_answer|confirm_answered|answer_early" \
  ~/.claude-agent/audit.log | tail -20
```

| 看到什么 | 说明 |
|---|---|
| `confirm_asked … cid=… wait=…` | 网关把问题发出去了，并写明等多久（默认 115 秒） |
| `gateway_asked` 之后**没有** `gateway_answer` | 手机的答复没进网关：可能是消息没送到、或客户端把它当成新指令了 |
| `answer_early` / `early_answer_used` | 答复比客户端记下「等确认」还早到 —— 已自动攒起来用掉（v0.2.6 起） |
| `confirm_answered … stale=1` | 答复带的 cid 对不上，被判成上一道题的迟到答复（丢弃） |
| `confirm_answered … timeout=1` | 到点没等到答复，按拒绝处理，并已回你一句「这次操作没有执行」 |

真机验收：让它做一次需要确认的操作 → ①回 y 应执行 ②回 n 应拒绝 ③不回，到点后应收到
「（确认超时，这次操作没有执行）」，并且审计里三行能对上。
