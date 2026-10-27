# Mac 真机验收清单

本机（Linux）只能验到「协议构造 + 逻辑分支 + 控件结构」这一层。下面这些**只有
macOS 真机能确认**，按顺序做一遍大概 15 分钟。

每一步都写了「应该看到什么」和「不对的话把什么发给我」。发之前扫一眼有没有
密钥 —— 不要贴 key，贴到 `****` 之后的即可。

---

## 0. 准备

```bash
git clone git@github.com:undersail/advisor.git
cd advisor
```

需要：macOS 10.9 或更新（Tier B）+ 系统自带 perl/python3。
Xcode Command Line Tools **只有打 zip 包才需要**，装普通版不需要。

---

## 1. 终端版跑通（不装 GUI）

```bash
export DEEPSEEK_API_KEY=你的key      # 或先不设，看它是否给出指引
perl agent/claude-agent.pl
```

**应该看到**
- 中文环境：`=== high_sierra Advisor ===` + 历史记录提示
- 没有 key 时：`DEEPSEEK_API_KEY を設定してください`（或对应语言）
- 有 key 时：`有什么需要？>`

**顺手验三项**
| 操作 | 应该看到 |
|---|---|
| 输入 `/model` | 先列 **7 家厂商**（不是 12 个模型） |
| 接着输 `4` | 列出 DeepSeek 的两个模型 |
| 接着只按回车 | `已取消`，回到对话 |
| 输入 `/deepseek`（已有 key） | `已切换到 [deepseek / deepseek-chat]` |
| 输入 `/foo` | 当成普通发言发出去，不报"未知命令" |
| 输入 `/help` | 中文帮助 |

**这里最容易露的两处**：`/model` 是否真是两级、`/deepseek` 切换后 `model_lbl` 是否跟着变。

---

## 2. setup.sh 安装

```bash
bash setup.sh
```

**应该看到**
- 中文向导，厂商列表是 **7 项**（Gemini / Anthropic / OpenAI / DeepSeek /
  通义千问 / Kimi / GLM），不是原来的 2 项
- 选一家后：`需要 <厂商名> 的 API 密钥` + 密钥页 URL
- 粘贴后：`→ 使用 ...` + `已保存到 ~/.claude-agent-env`
- 最后 `检查 API 连通性` → `API 连接正常`

**不对的话**：把 `消息里的中文提示` + `HTTP 状态码` 发我。特别注意
`APIエラー(HTTP xxx)` 里的数字 —— 401 是 key 无效、403 是这家封了你的地区、
000 是网络根本不通。

然后重开终端：
```bash
advisor --version     # advisor (high_sierra_claude) <VERSION 文件里的版本>
advisor --list-models # 12 条，带中文说明
advisor -m glm-4.6    # 指定模型起一轮
```

---

## 3. GUI：首启画面

```bash
open ~/Applications/Advisor.app     # setup.sh 生成的双击版
# 或
python3 gui/advisor_gui.py
```

（若已存在 `~/.claude-agent-env` 且里面有 key，会直接进主界面 —— 想重看首启就
`mv ~/.claude-agent-env /tmp/env.bak`）

**应该看到**
- 一个下拉，**7 项**，中文环境显示中文厂商名（`通义千问（阿里云）` 这种）
- 切换下拉 → 下面那个蓝色「获取密钥」按钮的跳转地址跟着变（点开看一眼域名对不对）
- 粘 key → 校验通过 → 进主界面

**重点看观感**（这部分我没法在本机验）：
下拉框宽度够不够、厂商名有没有被截断、按钮与输入框的间距、整体是否居中。

---

## 4. GUI：模型菜单两级

主界面菜单栏点开「切换」那一项。

**应该看到**：7 个分组，鼠标悬停展开子菜单，列出该厂商的模型；当前在用的那条
后面带「使用中」。

点一个 → 顶部模型标签跟着变 → 下一句话由新模型回答。

---

## 5. 真机才可能暴露的坑（按怀疑度排序）

| 怀疑点 | 怎么验 | 出问题的表现 |
|---|---|---|
| **`/deepseek` 真调用** | 选 DeepSeek 问一句 | 400/422 → 请求体它不认；`tool_calls` 不返回 → 函数调用不可用 |
| **工具调用闭环** | 让它「读一下 ~/.zshrc」 | 卡住不动 / 报 `tool_result` 相关错误 |
| **`max_tokens` 上限** | 让它写长一点的东西 | 报参数非法（各家的字段名和上限不一致） |
| **Kimi/GLM 上下文与限流** | 连续问 5 轮 | 429 限流；错就错在限速，不是功能 |
| **`setup.sh` 的 bash 3.2** | 跑一遍安装 | `mapfile: command not found` 之类 → 说明误用了 bash 4 特性 |
| **包装脚本报错** | `advisor --list-models` | 说明 `provider_of` 取不到 provider |
| **py2app 打包** | `bash release/build_standalone_app.sh` | 需要 Xcode CLT；只在要分发时做 |

