# Advisor 设计文档

> 轻量级 AI 智能体，目标是让抽屉里的旧 Intel Mac（Snow Leopard ~ High Sierra 世代）
> 重新变成一台能用的机器。命令名 `advisor`，刻意取中性名，让用户不必在意背后是
> Claude 还是 Gemini。
>
> 本仓是 [`watermark-hd/advisor`](https://github.com/watermark-hd/advisor) 的 fork，
> 以 `upstream` remote 跟踪上游。上游 MIT 授权，日英双语。

**版本基线**：`advisor (high_sierra_claude) 0.1` · 上游 HEAD `7ab0b24`（2026-09-21）

---

## 1. 设计约束（一切的出发点）

这四条决定了后面所有取舍，改动代码前先读：

| 约束 | 含义 | 违反后果 |
|---|---|---|
| **零依赖** | 智能体是单文件 Perl，**不允许任何 CPAN 模块**；GUI 只用 Python 标准库 tkinter | 老机器装不上 / 安装链断裂 |
| **老 OS 兼容** | 目标机 perl 5.8.6+、bash 3.2、LibreSSL 无 `-pbkdf2`、High Sierra 的 VSCode 只到 1.85 | 用了新语法 = 整台机器用不了 |
| **完全离线可用** | 除 API 调用外不联网、不装包、不依赖 CDN | 内网/断网场景失效 |
| **隐私默认开启** | 对话历史必须加密落盘，家人共用一台 Mac 也读不到 | 核心卖点丢失 |

一句话：**「能在 2010 年的机器上双击跑起来」比「代码漂亮」优先。**

---

## 2. 架构总览：单后端 + 双前端

```
        ┌──────────────────────────────┐
        │  agent/claude-agent.pl       │  ← 唯一的智能体实现（2172 行）
        │  单文件 / 零 CPAN / Perl     │
        └───────┬──────────────┬───────┘
                │              │
     终端模式（默认）      GUI 模式（--gui）
     print / STDIN        STDOUT 输出 1 行 1 个 JSON
                │              │ STDIN  读入 1 行 1 个 JSON
                ▼              ▼
        ┌──────────┐    ┌─────────────────────┐
        │ Terminal │    │ gui/advisor_gui.py  │  tkinter（1796 行）
        │  .app     │    │ 子进程 + 队列 + 主题 │
        └──────────┘    └─────────────────────┘
```

**关键设计：智能体本身完全不知道前端是谁。**

所有输出都经过 `emit_*` 抽象层，会话循环和 `run_tool` 里没有一个 `$GUI` 判断：

| 函数 | 终端模式 | GUI 模式 |
|---|---|---|
| `emit_text` | `print "\n$PROVIDER> $text"` | `{"t":"text","text":...}` |
| `emit_tool` | `[tool_use] name({...})` | `{"t":"tool","name":...}` |
| `emit_status` | `... $text` | `{"t":"status","text":...}` |
| `emit_error` | 原文打印 | `{"t":"error","text":...}` |
| `emit_note` | 原文打印 | `{"t":"note","text":...}` |

新增一种输出时，**必须同时补终端与 GUI 两条路径**，否则某个前端会静默丢消息。

---

## 3. 进程与通信协议

GUI 通过 `subprocess.Popen` 拉起后端，`stderr` 直接丢弃（`DEVNULL`），只走
STDOUT/STDIN 的 JSON 行协议：

```python
# gui/advisor_gui.py::_start_backend
subprocess.Popen(cmd, env=env, stdin=PIPE, stdout=PIPE,
                 stderr=DEVNULL, bufsize=1,
                 universal_newlines=True, encoding="utf-8")
```

> 之所以用「子进程 + JSON 行」而不是 import 或 socket：Perl 与 Python 之间没有
> 共享库，JSON 行是这个约束下最省事的 IPC，且天然支持流式输出。

### 3.1 后端 → GUI

| `t` | 载荷 | GUI 行为 |
|---|---|---|
| `ready` | `provider`, `model`, `models[]`, `history` | 填充模型菜单、置空闲、写状态栏 |
| `text` | `text` | 含 ``` 走 `_render_reply` 一次性着色；否则 `_stream_append` 逐字流式 |
| `tool` | `name`, `input` | 灰色显示"正在使用工具" |
| `status` | `text` | 更新底部状态栏 |
| `error` | `text` | 红色追加 |
| `note` | `text` | 灰色追加（模型切换完成等） |
| `model` | `provider`, `model` | 更新菜单「← 使用中」标记 |
| `confirm` | `prompt` | 弹 yes/no，回 `{"t":"reply","value":"y"/"n"}` |
| `need_passphrase` | `prompt`, `recover` | 弹口令框 |
| `need_recovery` | `mode`, `question` | 弹合言葉框 |
| `need_key` | `provider` | 弹内嵌 API key 注册页 |
| `history_list` | `items[]` | 历史选择对话框 |
| `history_loaded` | `entries[]` | 重绘历史对话 |

### 3.2 GUI → 后端

| `t` | 载荷 | 说明 |
|---|---|---|
| `user` | `text` | 用户提问 |
| `reply` | `value` | `y` / `n`，回答确认提示 |
| `passphrase` | `value` | 历史口令 |
| `recovery` | `value` | 合言葉答案 |
| `key` | `provider`, `value` | 新注册的 API key |
| `cwd` | `path` | 切换工作目录 |
| `resume` | `index` | 继续某条历史 |
| `list_history` | — | 请求历史列表 |
| `quit` | — | 退出（后端所有 `gui_read_typed` 都把它当作终止信号）|

**协议不变量**：`gui_read_typed($want)` 会**跳过**所有非期望类型的行，并在遇到
`quit` 时立即返回 undef。因此新增事件类型时，必须确认没有哪个等待方会被它卡住。

---

## 4. 智能体核心（Perl）

### 4.1 工具集

| 工具 | 是否需要确认 | 说明 |
|---|---|---|
| `read_file` | 否 | 读文件 |
| `list_dir` | 否 | 列目录 |
| `write_file` | **是** | 写文件前 y/n 确认 |
| `run_shell` | **是** | 执行命令前 y/n 确认 |

系统提示里有一条**专门写给模型的行为约束**（见 `$SYSTEM_PROMPT`）：确认被拒
**只代表这一次被拒**，不代表环境禁用了工具，不许因此宣称"写文件/执行被禁用"，
而应停下来说明打算做什么、问用户想怎么调整、然后再试一次。

> 这是踩过的坑写进 prompt 的典型例子。改 prompt 时不要删掉这段。

### 4.2 多提供商：内部格式统一

**内部对话历史永远用 Anthropic 的 content blocks 格式**，只有在调用 Gemini 的
前后做一次边界转换。因此工具执行、输入处理、历史渲染的代码完全不需要感知提供商。

```
内部（Anthropic content blocks）
        │
        ├── provider=anthropic ──→ POST https://api.anthropic.com/v1/messages
        └── provider=gemini    ──→ POST .../v1beta/models/$MODEL:generateContent
                                    （contents / parts 转换）
```

> **已实现（M3）**：分派点已收敛到 `agent/claude-agent.pl` 的 `my %PROVIDERS` 注册表。
> 每个条目声明 `key_env / auth / model_prefix / default_model / url|url_template /
> api_version / build / parse`，`configure_provider`、`build_headers`、
> `build_request`、`parse_response` 四处都改成「查表 + 调用」。
> 新增提供商 = 注册表加一个条目 + 一对 `build_*`/`parse_*` 函数，
> 不再需要在 4 个地方同步改 if/elsif。
> 辅助函数：`provider_spec($name)`（未注册即 die）、`provider_for_model($id)`
> （按 `model_prefix` 反查，都不匹配时回落 `anthropic`）、
> `provider_from_command($cmd)`（`/claude` `/qwen` 等命令名 → provider，别名见
> `%PROVIDER_ALIAS`）。

**M4 起扩到 7 个（2026-10）**：`anthropic` / `gemini` / `openai` / `deepseek` /
`dashscope`（通义千问）/ `moonshot`（Kimi）/ `zhipu`（GLM）。后五家都走 OpenAI
兼容协议，**共用同一对 `build_request_openai` / `parse_response_openai`**，
彼此只差 `key_env`、`default_model`、`base_url`。新增厂商 = 注册表加一条目 +
`models.txt` 加一行。

OpenAI 兼容格式与内部格式（Anthropic content blocks）的对应关系：

| 内部（始终用这个） | OpenAI 兼容请求 |
|---|---|
| `system` 参数 | `messages[0] = {role:'system'}` |
| `{type:'text'}` | 同一条消息的 `content`（多段用 `\n` 拼接）|
| `{type:'tool_use', id, name, input}` | `assistant.tool_calls[]`，`arguments` 是 **JSON 字符串** |
| `{type:'tool_result', tool_use_id, content}` | 独立的 `{role:'tool', tool_call_id, content}` 消息 |
| `tools[].name/description/input_schema` | `{type:'function', function:{name, description, parameters}}` |

两个一定要记住的坑：
- **`tool_result` 不能像 Anthropic 那样塞进 user 消息数组**，必须是独立的
  `role:'tool'` 消息，靠 `tool_call_id` 关联。
- **`reasoning_content`（DeepSeek-R1 等的思考日志）不能回传**，否则 API 返回 400。
  适配器在解析阶段就丢弃，历史里不会存在。

其他机制：
- `base_url` 的优先级：`models.txt` 该行的 base_url → `CLAUDE_BASE_URL` → 注册表默认。
- `notools` 旗标（`models.txt` 第 7 列）会让请求不带 `tools`，用于不支持函数调用的模型。
- API 端点默认是 `<base_url>/chat/completions`，末尾斜杠会被吃掉。

需要注意的 Gemini 特例：
- **`thoughtSignature`**：Gemini 3 系在回传 `functionCall` 时必须原样带上，
  否则 400。转换层要保住这个字段。
- **thinking 默认 `LOW`**，可用 `CLAUDE_GEMINI_THINKING=high` 调深 —— Gemini 对
  简单问题也爱长时间思考，默认值是为体验调的。

`MAX_TOKENS = 4096`（两个提供商共用）。

### 4.3 不用模块的实现

- **JSON**：`MiniJSON` 包（`encode` / `decode` / `_decode_*`）是自研递归下降
  解析器。**没有 JSON::PP**。改它要同时跑通 encode/decode 双向往返。
- **HTTP**：`curl` 子进程（`call_api`）。TLS 不放在 Perl 侧 —— 这正是能在
  High Sierra 的旧 curl 上跑通的原因，也是 Tier A 能靠换 `CLAUDE_CURL` 解决的前提。
- **加密**：`openssl enc -aes-256-cbc` 子进程。密钥通过**环境变量**传给 openssl，
  绝不出现在命令行参数、`ps` 输出或磁盘上。

### 4.4 输入编码的坑（不要"优化"掉）

`STDIN` **故意保持生字节**，不加 `:encoding` 层。原因写在源码注释里：

> Perl 5.8.6 的 `PerlIO :encoding(UTF-8)`，在键盘逐字节到达的交互式读取下，
> 会在多字节字符中间截断缓冲区，报 `utf8 does not map to Unicode`。
> 管道整体输入不重现。所以改成读完一行、字节齐全后再统一 decode。

同理，`STDOUT` 加了 encoding 层后自动 flush 会失效，所以有显式 `$| = 1` 和手动
flush；`read_line_interactive` 会把终端切 raw 模式，因此 `restore_tty` 要保证
任何退出路径都还原终端（否则用户终端会瞎掉）。

---

## 5. 加密历史：密钥层级

```
        master key（随机，AES-256-CBC 用它加密每条会话）
          ├── key.enc          ← 用【口令】包起来
          └── key.recovery.enc ← 用【合言葉答案】包起来（可选）
                                 问题明文存在 key.recovery.q
```

两条恢复路径都能取出同一把 master key，所以忘记口令还能用合言葉救回来。

| 路径 | 内容 |
|---|---|
| `~/.claude-agent/history/<时间戳>.json.enc` | 单次会话（加密） |
| `~/.claude-agent/history/key.enc` | 口令包裹的 master key |
| `~/.claude-agent/history/key.recovery.enc` | 合言葉包裹的 master key |
| `~/.claude-agent/history/key.recovery.q` | 合言葉**问题**（明文） |
| `~/.claude-agent/history/.check` | 旧格式遗留；存在则走 `migrate_check_file` 迁移 |
| `~/.claude-agent/session.log` | 运行日志（chmod 0600） |
| `~/.claude-agent/gui.json` | GUI 配置（主题、上次模型等） |
| `~/.claude-agent-env` | 环境持久化（`CLAUDE_PROVIDER` / 模型 / key） |

### 已知弱点（承重，不要假装不存在）

- High Sierra 的 LibreSSL **不支持 `-pbkdf2`**，键导出只能用 MD5 派生 → 强度偏弱。
  定位是"远好于明文躺着"，不是"军事级"。
- 合言葉答案通常可猜 → 这是整个方案最薄的一环。UI/文档都应引导用户别用
  「第一辆车的名字」这类问题。
- **口令与合言葉同时丢失 = 历史不可恢复**。这是设计，不是 bug。
- `CLAUDE_NO_HISTORY=1` 时根本不问口令。

---

## 6. GUI 层（tkinter）

- **三主题**：`note`（带横线的笔记本）、`coding`、`hacker`（黑底绿字）。
  `THEMES` 字典集中管理，`_apply_theme` 统一切换。
- **横线/网格背景**用 Canvas 画洞和格子（`_draw_holes` / `_draw_grid`），
  通过 `_request_draw_*` 增量重绘，避免整窗重画造成卡顿。
- **流式输出**：`_stream_append` / `_stream_step` 逐字入文本框；但**含代码围栏
  的回复走一次性 `_render_reply`**，否则着色器会在未闭合的 ``` 上反复出错。
- **线程模型**：`_reader` 线程只做 `stdout → json → queue`，绝不碰控件；
  `_pump` 用 `root.after(80, ...)` 在主线程消费队列。**所有 UI 操作都在主线程。**
- **内嵌 key 注册**：首次启动无 key 时，不弹终端，直接在窗口里选提供商 →
  打开取 key 页面 → 粘贴 → 后台线程 `validate_api_key` → 通过后进主界面。
- **i18n**：`_detect_lang()` 读 macOS 的 `defaults read -g AppleLocale`（而不是
  `LANG`，因为 GUI 应用启动时 `LANG` 可能是空的）。文案集中在 `_S` 字典，
  用 `L(key, **kw)` 取。原生菜单栏用 pyobjc 本地化（`_localize_native_app_menu`）。
- **输入框**：避开 Terminal.app 的双字节输入问题，直接用 OS 的日文输入法。

---

## 7. 安装与分发

两条路，对应两类用户：

### ① 普通用户：standalone zip（不碰终端）

`release/build_standalone_app.sh` 用 **py2app** 打包成 `Advisor.app`，塞进 zip，
附带 `ReadMe_JP.txt` / `ReadMe_EN.txt`（讲清 Gatekeeper 首次右键「打开」的流程）。
未做 Apple Developer ID 签名 → 首次启动必有"未确认的开发者"警告，这是**预期**
行为，不是 bug。构建失败时自动降级为简化版 app，保证 `advisor` 命令一定可用。

### ② 开发者：`bash setup.sh`

`setup.sh`（702 行）负责：选择 Gemini/Anthropic → 引导并保存 key → 装
`~/bin/advisor`（bash 包装器）→ 装 bash 补全 → 生成 `Advisor.app` → 跑一次
连通性自检。首次会装 Xcode CLT（签名用，~190MB）、py2app、pyobjc（~7MB）。

> **职责划分**：参数解析、模型选择菜单都在 `~/bin/advisor` 这个 bash 包装器里；
> `agent/claude-agent.pl` 只保持**纯粹的对话循环**。新增 CLI 选项优先加在包装器。

### Tier 分层

| Tier | OS | 状态 | 关键点 |
|---|---|---|---|
| **B** | 10.9 Mavericks ~ 10.13 High Sierra+ | ✅ 已实现 | 标准 curl 已支持 TLS1.2，开箱可用 |
| **A** | 10.6 Snow Leopard ~ 10.8 Mountain Lion | ❌ 未开工 | 需在别的机器上编译 OpenSSL/curl 再传过去 |

Tier A 的接口已经预留：`CLAUDE_CURL` / `CLAUDE_CACERT` 可指向自建 toolchain；
`setup.sh` 若发现 `~/claude-toolchain` 会优先使用它。

---

## 8. 环境变量一览

| 变量 | 作用 |
|---|---|
| `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` | 密钥（代码里绝不含任何 key） |
| `CLAUDE_PROVIDER` | `anthropic` / `gemini` |
| `CLAUDE_MODELS_FILE` | 覆盖 `models.txt` 路径 |
| `CLAUDE_CURL` / `CLAUDE_CACERT` | 替换 curl / CA（Tier A） |
| `CLAUDE_OPENSSL` | 替换 openssl |
| `CLAUDE_NO_HISTORY` | `1` = 不保存历史（不问口令） |
| `CLAUDE_LANG` | `ja` / `en` 强制语言，否则自动检测 |
| `CLAUDE_GEMINI_THINKING` | `high` 加深 Gemini 思考 |

`models.txt` 格式：`<model_id>|<日本語>|<English>|<中文>|<provider>|<base_url>|[flags]`，一行一条。只有前两列必需，第 3 列起可省（老的三列表仍可直接用）。
CI 里有格式卡口，改格式必须同步改 CI。

---

## 9. 已知限制 / 技术债

1. **Tier A 完全未实现** —— 上游明确列为下一步，但需要交叉编译 toolchain。
2. **CI 覆盖不到真实 API** —— 无密钥、要计费，只做语法/一致性/启动冒烟。
3. **GUI 无法在无显示器环境验证** —— 本仓的 Linux 开发机只能静态审代码。
4. **`Advisor.app` 打包只能在 macOS 上验证** —— py2app + Gatekeeper 流程跑不了。
5. **MD5 键派生偏弱** —— 受 High Sierra 的 LibreSSL 限制，短期无解。
6. **单文件 2172 行** —— 与"零依赖单文件"的约束绑死，拆分需谨慎（见 §1）。

---

## 10. 改动规则

- 提交信息格式：`TYPE(scope) 中文描述`，例如 `FIX(gui) 修正流式输出重复追加`、
  `FEAT(agent) 增加 xxx 工具`。TYPE 用 `FEAT` / `FIX` / `DOCS` / `STYLE` /
  `CHORE` / `CI` / `UI`。
- 改 `agent/claude-agent.pl` 前必须确认：**没引入 CPAN 依赖**、**没用到 perl 5.8.6
  之后的语法**、`perl -c` 通过。
- 改 GUI↔后端协议时，同步更新本文 §3 的两张表。
- 版本号 / tag 由维护者决定，不自动打。
- 发布说明写进 `docs/releases/<tag>.md`。
