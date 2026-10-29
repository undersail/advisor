# 审计记录 · v0.2.3（发版前全面审计）

日期：2026-10-28 · 范围：`v0.2.2..HEAD`（18 个提交，28 个文件，+4107 / −183）
审计对象：交互模式三档、`/key` 密钥策略、远程只对话、真机两处报障修复

## 一句话结论

**本地全量预演 58/58 步通过、15 个测试脚本 363 项全过、6 个卡口全过、两条 `--pristine` 与常规预演一致。**
本轮新加的每一条卡口都做了反向探针（植入违规 → 必须变红 → 还原 → 再绿，15/15）。
仍未验的只有真机观感与真凭据（见文末盲区）。

## 1. 全量预演（`scripts/ci-local.py`，真执行 `ci.yml` 的 `run:` 原文）

| 预演 | 结果 |
|---|---|
| `python3 scripts/ci-local.py` | **58 步执行 / 2 步按条件跳过 / 全部通过** |
| `python3 scripts/ci-local.py --pristine` | 同上（`env -i` + 最小 PATH + 临时 HOME，不继承 `TMPDIR`/`CLAUDE_*`） |

第一次跑是 **57/58**，唯一的红是「泄漏检查」抓到 `scripts/audit-probes.py` 里写死了
写死了本机的项目绝对路径（形如 `<家目录>/…/advisor`）。**这是卡口按设计工作**，已改成按文件位置推导
（`os.path.dirname(os.path.dirname(os.path.abspath(__file__)))`），复跑通过。

## 2. 测试与卡口（数字以实际输出为准）

| 脚本 | 项数 | 备注 |
|---|---|---|
| `test-modes.py` | 60 | 三档交互模式端到端（`--rpc`） |
| `test-platform.py` | 46 | 平台端签收（自造凭据） |
| `test-setup-py3.py` | **35** | 新增 6 项：模型名按厂商校验 / 写回配置 / heredoc 反引号 |
| `test-release-workflow.py` | 26 | 发布流水线非 macOS 部分 |
| `audit-commands.py` | 27 | 12 条命令 × 路由与真切换两相 |
| `test-key-policy.py` | **25** | 新增：`/key` 全流程 + 受限会话拒绝配置 |
| `test-gui-modes.py` | **25** | 新增：焦点调度、后端退出提示 |
| `test-remote.py` | **24** | 新增：`no_config=1` 审计、聊天端改配置被拒 |
| `test-remote-notify.py` | 22 | 档① 通知 |
| `test-relay-do.mjs` | 21 | Durable Object 队列语义 |
| `test-mirror-drift.py` | **20** | 镜像漂移与反拉保护（新增「推 tag 也要同步」） |
| `test-hooks.py` | 10 | pre-commit hook |
| `test-gui-keyenv.py` | **8** | 新增：GUI 存密钥的权限路径 |
| `test-gui-recursion.py` | 8 | GUI 自递归静态卡口 |
| `test-relay.py` | 7 | 档② 轮询端 |
| **合计** | **364** | 15 个脚本（发版前逐条实测，不是抄文档） |

卡口 6 个：`check-secrets`（70 个已跟踪文件 + 全历史，0 命中）、`check-i18n`（Perl `%S` **147** /
GUI `_S` **68** / `msg()` **52**，未译 0）、`check-models`（12 条模型 × 7 家）、`check-version`、
`check-decoupling`、`check-shell-var-glue`。

## 3. 反向探针（本轮新卡口全部验过"会红"）

`python3 scripts/audit-probes.py` → **15/15**（每条都是「植入前绿 → 植入后红 → 还原后绿」）：

| 卡口 | 植入的违规 | 结果 |
|---|---|---|
| 解耦：网关必须传 `--no-config` | 去掉 `'--no-config'` | 变红 ✓ |
| setup：无引号 heredoc 不许有反引号 | 把注释里的 `“giving up after”` 改回反引号 | 变红 ✓ |
| 密钥策略：受限会话拒绝配置 | `if ($NO_CONFIG)` → `if (0)` | 变红 ✓ |
| GUI：存密钥必须原子替换 | 改回 `open(path,'w')` | 变红 ✓ |
| GUI：忙完把焦点交回写作框 | 删掉 `_focus_write_zone()` 调用 | 变红 ✓ |