---

## 6. 打可分发 zip（可选）

```bash
xcode-select --install          # 若没装过
bash release/build_standalone_app.sh
```

产物在 `release/` 下。**这一步在本机完全没验过**（Linux 没有 py2app），
如果失败把完整报错发我。

---

## 7. 想更彻底：用脚本验协议

```bash
export DEEPSEEK_API_KEY=你的key
python3 scripts/live-check.py deepseek
```

10 项断言，只打印 PASS/FAIL，**不含 key**。想验别家就换参数
（`openai` / `dashscope` / `moonshot` / `zhipu`；`anthropic` / `gemini` 走另外两种
请求形状，脚本目前只覆盖 OpenAI 兼容那五家）。

## 8. 远程接入（可选，M5）

远程和本地是两套东西，先确认本地能跑再做这一步。

### 8.1 只验通知（最快，1 分钟）

1. 建 `~/.claude-agent/remote.conf`，写一行（企微群 → 群机器人 → 复制 webhook 地址）：
   ```
   WECOM_WEBHOOK = https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
   ```
2. 跑：`perl remote/notify.pl --test`
3. 应看到：`通知已发送：WECOM_WEBHOOK`，手机上群里收到一条
   「advisor 通知连通性测试 —— 收到即成功。」
4. 不对时看：`通知发送失败：WECOM_WEBHOOK（errcode 93000: ...）` —— 93000 是
   key 无效或地址抄错；报 `url must start with https` 说明粘成了 http。

### 8.2 验网关（远程只读）

1. 同目录加白名单（先随便写你自己的 ID，随便什么串都行，这里只验证拦截逻辑）：
   ```
   ALLOW = alice
   ```
2. 跑一条：`perl remote/gateway.pl --once --from alice --text "列一下当前目录"`
3. 应看到：正常的中文回答（说明 agent 被网关驱动起来了）
4. 换成不在白名单的人：`perl remote/gateway.pl --once --from bob --text "ls"`
   应看到：**什么都没有输出**（不回"无权限"，避免暴露机器人存在），
   但 `~/.claude-agent/audit.log` 里有一行 `drop_sender from=bob`。
5. 试让它写文件：「在 /tmp 建个文件」 —— 应被拒绝，且 `/tmp` 下不会出现文件。
   拒绝理由会回给模型，模型会转述给你。

### 8.3 验收要点（对着看，别只看"跑通了"）

- [ ] `~/.claude-agent/audit.log` 存在且权限 `-rw-------`
- [ ] 白名单外的人：无输出、有审计
- [ ] 让写文件：没写成，且回答里说明了不能写
- [ ] `remote.conf` 里没有 `HIST_PASS` 时，`~/.claude-agent/history/` 不该多出东西

## 9. 平台端收发（真机 + 真平台）

本地已经把**确定性部分**验干净了，不需要你重复：

| 脚本 | 项数 | 覆盖 |
|---|---|---|
| `scripts/test-platform.py` | 46 | 验签、AES 解密、ReceiveId、防重放、去重、超长切分、报文形态、0600、只听 127.0.0.1、中继投递 |
| `scripts/test-remote-notify.py` | 22 | 企微 markdown / 飞书 text 报文、转义、平台报错退出码、`http://` 明文被拒 |
| `scripts/test-remote.py` / `test-relay.py` / `test-relay-do.mjs` | 20 / 7 / 21 | 网关白名单与只读、中继契约、DO 队列语义 |

所以要你验的是**自动化覆盖不到的那一层**：凭据真不真、回调地址通不通、白名单里的
ID 对不对、你 CF 账号上的真实部署、以及手机上真实的观感。按下面顺序做，每步都有
「期望」和「不对时先看哪里」。

### 9.0 先备齐三样（缺一样后面都走不通）

- [ ] **凭据**：企微 = CorpID + 应用 AgentId + 应用 Secret + 回调 Token + EncodingAESKey（43 位）；
      飞书 = App ID + App Secret +（加密时）Encrypt Key + Verification Token
