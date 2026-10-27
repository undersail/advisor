# Advisor 第二轮审计（v0.2.1 之后，未发版）

> 上一份是 `docs/audits/audit_advisor_v0.2.1.md`（tag `v0.2.1` 时的快照）。这一份记录**之后**发现并修掉的问题，
> 以及当前的真实状态。版本号仍由维护者决定，本文不预设下一个版本号。

日期：2026-10-27 · 起点提交 `15f5253` · 审计对象：整个仓库（代码 / 脚本 / CI / 文档 / 镜像 / hooks）

## 1. 审计方法与覆盖范围

这一轮不靠读代码"看着没问题"，全部用可执行的方式验：

| 手段 | 具体做法 |
|---|---|
| 本地预演 CI | `python3 scripts/ci-local.py` —— 读 `ci.yml` 把每个 `run:` 原文真跑一遍（**不手抄逻辑**） |
| 全部卡口 | 6 个 `check-*.py` 逐个跑，看退出码与真实输出 |
| 全部测试 | 10 个测试脚本逐个跑，记录实际通过项数（不引用文档里的旧数字） |
| 双向验证 | 新加的每个卡口都做反向探针：故意植入被禁止的写法，确认它真的红 |
| 真环境对打 | Gitee 真实镜像、真实 git hook、`wrangler dev` 真 workerd、真 PTY |
| 文档对账 | 文档里每个数字（步数/条数/测试项/厂商数）都与实际执行输出比对 |
| 覆盖矩阵 | 把「仓库里有哪些脚本」与「CI 里引用了哪些脚本」做差集，找从未被检查的文件 |

**盲区（明确说明，别当成已验）**：真机 GUI 视觉与交互、真 API key 连通性、真实企微/飞书回调
（需公网可达域名 + 真实 UserID）、macOS 打包与签名、Windows。这些只能在真机上验，见
`docs/manual_test_mac.md`。

## 2. 本轮修掉的问题（按发现顺序）

### 2.1 GUI 启动即崩（macOS 独占，我写的 bug）

```python
return _pointing_cursor() if sys.platform == "darwin" else "hand2"
```

`_pointing_cursor()` 无条件调用自己 → macOS 上 `RecursionError`，双击图标立刻退出（连窗口都不出现）；
Linux 永远走 `else`，本机所有测试全绿。维护者直接在 Gitee 网页上提交了修复（`dc424a0`），
本仓 cherry-pick 回来（`14f1889`，保留原作者信息）。

**防线**：`scripts/test-gui-recursion.py`（8 项）—— AST 扫「函数体里必有分支调用自己且没有可提前返回的
出口」，双向验证过：把原 bug 植回去会红。

### 2.2 Gitee 镜像会无声覆盖对方的提交

`sync-gitee.yml` 用 `git push --all --force` + `--tags --force` 单向强推。任何人在 Gitee 侧
直接提交或打 tag，下一次同步会**无声覆盖**，不可恢复。这不是理论风险 —— 上一条的修复提交就是在
Gitee 侧做的，保护上线第一次跑就把它拦下了（同步中止，没有推）。

**防线**：`scripts/check-mirror-drift.sh` + `sync-gitee.yml` 前置步骤：

| 情况 | 行为 |
|---|---|
| 镜像同名分支有未进入本地的提交 | 中止同步，打印反拉步骤 |
| 镜像同名 tag 指向本地历史之外 | 中止同步 |
| 已 cherry-pick（补丁等价，按 patch-id 判） | 放行（否则按自己建议的方式修完，同步反而永久卡住） |
| 镜像独有的分支 / 不同名 tag / 镜像滞后 | 只提示或放行（`--all` 不删除它们，谈不上丢失） |
| 读不到镜像 | 中止，不盲目强推 |

逃生门：`workflow_dispatch` 勾 `force`。测试 `scripts/test-mirror-drift.py` 19 项（本地裸仓模拟）。

### 2.3 bash 3.2 把全角字符算进变量名（macOS 独占）

```bash
note "镜像上还有本地没有的分支：$mb（不会被删除）"     # 期望 master（不会被删除
# 实际输出：镜像上还有本地没有的分支：��不会被删除      ← 分支名凭空消失
```