该脚本**故意不进 CI**（会临时改源码再还原，污染工作区），理由写在文件头。

## 4. 覆盖矩阵（`scripts/` 减 `ci.yml` 引用）

未被 `ci.yml` 直接引用的 4 个文件，每个都有理由：

| 文件 | 理由 |
|---|---|
| `ci-local.py` | 本地预演执行器本身 |
| `doctor-macos.sh` | 只能在用户 Mac 上跑（诊断双击打不开）；CI 里由「全仓 `bash -n`」覆盖语法 |
| `install-git-hooks.sh` | 开发机一次性安装；同样只被 `bash -n` 覆盖 |
| `live-check.py` | 需要真 key（计费），由「全量 `py_compile`」覆盖语法 |
| `audit-probes.py` | 人工审计用（改源码），见上 |

## 4.5 CI 耗时剖析与提速（实测，不是猜）

从 Actions API 取每步耗时（`c01615a` / `9e10bb4` 两次成功 run）：

| | ubuntu 腿 | macOS 腿 |
|---|---|---|
| job 总时长 | 5.5 分 | 9.0 分 |
| 最慢一步「命令可达性审计」 | **242s（占 73%）** | **252s** |
| 次慢「密钥策略」 | 49s | 86s |
| 「平台端到端」 | 15s | 53s |

两个最慢的步骤都不是在算东西，而是**盲等**：`pump(6)` 等启动、每条输入 `pump(3)` 等回显，
27 个用例（另一处 25 个用例）把固定秒数累加成了 4 分钟。改成**事件驱动**——
收到输出后连续 quiet 秒无新数据就返回，没有任何输出时仍等满上限（不会漏判）：

| 步骤 | 改前 | 改后（本机实测） |
|---|---|---|
| `audit-commands.py` | 242s | **57s** |
| `test-key-policy.py` | 49s（macOS 86s） | **18s** |

按此推算 ubuntu 腿 5.5 → 约 2.2 分、macOS 腿 9.0 → 约 5 分。

**再加上结构性的那一刀：拆成 3 个 job 并行**（用户拍板）。原来 30 步串在一个 job 里，
墙钟 = 所有步骤之和；现在按耗时分成三组，覆盖范围完全不变（步骤一个没丢，脚本里断言
"没分到 job 就退出"）：

| job | 内容 | 本机耗时量级 |
|---|---|---|
| `gates` | 语法 / 模型表 / 三语 / 解耦 / 版本 / 泄漏 / 换行等 15 步静态卡口 | 约 20s |
| `core` | 命令可达性审计、密钥策略、平台端到端、DO 队列、hook | 最慢组（审计领跑） |
| `io` | 交互模式、出站通知、中继、远程、GUI 两测、setup、镜像 | 次慢组 |

拆完本地预演（含 `--pristine`）：**62 步执行 / 6 步按平台跳过 / 0 失败**。

### 根因（GitHub 自己给的注解，不是猜）

三次 macOS 腿都是 `steps=0`、恰好 15.0 分被取消。查 check-run 的 annotations 拿到原文：

```
[failure] The job was not acquired by Runner of type hosted even after multiple attempts
[notice]  Due to capacity constraints, jobs targeting macOS arm64 runners may experience
          longer queue times.
```

即：**`macos-latest` 现在指向 macOS 26 arm64，而 arm64 池容量紧张** —— 我们的 job 一直没被
分配机器，GitHub 多次重试后放弃并按「取消」记账。期间我们做过两次排除：把超时从表达式改成
字面量 300（结果仍是 15 分整被取消，说明与我们的配置无关）、以及确认仓库是 public（不限分钟数）。

处置：CI 与发布两条 macOS 腿都改用 **Intel 池的具体标签 `macos-15-intel`**（不再用会漂移的
`macos-latest`），顺带减少一层架构偏差 —— 真实目标机 High Sierra 也是 Intel。
同时确认了一个反直觉的事实：**排队时间算在 `timeout-minutes` 里**（15 分钟那档连排队一起掐），
所以超时一律写字面量并给足。