- [ ] **公网可达的回调地址**：任何能给你一个公网 `https://` 地址的穿透/反代都行
      （本机默认只听 `127.0.0.1:8099`，这是故意的：回调正文是明文消息）
- [ ] **你自己的平台 ID**：企微填 UserID（不是昵称），飞书填 `open_id`（`ou_` 开头）

### 9.1 回调接入（企微）

- [ ] `perl remote/platform.pl --init` 录入凭据 → `perl remote/platform.pl --check`
      期望：`配置齐全：platform=wecom port=8099`
- [ ] `perl remote/platform.pl --serve`
      期望：`监听 127.0.0.1:8099（platform=wecom）` + 那句「默认只监听本机」的提醒
- [ ] `~/.claude-agent/remote.conf` 里写 `ALLOW = <你的 UserID>`（白名单只有这一处）
- [ ] 穿透把 `https://<你的地址>/wecom` 转到 `127.0.0.1:8099`
- [ ] 企微后台「应用 → 接收消息 → API 接收」填 URL / Token / EncodingAESKey，点保存
      期望：**保存能通过**（平台会打 GET + echostr，服务端解密后原样回明文）
      不对时：`~/.claude-agent/audit.log` 里会是 `wecom_verify_fail`（签名或 Token 不对）
      或 `wecom_receiveid_fail`（EncodingAESKey 抄错 / 不是这个企业的）
- [ ] 手机上给这个应用发一条「列一下当前目录」
      期望：3 秒内先收到「收到，正在处理…（完成后把结果发给你）」，随后收到真正的结果
- [ ] 预期之外的：`--serve` 前台窗口里应能看到请求进来；关掉窗口后手机再发就不通了
      （没有做开机自启/守护，这是现状，不是 bug）

### 9.2 回调接入（飞书）

- [ ] `--init` 选飞书 → `--check` 显示 `platform=feishu`
- [ ] `--serve` 后，飞书开放平台「事件订阅」填 `https://<你的地址>/feishu`
      期望：challenge 校验通过（明文与加密两种都要能过；填了 Encrypt Key 就走加密）
- [ ] 把应用权限加上「接收消息」与「以应用身份发消息」，然后手机上私聊这个应用
      期望：和企微一样，先「处理中」再结果
- [ ] 白名单里填你的 `open_id`（不是手机号/邮箱）

### 9.3 边界与安全（这几条最容易被忽略，但正是远程的风险面）

- [ ] **白名单外的人**：换一个不在 `ALLOW` 里的账号发消息
      期望：手机上**没有任何回复**（不回「无权限」，避免暴露机器人存在），
      `audit.log` 里出现 `drop_sender from=<那个人>`
- [ ] **远程不能写、不能执行**：让它「在 /tmp 建个文件」「跑一下 rm -rf 测试目录」
      期望：被拒绝（远程工具只有 `read_file` / `list_dir`），并且 `/tmp` 下没有新文件
- [ ] **重投不会跑两遍**：手机发一条后立刻断网再恢复（平台会重投）
      期望：agent 只跑一次；`audit.log` 里有 `duplicate_drop`
- [ ] **超长回答**：让它输出 3000 字以上
      期望：拆成多条发到手机，每条开头有「（1/3）」这样的编号，内容不丢字
- [ ] **凭据不落地到日志**：`grep -c "你的 Secret\|你的 AESKey" ~/.claude-agent/audit.log`
      期望：0（`audit.log` 只有事件名与长度）
- [ ] **凭据文件权限**：`ls -l ~/.claude-agent/platform.conf`
      期望：`-rw-------`（0600）

### 9.4 中继模式（家里 Mac 在 NAT 后面，不在本机验）

先把**真的 CF Worker 部署一次**（这是自动化完全没碰过的一段）：

- [ ] `cd remote/relay && npx wrangler login`（用你自己的 Cloudflare 账号）
- [ ] `npx wrangler deploy`
      期望：输出里有 `https://advisor-relay.<你的子域>.workers.dev`
      （Durable Object 不用手建、不用填 id：`wrangler.toml` 里只有绑定名）
- [ ] `npx wrangler secret put RELAY_TOKEN`（随便一串长随机）
- [ ] `curl https://<你的 workers.dev>/health`
      期望：`{"ok":true,...,"backend":"durable-object"}`
- [ ] `curl -X POST https://<你的>/push -H "authorization: Bearer <刚才的 RELAY_TOKEN>" ...`
      不带这个头时**必须是 401**（说明鉴权没被绕过）

再接起来（平台端在公网机器 / Mac 端在家里）：