bash 3.2（macOS 自带）+ UTF-8 locale 下，`（` 的首字节被当成标识符的一部分 → `$mb（` 被解析成
未定义变量 → 展开为空，还留下半个多字节乱码。bash 5 不这样，所以本地永远复现不了。
全仓扫出 6 处同类（含 `doctor-macos.sh` 三条体检提示、`setup.sh` 生成的脚本）。

### 2.4 `case … continue ;;` 在 bash 3.2 上语法错误（pre-commit hook 整块失效）

```bash
case "$f" in *.png|*.icns) continue ;; esac    # bash 3.2: syntax error near `;;'
```

放进 pre-commit hook 的后果是**hook 从没执行过**，而这正是最不容易被发现的失效形态。
`setup.sh` 的 providers 解析循环里有一处同构写法，一并改成 `if/else`。

**防线**：`scripts/check-shell-var-glue.py`（两条规则：变量粘连非 ASCII、case 里直接 continue/break），
覆盖 `*.sh` / `setup.sh` / `scripts/hooks/*`，每条规则都做过反向探针；`setup.sh` 那处就是被它翻出来的。

### 2.5 `.app` 启动器的弹窗在无人值守环境永久挂住

`.app` 在解释器/源码不可用时会 `osascript -e 'display dialog …'`。没有 `giving up after`，
它会一直等人点「好」——在 CI、远程登录这类没人操作的机器上就是永久挂住（实测吃掉 45 分钟
job 预算后整个 run 被 cancelled）。Linux 没有 osascript，本地永远看不出来。

修法（产品行为，不只是测试）：
- `giving up after 10`，最多等 10 秒自动消失；
- 文字提示（解释器路径、程序路径）**挪到弹窗之前**写 stderr —— 弹窗没人点时也能立刻看到原因。

### 2.6 测试自身的两个平台问题

- `subprocess.run(..., text=True)` 在 macOS runner 的 locale 下把 git 输出当非 UTF-8 →
  `UnicodeDecodeError`，整条测试崩成 "exit code 1"，注解里一条断言都看不到。统一
  `encoding='utf-8', errors='replace'`。
- 测试子进程不给 stdin：CI 的 stdin 是不关闭的管道，被测脚本里的 `read` 会永久阻塞。
  统一 `stdin=DEVNULL` + `timeout`，把「挂 45 分钟什么都看不到」变成「2 分钟报出是哪条命令」。

### 2.7 测试自身的进程泄漏（12 小时没人发现）

`scripts/test-platform.py` 每跑一轮，`remote/platform.pl --serve` 与它 fork 出来的
`gateway.pl --stdin` 都会**留在后台**：`stop()` 只 `terminate()` 了父进程，网关子进程成了孤儿。

实测本机累积了 **37 对（74 个进程）**，最长的一个已经跑了 11 小时 58 分 —— 它们还占着端口、
继续往 `~/.claude-agent/audit.log` 里写、并吃内存。CI 上因为 job 结束会连带杀掉所以看不出来，
正好是"只在开发机上慢慢腐烂"的那类问题。

修法：`Popen(..., start_new_session=True)` + `stop()` 里 `os.killpg()` 整组收（TERM → 等 8 秒 →
KILL，最后再补一次 KILL，因为父进程退了子进程可能还在）。`test-relay.py` 用的是
`--max-msgs 2` 自退出 + `communicate(timeout=90)`，本来就是有界的，不需要改。

审计方法上的教训：**跑完测试要看一眼 `ps`**。断言全绿不代表没留下东西 —— 这类泄漏永远不会
让测试变红。

## 3. 本轮补上的覆盖缺口

做「仓库脚本 vs CI 引用」差集时发现的真实缺口（不是顺手加的）：

| 缺口 | 之前的状态 | 现在 |
|---|---|---|
| `scripts/*.sh` 语法 | 从未检查（`bash -n` 只查了 setup.sh / completion / release 脚本） | 全仓 shell 一起查，含 `scripts/hooks/pre-commit` |
| `remote/platform.pl` 语法 | 平台端只被运行时测试间接覆盖 | 进 `perl -c` 清单，语法错误立刻红 |
| `scripts/*.py` 编译 | 只有 `gui/advisor_gui.py` 被 `py_compile` | 全量 `py_compile scripts/*.py`（`live-check.py` 平时没有任何机会暴露语法错误） |
| `scripts/audit-commands.py` | 只在本地手工跑过，等于没有防线 | 进 CI（24 项：12 条命令 × 路由/真切换） |

CI 因此从 21 步增到 **25 步 × 2 平台**。注意 `audit-commands.py` 走 PTY、逐条启真 agent，
一轮约 7 分钟 —— macOS 腿 45 分钟的预算够用，但 `ci-local.py` 整体会到 10 分钟上下，别当它吊死。

## 4. 当前真实状态（全部来自本轮实际执行）

**质量门**

```
perl -c agent/claude-agent.pl        syntax OK
perl -c remote/{gateway,notify,platform}.pl   OK
--version                            advisor (high_sierra_claude) 0.2.1
卡口  check-secrets / check-i18n / check-models / check-version
      check-decoupling / check-shell-var-glue        全部通过
泄漏  59 个已跟踪文件，0 命中（含未跟踪文件与 --history）
```

**测试项数（逐个跑出来的，不是文档抄的）**

| 脚本 | 结果 |
|---|---|
| `test-platform.py` | 42/42 |
| `test-release-workflow.py` | 26/26 |
| `audit-commands.py` | 24/24 |
| `test-setup-py3.py` | 22/22 |
| `test-relay-do.mjs` | 21/21 |
| `test-remote.py` | 20/20 |
| `test-mirror-drift.py` | 19/19 |
| `test-hooks.py` | 10/10 |
| `test-gui-recursion.py` | 8/8 |
| `test-relay.py` | 7/7 |
| **合计** | **199 项** |

**文案与注册表**：Perl `%S` 102 条 / GUI `_S` 57 条 / `setup.sh` `msg()` 44 条；未译 0 条；
厂商 7 家；`models.txt` 12 条。这些数字由 `scripts/check-version.py` 守着，文档不再手写死数。

**CI 与镜像**
- `ci.yml`：25 步 × 2 平台（ubuntu + macOS），`timeout-minutes` 按平台拆分（macOS 45 / ubuntu 15）
- `sync-gitee.yml`：反拉保护 + `force` 逃生门，最近多次 success
- `release.yml`：tag → macOS py2app → `gh release create`（产物校验不用 `grep -q`，避免 SIGPIPE 假阴性）

**hooks**：`core.hooksPath = scripts/hooks`（hook 本身受版本控制），提交前跑泄漏 + 换行 + 调试残留。

## 5. 仍未做 / 仍未验（不要当成已完成）

| 项 | 状态 |
|---|---|
| Tier A（10.6–10.8） | **未实现**，维护者已决定暂不做，只留 `CLAUDE_CURL` / `CLAUDE_CACERT` 接口 |
| 签名分发 | 未签名（Apple Developer ID 需付费账号），维护者已决定保持右键打开 |
| 群聊 / 非文本消息 | 按计划不做（记 `wecom_skip`） |
| 档③ 双向实时逐字流式 | 暂缓（依赖隧道，10~15 人日） |
| 真 key 连通性 | 只能在真机用 `scripts/live-check.py` 验（只输出 PASS/FAIL） |
| 真企微/飞书回调 | 需公网可达域名 + 真实 UserID / open_id 白名单 |
| GUI 视觉排版 | 需真机图形会话 |
| macOS 打包产物 | 需 macOS（Linux 无 py2app / xcode-select） |

## 6. 这一轮的方法论收获

1. **Linux 绿 macOS 红，一律先当成真 bug**。这一轮 4 个都是真 bug，没有一个是"测试写错了"。
   其中最贵的是 hook：静默失效、永远不会有人报障。
2. **不让平台差异靠猜**。拿不到 CI 日志时，把诊断打成 `::error::` / `::notice::` 注解（注解接口
   免鉴权可读），一次推送就能看到被测脚本的真实输出 —— 「变量被吞成乱码」只有这样才第一次看见。
3. **卡口要双向验**：新写的每条规则都植一次"坏样本"确认它真会红，否则就是给自己发安慰奖。
4. **覆盖矩阵比逐个 review 有效**：脚本清单减 CI 引用清单，一眼看到 4 个从未被检查的文件。
5. **测试的超时是防御**：没有 `timeout` 时，吊死会吃掉整个 job 预算，最后只剩一个 `cancelled`。