**但真正让 CI 显得很慢的还有 macOS runner 排队**：实测 `9e10bb4` 那次总 19.1 分里，
我们自己的步骤只占 9 分，其余是排队 + 镜像准备（GitHub 侧，我们控制不了）。
所以「减步骤」和「拆 job」的收益有上限，剩下的只能等 GitHub 的 macOS 机器。

## 5. 进程清理

跑完扫 `ps`：发现一个**跑了 2 天的 `wrangler dev --local --port 8787`**（上上轮中继调试残留），
已按 PID 杀掉（不用 `pkill -f wrangler dev`，那条会自匹配掉自己的 shell）。
本轮测试自己没有留下 `claude-agent.pl` / `platform.pl` / `gateway.pl` 孤儿（在跑的只属于当前 ci-local）。

## 6. 本轮修掉的真问题（按严重程度）

1. **GUI 输入框从来拿不到键盘焦点** —— 整个 GUI 里没有任何一处给写作框 `focus_set()`，
   窗口一开焦点不属于任何控件，按键直接丢弃。真机表现为「GUI 能打开但打不了字」。
   现在启动时 / 后端 `ready` 后 / 每轮忙完 / 窗口重新获得焦点时都会补焦点。
2. **后端退出时 GUI 静默变石头** —— 进程 EOF 后只把输入框 DISABLE、状态栏一句「已退出」，
   而 stderr 被 `subprocess.DEVNULL` 丢掉，用户看不到任何原因（本地复现：环境缺 provider 时
   agent `exit 25` + 「请设置 ANTHROPIC_API_KEY」，GUI 一个字都不显示）。现在 stderr 收最后
   20 行并在对话区打出原因 + 处理办法。
3. **GUI 存密钥因「文件只读」失败，而命令行 setup 却能写** —— GUI 用 `open(path,'w')`（要文件可写），
   setup 用 `mv`（只要目录可写）。已统一为同目录临时文件 + `os.replace`；真写不进时报
   「路径 / 属主 / 权限 / `sudo rm` 再试」。
4. **`setup.sh` 用错模型名却报「密钥不正确」** —— 检查连通性时沿用 `~/.claude-agent-env` 里
   上一家厂商的 `CLAUDE_MODEL`（真机实测：拿 `claude-opus-5` 去请求 DeepSeek → 400）。
   现在模型名必须属于所选厂商，否则回落并告知，同时把 `CLAUDE_MODEL` 写回配置。
5. **`models.txt` 的 DeepSeek 模型名已过期** —— 服务端只认 `deepseek-flash` / `deepseek-v4-pro`。
   已按服务端返回的名单更新，默认模型 = `deepseek-flash`。
6. **远程只对话** —— 原先 `--tools` 只收窄了工具，**命令入口还开着**：聊天端发 `/mode bypass`、
   `/model`、`/key` 都会被真的执行，其中 `/key` 会让密钥经第三方聊天平台转一圈。
   现在核心多一个通用开关 `--no-config`，网关起 agent 时带上，审计记 `no_config=1`。
7. **密钥策略** —— 密钥只在两处输入（安装流程 / 专门命令 `/key`）；切换模型不再夹带密钥输入；
   401/403 单独识别成「密钥被拒绝」并要求退出后重配。
8. **CI 的 macOS 腿被误杀** —— `timeout-minutes: ${{ matrix.os == 'macos-latest' && 45 || 15 }}`
   实测没吃到 45（`df2e917` 的 macOS job `steps=0`、恰 15 分钟被取消）。改成矩阵里直接给数值
   （ubuntu 25 / macOS 90）。

## 6.5 发版后追加（v0.2.3 已发布，改动随下一版走）

用户追问「这个卡口为什么现在才发现需要加」后补的一条真盲区：**CI 的 perl 版本（5.34 / 5.38）
与目标机 High Sierra 自带的 5.26 从来没有人比对过**。原审计方法里只有「`scripts/` 减 `ci.yml`」的
覆盖面差集，没有「运行时版本差集」，所以这个问题是被用户的提问问出来的，不是审出来的。

补了两件（都不改产品行为）：

- `scripts/check-perl-version-compat.py`：扫已跟踪 `.pl/.pm`，拦 5.27+ 的写法（`use v5.28+`、
  `use feature ':5.2x'`、`builtin::`、`try/catch`、中缀 `isa`、`class`/`method`），并带 `--self-test`
  （6 正例 + 5 负例，验它自己会红且不误报 `->isa()` / 注释 / POD）。**今天真扫 0 命中**，属预防性卡口。