- [ ] 平台端 `platform.conf` 加 `RELAY_URL = https://<你的>/ push 前缀` + `RELAY_TOKEN = <同一串>` + `RELAY_POLL = 3`
- [ ] `platform.pl --check` 提示「中继模式」，`--serve` 后**不再本地起网关**
- [ ] 家里 Mac：`perl remote/gateway.pl --poll`（白名单、审计、只读仍在这一侧）
- [ ] 手机发一条
      期望：平台端不出现 `gateway.pl --stdin`；Mac 侧 `--poll` 取到并处理后，手机收到结果

本机可以先不花钱预演一遍（`npx wrangler dev --local` + `node scripts/test-relay-do.mjs`），
但那**证明不了**你账号上的部署与 secret 配置对不对。

### 9.5 出站通知（档①，1 分钟，随时可验）

- [ ] `~/.claude-agent/remote.conf` 写 `WECOM_WEBHOOK = https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...`
- [ ] `perl remote/notify.pl --test`
      期望：`通知已发送：WECOM_WEBHOOK`，群里收到「advisor 通知连通性测试 —— 收到即成功。」
- [ ] 长任务收尾：`echo "构建完成" | perl remote/notify.pl -`
      期望：群里收到 markdown 消息，中文与换行正常

### 9.6 不对时先看哪里（按症状查，别乱改配置）

| 症状 | 先看 | 常见原因 |
|---|---|---|
| 平台后台保存回调 URL 失败 | `audit.log` 的 `wecom_verify_fail` | Token 不一致 |
| 同上 | `audit.log` 的 `wecom_receiveid_fail` | EncodingAESKey 抄错/不是这个企业的 |
| 手机发了没反应、日志里没有 `inbound` | 穿透/反代 | 回调没真正打到本机 8099 |
| 日志有 `inbound` 但没有 `gateway_done` | 本机 agent | 本机 key 失效或模型不通（先本地跑一次 `advisor`） |
| 有 `gateway_done` 但手机没收到 | `audit.log` 的 `wecom_send_fail` / `feishu_send_fail` | 发送权限没开（飞书要「以应用身份发消息」）、`--to` 的 ID 不是 UserID/open_id |
| 中继 `/push` 一直 401 | Worker 的 `RELAY_TOKEN` | 两端的 token 不一致 |
| 手机收到的字是 `\u4f60\u597d` 这样的转义 | 中继侧 | 中继返回的 JSON 必须是 UTF-8 原文，不能 `\u` 转义 |

### 9.7 这一轮新增的两处加固（顺手记一下，不必单独验）

- `platform.pl` 的测试从 42 项加到 46 项：补了「ReceiveId 不是本企业 → 400」
  「非文本消息不派活」「飞书时间戳过期 → 403」「中继投递的 Authorization 头必须是
  `Bearer <token>`（不是占位）」。
- 新增 `scripts/test-remote-notify.py`（22 项）——`notify.pl` 之前只有语法检查。

## 10. 双击 Advisor.app 打不开

Finder 双击启动时 stderr 没有地方显示，失败表现为「弹一下就没了」或完全没反应。
按这个顺序查：

```bash
# ① 直接跑包内可执行文件——Finder 里看不到的报错会全部打出来
~/Applications/Advisor.app/Contents/MacOS/Advisor

# ② 逐条体检（包结构 / python3 与 Tk / Gatekeeper / 真跑一次 / 崩溃日志）
bash scripts/doctor-macos.sh
```

先看这两条**这一轮刚修过**的行为，确认真的生效（别只看「能打开了」）：

| 检查 | 应该看到 |
|---|---|
| 解释器/源码不可用时 | stderr **先**打出 `Advisor: …`、`解释器: …`、`程序: …` 三行，之后才可能出现弹窗 |
| 弹窗行为 | 弹窗最多停留 **10 秒**自动消失（`giving up after 10`），不需要你点「好」 |
| 为什么重要 | 没有 `giving up after` 时，弹窗会一直等人点 —— 在远程登录/无人值守的机器上就是永久挂住（CI 上实测吃掉 45 分钟） |

验法（把解释器路径故意指错，模拟「装完 python3 又被卸载」）：

```bash
# 直接跑包内可执行文件即可，不需要真的卸载 python3
~/Applications/Advisor.app/Contents/MacOS/Advisor
```

常见三种原因：

