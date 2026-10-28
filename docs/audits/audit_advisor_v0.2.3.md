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
| `test-mirror-drift.sh` 配套 `test-mirror-drift.py` | 19 | 镜像漂移与反拉保护 |
| `test-hooks.py` | 10 | pre-commit hook |
| `test-gui-keyenv.py` | **8** | 新增：GUI 存密钥的权限路径 |
| `test-gui-recursion.py` | 8 | GUI 自递归静态卡口 |
| `test-relay.py` | 7 | 档② 轮询端 |
| **合计** | **363** | 15 个脚本 |

卡口 6 个：`check-secrets`（70 个已跟踪文件 + 全历史，0 命中）、`check-i18n`（Perl `%S` **147** /
GUI `_S` **68** / `msg()` **48**，未译 0）、`check-models`（12 条模型 × 7 家）、`check-version`、
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

## 7. 盲区（Linux 开发机验不到，别当成已验）

- **真机 GUI 观感**：字体/间距/焦点手感、macOS 上 `focus_set` 的实际效果
- **真 API key 连通性**：七家里只有 DeepSeek 的模型名有服务端实证，其余仍是文档值
- **真企微 / 飞书回调**（需公网可达域名 + 真实 UserID / open_id 白名单）
- **macOS 打包与签名**：`release.yml` 的 py2app 一段只能在 macOS runner / 真机跑
- **macOS 命名管道与 IME 行为**：输入法对 `<<Modified>>` 的影响只能人工试

真机清单见 `../manual_test_mac.md`（§8.4 密钥策略、§8.5 远程边界、§9 远程接入）。