- `setup.sh` 在**写任何配置之前**用本机 perl 编译一遍 agent：不通过就打印本机 perl 版本 + 真实报错
  + 一句「装下去只会得到跑不起来的 advisor」，然后中止。这是唯一能覆盖版本*语义*差异的手段。
  自己也踩了一个坑：脚本开着 `set -e`，命令替换失败会立刻退出、连提示都打不出来 →
  `PERL_C_OUT="$(... || true)"`。
- 回归：`scripts/test-setup-perl-check.py`（8 项：坏文件必须中止、且**不得**留下
  `~/.claude-agent-env` 或 `~/bin/advisor`；正常仓库必须放行）；反向探针加第 6 条（18/18）。

## 7. 盲区（Linux 开发机验不到，别当成已验）

- **真机 GUI 观感**：字体/间距/焦点手感、macOS 上 `focus_set` 的实际效果
- **真 API key 连通性**：七家里只有 DeepSeek 的模型名有服务端实证，其余仍是文档值
- **真企微 / 飞书回调**（需公网可达域名 + 真实 UserID / open_id 白名单）
- **macOS 打包与签名**：`release.yml` 的 py2app 一段只能在 macOS runner / 真机跑
- **macOS 命名管道与 IME 行为**：输入法对 `<<Modified>>` 的影响只能人工试

真机清单见 `../manual_test_mac.md`（§8.4 密钥策略、§8.5 远程边界、§9 远程接入）。

### 6.5.1 追加：企微智能机器人长连接（`remote/wecom-ws.pl`）

用户报障（不是审出来的）：他的企微机器人账号给的是「API 模式 · 使用长连接」，凭据只有
**BotID + Secret**。而当时 `remote/` 只有回调模式（要公网 HTTPS + Token + EncodingAESKey）
与 CF 中继（要 CF 账号）。两者都建立在「家里 Mac 有公网可达地址」这个前提前提上。

长连接把方向反过来：本机连出去，于是**不需要公网域名、不需要内网穿透、不需要 CF**，
也没有 AES 与验签。这是一条新的入站形态，落在 `remote/`，核心一行未改。

- `remote/wecom-ws.pl`（748 行）：`--init` / `--check` / `--serve`；握手 → `aibot_subscribe`
  → `aibot_msg_callback` → `aibot_respond_msg`（沿用回调 `req_id`）；30 秒 ping 心跳，
  连续两次无回执判死，退避 1→30 秒重连；订阅被拒（errcode≠0）连三次即停，不无限撞墙
- 判定一律不在这个文件里：白名单 / 审计 / 只读工具集仍由 `gateway.pl --stdin` 决定，
  `check-decoupling.py` 新增断言（读 `{ALLOW}` 或自己起 agent 即红）
- `scripts/test-wecom-ws.py` **35 项**：本机假服务端（明文 ws、127.0.0.1）逐字段验协议、
  白名单外不回、非文本明确回一句、长回复分片不丢字、ping→pong、心跳缺失重连、审计 0600、
  Secret 不出现在输出
- **未能覆盖**：wss/TLS 那一段（`openssl s_client` 管道）只能在真机上验；真连步骤见
  `docs/manual_test_mac.md` §9.8
- 踩过的坑：`use utf8` 缺失导致中文提示二次编码；`ws_send_text` 对已是 JSON 的文本又套了一层引号；
  「每片发完就等回执」会丢掉等待期间到达的新消息（改为 pending 表 + 主循环统一处理）

### 6.5.2 追加：GUI 远程接面板（用户要求：不用开终端）

用户问「GUI 上支持模型 key 配置和远程参数配置吗」—— 核对结果是：**key 支持、远程完全不支持**
（GUI 里一行 `remote` 代码都没有，只有 `sys.platform` 的假命中）。所以补了面板，范围只做企微长连接。

- 菜单 **工具 → 远程接入…**：BotID / Secret（掩码，保存后清空、旧值不回填）/ 白名单 / 保存 / 测试连接
- **写的就是命令行那同一个文件**：`~/.claude-agent/wecom-ws.conf`、`~/.claude-agent/remote.conf` 的
  `ALLOW`；只改自己负责的键，`WS_URL` / `HEARTBEAT` / `NOTIFY` / `LANG` / `HIST_PASS` 原样保留