| 现象 | 原因 | 处理 |
|---|---|---|
| `exec: /usr/bin/python3: No such file or directory` | macOS 12.3 起 `/usr/bin/python3` 只在装了 Xcode CLT 后才有；旧版 setup.sh 把它当兜底 | 现已修：查找时逐个 `-x` 验证。装 python.org 的 Python 3 后重跑 setup.sh |
| 图标跳一下就消失 | python3 缺 Tk（Homebrew 版常见） | 装 python.org 的 Python 3（自带 Tk）；`setup.sh` 现在会直接告诉你缺 Tk 并跳过生成 |
| 弹「无法验证开发者」 | 未签名 + 隔离属性 | 系统设置 → 隐私与安全性 → 「仍要打开」；或 `xattr -dr com.apple.quarantine ~/Applications/Advisor.app` |

装 Python 3 的两条路（GUI 需要 Tk，只装 Xcode CLT 不够）：

```bash
open https://www.python.org/downloads/macos/     # 推荐：安装包自带 Tk
python3 -c "import tkinter; print('tkinter ok')" # 装完自验，必须打印 tkinter ok
brew install python python-tk                    # 或者用 Homebrew（两件都要装）
```

注意：本地 setup 用的是 `py2app -A`（alias 模式），产物依赖本机 python3 与
`~/claude-build/` 源码目录，**不能拷到别的 Mac**；发布 zip 用的是独立构建，不受影响。

---

## 11. 交互模式（default / accept-edits / bypass）验收

三档只改「要不要问」，不改「能做什么」。危险命令在三档里**都会问**。

```bash
advisor                      # 默认 default：写文件/跑命令每次都问
advisor --mode=accept-edits  # 写文件（可写范围内）不问，命令仍问
advisor --mode=bypass        # 普通写/跑不问，危险命令仍问
/mode                        # 会话内看当前模式；/mode bypass 需再输一次 yes
/allow-write ~/work/notes    # 追加可写目录（可多个）；/allow-write 看列表
/approvals                   # 最近 10 条自动批准记录
```

逐条勾：

- [ ] `advisor --mode=xxx`（乱写）应**退出码 2** 并打印「模式名不正确」，**不是**退回 default 继续跑
- [ ] default 下写文件 / 跑命令仍然每次都问（这条最重要：不能为了新功能把旧行为改掉）
- [ ] accept-edits 下在工作目录里写文件不问，但跑命令**仍然问**
- [ ] bypass 下普通写/普通命令不问，且消息里出现一行「· 已自动批准：…」
- [ ] bypass 下递归删除类的危险命令（**别真按 y**）仍然弹出确认，且确认框里有「★ 这是危险操作」；
      带 `sudo` 的命令同理
- [ ] 危险确认**放着不管 60 秒**，应自动拒绝并说明「确认无人应答」，**会话不卡死**
- [ ] 把命令用管道喂进去（没有终端）时，危险命令直接拒绝，不等人
- [ ] bypass 下写 `~/.claude-agent/任意文件` 被拒，理由写「该位置永远不允许写入」
- [ ] bypass 下写工作目录外的文件被拒，并提示 `/allow-write <dir>`；加上之后能写
- [ ] bypass 下用**命令**写到范围外（`echo hi > /tmp/xxx`）也会弹确认；写 `/etc/...` **直接拒绝**
- [ ] 不涉及写入的命令（`echo hi`、`ls`）在 bypass 下照旧不问，别被写目标识别误伤
- [ ] 一条 `sleep 200` 的命令在 120 秒后被中断，结果里说明是超时（不是无声消失）
- [ ] `/allow-write` 显示的「临时目录」就是 macOS 的 `$TMPDIR`（`/var/folders/.../T`），写 `/tmp` 不算默认可写
- [ ] 输出很大的命令只回前 64 KB，并注明原大小
- [ ] `~/.claude-agent/approvals.log` 里能看到刚才的自动批准，权限 `-rw-------`，不含 API key
- [ ] GUI：页眉有「模式 ▾」，切换后旁边徽标跟着变（默认=灰、写免确认=强调色、Bypass=**红色**）
- [ ] GUI：在 Bypass 下写文件不弹窗，但对话里有一行「已自动批准」
- [ ] GUI：从菜单选 Bypass 会先弹一次确认；取消后徽标仍是原来的模式
- [ ] 换主题（笔记 / 编程 / 黑客）后，Bypass 徽标**仍然是红色**（不会退回灰色）
- [ ] 退出再启动，模式沿用上次的选择（`~/.claude-agent-env` 里的 `CLAUDE_MODE`）
- [ ] 远程（企微/飞书）**永远**没有写文件和执行命令的能力，且不接受任何模式参数