- 状态只显示文件与 `audit.log` 里的真实内容（未配置 / 已配置 + 最近活动时间），不自己造
- 「测试连接」真跑 `wecom-ws.pl --check`，把真实输出（成功或 `errcode`）打在面板上
- 子线程只算不碰 Tk：用 queue + 主线程 `after` 轮询。**踩过的坑**：从工作线程调 `after()` 在 Tk 里
  不安全，实测静默不执行，界面永远停在「正在检查连接…」
- 新增 `scripts/test-gui-remote.py` **24 项**（需 Xvfb）：文件同一性、掩码、凭据校验、0600、
  只改自己的键、白名单合并、状态读 audit、测试连接失败如实显示
- 顺带把用户「模型 Key 每次启动都要重填」的顾虑锁成断言：`test-gui-keyenv` 8 → **11 项**，
  新增「写完再判定 `has_valid_api_key()` 为真」「写了 `CLAUDE_PROVIDER`」「key 变量名与
  `providers.txt` 一致」

**关于「每次都要重填」的判定条件**（也是排查清单）：`has_valid_api_key()` 只要求
①env 文件里有 `CLAUDE_PROVIDER` ②该厂商在 `providers.txt` 里且 key 变量非空。
不满足就重弹引导页。历史上还有一种情况是写盘静默失败（早期 `open('w')`），
现在走临时文件 + `os.replace`，失败会抛 `key_save_denied` 并打印属主/权限。

### 6.5.3 追加：远程权限改为「启动时定档 + 手机确认」（用户推翻了「远程硬关写入」的旧铁律）

用户原话：「远程模式不是完全不能写，这样很多功能就无法使用了。建议权限管控和本地一样，
在MAC上启动远程服务时选好模式，比如edit，启动后在远程客户端（手机）无法更改模式。
遇到需要确认的操作，由用户在客户端回复确认」。

改了哪些：

- `remote/gateway.pl`：新增 `--mode=` / `--allow-write=` / `--confirm-wait=`；
  `effective_tools()` 一处绑定「档位 → 工具集」；只读档 = `read_file,list_dir`，
  可写档追加 `write_file,run_shell`；参数非法当场 exit 2 并说明可选值；
  只读档给 `--allow-write` 直接报错（矛盾配置不许静默无效）
- 确认转发：`{t:"confirm"}` → 吐一行 `{"from","ask","danger"}` → 读一行 `{"answer"}` →
  回 `{t:"reply","value":"y|n"}`；`--confirm-wait` 默认 120 秒，超时按拒绝并记 `timeout=1`
- `remote/wecom-ws.pl`：`--mode` / `--allow-write` / `--confirm-wait`（命令行 > 配置）；
  把确认问题发到手机（危险操作带 ⚠ 与「回复 y 允许 / n 拒绝」）；用户回的 y/n 转成 answer 行；
  回的是别的话 → 先按拒绝收尾，再把这句话当新指令，不把人卡住
- GUI：远程面板新增「远程权限」下拉与「可写目录」，写 `REMOTE_MODE` / `REMOTE_ALLOW_WRITE`
  到同一份 `wecom-ws.conf`；只读档配可写目录会被拦下
- 卡口 `check-decoupling.py`：旧规则「远程一律只读、remote/ 里不许出现 --mode」整段替换为新规则 ——
  档位只来自启动参数（`$conf->{REMOTE_MODE}` / `CLAUDE_MODE` / `$j->{mode}` 出现即红）、
  `writable_mode()` 只认 `accept-edits` / `bypass`、必须有 `ask_remote()`、回应键必须是 `reply`

**过程中抓到两个真 bug（此前因为远程只读所以没暴露）**：

1. 网关回应确认用的键是 `confirm_answer`，agent 的 `confirm()` 只认 `reply`
   → 等于没人回答，放开写就会一路等到超时（fail-closed 拒掉）
2. 网关 STDOUT 没有自动刷出，`--stdin` 模式下确认问题卡在缓冲区到不了手机
   （`$| = 1` 修好；这也是长连接能正常收回复的前提）

**测试**：新增 `scripts/test-gateway-write.py` **22 项**（假 agent：默认只读 / 工具集 /
参数透传 / 回 y / 回 n / 超时拒绝 / 非法档位 / 审计）；`test-wecom-ws` 35 → **39 项**
（确认发到手机、⚠ 标注、回 y 后跑完）；`test-gui-remote` 24 → **34 项**
（下拉入口、默认只读、矛盾配置拦截、档位与目录落盘、重开面板读回、Secret 不回填）。
CI 35 → **36 步**（io 10 → 11）。

### 6.5.4 追加：单实例保护、优雅退出、GUI 启停与操作手册

用户问「命令行和 GUI 都可以启动远程模式是吧？启动的是同一个服务吧，有避免多启保护和状态同步吧？
启动时如何选择交互模式，如何保活和退出？是不是补充一个操作手册？」—— 核对结果：**同一个服务**，
但**多启动保护、状态同步、优雅退出、GUI 启停都没有**，补上。

- `remote/wecom-ws.pl`：`--serve` 起来时在 `~/.claude-agent/wecom-ws.pid` 上加 `flock` 独占；
  第二个实例立刻 **exit 3** 并告出「已经有一个远程服务在跑（pid=… 档位=…）」；
  pid 文件写 `pid/mode/allow_write/started/version`（**不含密钥**、0600）；
  退出时先 truncate 再 unlink，不留残留
- 信号：`INT` / `TERM` / `HUP` → 审计 `ws_stop`、删 pid、放锁、exit 0（优雅退出）
- `effective_mode()` / `effective_allow()` 抽出为唯一来源（命令行 > 配置文件 > `default`），
  `remote_extra_args()` 复用它，避免「两处各判一次」
- GUI：`remote_service_status()` 只读 pid 文件 + `kill(pid,0)` 判活；
  `start_remote_service()` / `stop_remote_service()`（TERM → 6 秒后 KILL）；
  面板加服务状态行与「启动服务」「停止服务」按钮，按状态互相禁用
- 新文档 `docs/ops_remote.md`（现已并入 `docs/user_manual.md`）：启动 / 三档 / 手机确认 / 多启动保护 / 保活（心跳、退避、SIGPIPE）/
  退出 / 状态与排错 / launchd 开机自启 / 9 步验收清单
- 测试：`test-wecom-ws` 39 → **47 项**（pid 文件内容与权限、第二实例 exit 3、
  SIGTERM 后 pid 清理、审计 `ws_stop`）；`test-gui-remote` 34 → **44 项**
  （状态未运行 → 点启动 → 运行中且档位一致 → 点停止 → 已停 + pid 清理 + `ws_stop`）

### 6.5.5 追加：保活/重连机制对照官方 SDK 复核（用户问「30 秒保活合理吗」）

对照 `WecomTeam/aibot-node-sdk` 的 `src/ws.ts`（官方自己维护的客户端）逐项核对默认值：
`heartbeatInterval=30000ms`、`maxMissedPong=2`、`reconnectBaseDelay=1000ms`、
`reconnectMaxDelay=30000ms`、`maxReconnectAttempts=10`、`maxAuthFailureAttempts=5`，
心跳帧 `{cmd:"ping",headers:{req_id}}`，回执按 `req_id` 前缀判定，**认证成功即清零两侧计数**。

原本就对的部分：30 秒间隔、连续 2 次无回执判死、`ping` 帧格式、退避 1→30 秒上限、
心跳 `errcode≠0` 时不清零 missed、订阅被拒时不无脑重试。

修了的三处（都是偏差，不是风格问题）：

1. **退避永久卡在 30 秒**：原来的 `$attempt` 只在启动时自增、从不清零，跑久了每次断线都等 30 秒；
   现在订阅成功置 `$SUB_OK`，下次断线按第一次算（1 秒）。审计可验：`ws_reconnect delay=1s`
2. **订阅被拒停止阈值 3 → 5**：对齐 `maxAuthFailureAttempts` 默认值；成功订阅后同样清零
3. **缺 `disconnected_event` 处理**：同一机器人在别处建新连接时服务端会推这个事件，官方 SDK
   的处理是「标记不重连、关掉 socket」。我们原来当成普通断线 → 会与另一处客户端来回互踢。
   现在：审计 `ws_kicked`、清理 pid、**退出码 4** 并打印原因，不自动重连

测试：`test-wecom-ws` 47 → **56 项**，新增「被踢 → 退出码 4 且只连一次」「连通过再断线 →
退避回到 1 秒」「凭据错 → 恰好 5 次后停」。退避基数/上限加了
`WECOM_WS_BACKOFF_BASE` / `WECOM_WS_BACKOFF_MAX` 覆盖，测试把它压到毫秒级才能跑得快。
文档：`user_manual` 保活段、`manual_test_mac` §7.5、`design_doc` §4.5.3 同步。

### 6.5.6 wss 证书校验：真机报障碍暴露的两个 bug

真机日志：`连接结束：握手被拒：depth=1 C = US, O = "DigiCert, Inc.", CN = … verify error:num=20:
unable to get local issuer certificate … HTTP/1.1 101 Switching Protocols`，随后每 30 秒重试一次。

两个独立缺陷：

1. **HTTP 头解析**（真 bug，macOS 必现）：`openssl s_client` 即使带 `-quiet` 也会把
   `depth=…/verify return:…` 写到 **stdout**，所以 HTTP 响应不在缓冲区开头；原判据
   `^HTTP/1\.1\s+101` 失配 → 明明已经 101 却报「握手被拒」。改为先切掉 `HTTP/1.` 之前的噪声
   再判 101，同时检查噪声里的 `verify error:num=NN`
2. **stderr 没接管道**（真 bug）：`open3($in,$out,$errh,…)` 的 `$errh` 是 undef（漏了 `gensym`），
   子进程 stderr 直接丢失 → 证书校验失败的真实原因永远读不到，只剩含糊的「握手时连接被关闭」

修法：`s_client` 带 `-CAfile`（证书包按 `SSL_CERT_FILE` → `~/.claude-agent/ca-bundle.pem` 缓存
→ 常见路径 → **macOS 从钥匙串导出**）+ `-verify_return_error`（fail-closed）；
证书类错误标记 `[fatal]` 并 **退出码 5**（不进重试循环），打印三条处理办法与已用证书包；
审计新增 `ws_ca bundle=…`、`ws_fatal`。

新增 `scripts/test-wss-tls.py`（9 项，自签 CA + 本地 TLS WebSocket 服务端）：证书对能握手并订阅、
证书不对立即退出 5 且消息点名「证书校验」并给出三种办法（钥匙串 / `SSL_CERT_FILE` / Homebrew）、
不设 `SSL_CERT_FILE` 时也能自己找到系统证书包。CI 加一步（36 → 37 步，测试脚本 17 → 18、453 →
… 现 471 项）。文档：`user_manual` §8.3 + 排错表退出码 4/5、`manual_test_mac` §7.5 查 `ws_ca`、
`design_doc` §4.5.3。

### 6.5.7 回复体 msgtype 用错：真机 errcode=40008

真机日志：`ws_sent to=Jack part=1/1 len=444` 之后紧跟
`ws_send_err req=… errcode=40008 errmsg=invalid message type` —— 消息发出去了、服务端拒收。

原因：`aibot_respond_msg` 的 `body.msgtype` 只接受 `stream`（`{stream:{id,finish,content}}`）；
`msgtype:text` 只对**欢迎语** `aibot_respond_welcome_msg` 合法。原来回复用 text，
本地假服务端不校验所以测试全绿，真机直接废。

修法：回复改 `msgtype:stream`，`stream.id` 取回调的 `msgid`（同 id 刷新同一气泡），
单条 `finish:true`；「正在处理，请稍等…」用 `finish:false`，最终结果用同一 id 顶掉；
分片时第 1 片沿用该 id、后续 `${id}_n`。

防回归：`test-wecom-ws` 的假服务端现在像真服务端一样校验 `msgtype`/`stream.id`/`finish`/
`content`，不合规就回 40008 —— 客户端会记 `ws_send_err`，CI 即可发现。测试 56 → **59 项**
（新增 stream 类型、非空 id、finish=true、正文在 stream.content 四条断言，去掉一条 text 断言）。
文档：`design_doc` §4.5.1、`user_manual` §8.2 排错表（40008 / 无 ws_inbound / 无 ws_sent 三行）。
