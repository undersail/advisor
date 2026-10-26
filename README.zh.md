# Advisor

## 🇯🇵 [日本語版はこちら →](README.md) ・ 🇺🇸 [Read this README in English →](README.en.md)

<img src="launcher/advisor.png" alt="Advisor" width="120">

*为 High Sierra 时代的老 Mac 打造的轻量 AI 智能体*

**Advisor** 让老 Intel Mac（Snow Leopard 到 High Sierra）重新变成一台真正好用的 AI
智能体 —— 一个轻量的终端 + 图形界面应用，同时支持 Claude（Anthropic）和
Gemini（Google）。

命令之所以叫 `advisor`，是刻意取的中性名字 —— 这样你不用去想背后到底是哪个 AI 在回答。

## 为什么要做这个

起因是一台我基本已经不再使用的旧 MacBook。一开始我以为今天的编程智能体根本没法跑在
这么老的系统上 —— 毕竟 High Sierra 最高只能装到 VSCode 1.85。后来发现这是个误解，
有些智能体确实能跑。

但就算能跑，AI 的 API 费用涨得也快。我想要的是在旧 Mac 上随手就能用、不用每问一句就
担心账单的东西。

真正的目标一直是两件事。第一，我想要一个类似随口聊天的伙伴 —— 有点像交换日记，不用
太正式，随手就能说两句。第二，既然都是 AI 了，我也希望能钻进终端拿到真正的编程帮助
—— 读文件、跑命令，全都要。**Advisor 就是要同时呈现这两张脸：温和的聊天伙伴，和
干脆利落的 AI。** 所以 GUI 有三个主题 —— 笔记、编程、黑客 —— 让你按心情在两副面孔
之间切换。

## 适合谁

- 抽屉里躺着 2010 年代 Mac、想再给它派点活的人
- 想跟稍微更像人的 AI 聊天或写日记，喜欢横线笔记本式的界面而不是冷冰冰的聊天框的人
- 只想要快速的终端编程帮助 —— 改文件、跑命令，不想为此开一个完整 IDE 的人
- 想避开昂贵订阅或按量计费的人 —— 光 Gemini 的免费额度就足够起步
- 和家人共用一台 Mac、希望自己的对话保持私密的人（历史记录加密）
- 想把这份东西顺手交给说中文、英文或日文的朋友的人 —— 它会自动跟随系统语言

## 特点

- **轻量，几乎无外部依赖** —— 智能体本体（`agent/claude-agent.pl`）是一个单文件
  Perl 脚本，零 CPAN 依赖。GUI 只用 Python 自带的 `tkinter`。
- **随时在七个 AI 之间切换** —— Claude（Anthropic）、Gemini（Google）、
  OpenAI、DeepSeek、通义千问（阿里云）、Kimi（月之暗面）、GLM（智谱 AI）。
  对话中用 `/claude` `/gemini` `/deepseek` `/qwen` `/kimi` `/glm` `/openai`
  切换。Gemini 有免费额度，整件事可以零成本先试一遍。
  其他 OpenAI 兼容的 API 也能用 —— 在 `models.txt` 里加一行即可。
- **GUI 首启直接选厂商** —— 七家的下拉，选中后「获取密钥」按钮自动跳到
  那一家的密钥页；模型菜单按厂商分级，不用在十几个名字里找。
- **GUI 三主题：笔记、编程、黑客** —— 横线笔记本式的聊天界面、黑底绿字的黑客终端
  风格，跟着心情走。
- **也能当普通终端命令用** —— 敲 `advisor` 就行，不需要 GUI。
- **对话历史加密保存在本地** —— 不知道你的口令的人读不到。
- **中文 / 日文 / 英文自动切换** —— GUI、终端文字、甚至 macOS 原生菜单栏，都会自动
  跟随你 Mac 的系统语言。
- **可双击运行的 `Advisor.app`** —— 完全不需要终端经验。拖进 Dock，之后一键就开。
- **API 密钥直接在 GUI 里登记** —— 第一次启动若还没有密钥，会给你一个应用内页面而
  不是在终端里问你。选厂商、点按钮打开申请页面、粘贴进来 —— 完事。全程不用开终端。

## 支持的 OS 层级

- **Tier B：Mavericks（10.9）～ High Sierra（10.13）及更新** —— 系统自带的 `curl`
  已支持 TLS 1.2，不需要额外编译。目前实现的正是这一层。
- **Tier A：Snow Leopard ～ Mountain Lion（10.6–10.8）** —— 系统 `curl` 连 TLS 1.0
  都够不着，需要自行编译 OpenSSL/curl（在新机器上取源码 → 传到目标机 → 在目标机上
  本地编译）。尚未开工，是下一步。

## 安装（Tier B：High Sierra 等）

有两条路。不习惯终端就走 ①，是开发者或者不介意命令行就 ②。

### ① 下载即用（不需要终端）

1. 从[最新发布](https://github.com/watermark-hd/advisor/releases/latest)下载
   **`Advisor-v0.1-standalone.zip`** 并解压
2. 把里面的 `Advisor` 拖进 `Applications` 文件夹（或 Dock）
3. **仅第一次**不要双击，而是右键（或 Control-点击）选择「打开」。macOS 会提示开发者
   未验证（这是预期的 —— 这个构建还没有用付费的 Apple Developer ID 签名），再点一次
   「打开」。之后每次正常双击即可。

首次启动会显示应用内的 API 密钥登记页面 —— 全程没有终端窗口。压缩包里也附了
`ReadMe_ZH.txt`，内容与上面一致。

### ② 从源码使用（终端，面向开发者）

把整个仓库下载（或 `git clone`）下来，然后：

```bash
bash setup.sh
```

它会一次走完：选择 AI（Gemini 或 Anthropic）、获取并保存 API 密钥、安装 `advisor`
命令、设置 bash 补全、构建可双击的 `Advisor.app`、并确认 API 真的能通。完成后打开一个
新的终端窗口（或执行 `source ~/.bash_profile`），敲 `advisor` 就行。它构建出的
`Advisor.app` 在没有密钥时同样会显示应用内登记页面，和 ① 一样。

> `Advisor.app` 用 [py2app](https://py2app.readthedocs.io/) 构建。首次运行会自动安装
> Xcode Command Line Tools（签名需要，约 190MB，一次性）、py2app 本体，以及
> [pyobjc](https://pyobjc.readthedocs.io/)（约 7MB，用于本地化 macOS 原生菜单栏）。
> 若这一步因故失败，安装脚本会自动退回到更简单的应用包，所以无论哪种情况，
> `advisor` 命令最终都能用。

## 使用 GUI

双击 `Advisor.app`，或者运行 `advisor gui` —— 两种方式都会直接打开 GUI，不弹终端窗口。

**如果还没有登记 API 密钥**，你会先看到一个设置页面而不是正常聊天界面。选 Gemini
（免费）或 Anthropic（付费），点按钮打开申请页面，把密钥粘进来，它会当场验证连通性，
然后进入正常界面。

- 顶部的 **[ 对话 ] [ 命令 ]** 两个标签，用于在 AI 对话界面和 shell 命令面板之间切换。
- 有三个视觉主题：**笔记**（横线、手写笔记本风格）、**编程**、**黑客**（黑底绿字）。
  随时可在标题栏的 **[ 主题 ]** 里切换。
- **[ 切换 AI ]** 用来选 Claude 或 Gemini 的模型，**[ 继续上次 ]** 用来打开以前加密
  保存的对话。
- 输入框直接使用 Mac 正常的输入法，绕开了 Terminal.app 的双字节字符问题。

## 使用终端（`advisor` 命令）

智能体本体（`agent/claude-agent.pl`）刻意保持成一个简单的对话循环 —— 选项解析和模型
选择菜单放在生成的 `~/bin/advisor` bash 包装脚本里。

**最基本的：**

```
advisor            启动
（从列表里选一个编号）    切换你在对话的 AI
输入你的问题           得到回答
exit               退出
```

AI 在 `setup.sh` 里选一次就够了。之后切换就是**输入列表里的编号**：

```
  1) Claude Opus 5 — 顶级性能・付费
  2) Claude Sonnet 5 — 均衡型・付费
  3) Claude Haiku 4.5 — 高速・付费
  4) Gemini Flash-Lite — 快・免费   ← 当前
  5) Gemini Flash — 高性能・免费
输入编号即可切换。也可以直接提问。

有什么需要？> 3        ← 只输入这个就会切到 Haiku
```

对话中随时可用：

| 输入 | 会发生什么 |
|---|---|
| `1`–`5`（编号） | 切换到该 AI（厂商也会自动跟着切，并记住到下次）|
| `/model` 或 `?` | 再次显示 AI 列表 |
| `/claude` / `/gemini` | 只切换厂商 |
| `exit` / Ctrl-D | 退出 |

Shell 层选项（需要时才用）：

```
advisor --select-model [编号]  从命令行选择 AI
advisor --list-models          列出可用的 AI
advisor -m <ID>                仅本次改用别的 AI
advisor --list-history         列出已保存的对话
advisor --resume               继续已保存的对话
advisor --no-history           本次不保存
advisor --change-passphrase    修改历史记录口令
advisor --set-recovery         设置密保问题
advisor -h / --version         帮助 / 版本
```

在新终端里输入 `advisor ` 然后按 Tab 可以补全选项名；在 `advisor -m ` 之后按 Tab 会
补全可用的模型 ID（见 `completion/advisor-completion.bash`，已在 High Sierra 自带的
bash 3.2 上测过）。

- 随时用 **`/model`**（或 `?`）再看一次列表。
- 选编号会连带自动切换底层厂商（Claude/Gemini），并保存到 `~/.claude-agent-env` 供
  下次使用。如果那个 AI 你还没存密钥，会当场让你粘贴。
- 只想切厂商，用 **`/claude`** / **`/gemini`**。
- Gemini 即使回答简单问题也容易「想」很久，所以思考深度默认设得很浅（`LOW`）。想要它
  想得更深，设 `CLAUDE_GEMINI_THINKING=high`。

## 关于中文 / 日文 / 英文

Advisor 会检查 Mac 的系统语言（`defaults read -g AppleLocale`），并自动在中文、日文、
英文之间切换 GUI、终端文字、`setup.sh` 的提示，甚至 macOS 原生菜单栏。

也可以用 `CLAUDE_LANG=zh`（或 `ja`、`en`）环境变量强制指定语言。

## 对话历史（加密，保存在本地）

默认情况下，对话会被加密保存到 `~/.claude-agent/history/<时间戳>.json.enc`。即使和
家人共用一台 Mac，不知道你口令的人也读不到。

### 机制

- 每个对话文件用一个随机生成的**主密钥**加密，而这个主密钥本身又被你的**口令**（以及
  可选的**密保答案**）包装进 `key.enc` / `key.recovery.enc`。两者任一都能解出主密钥，
  所以只要你设了密保，忘记口令并不等于全部丢失。
- 加密通过调用 `openssl enc -aes-256-cbc` 完成（对 High Sierra 自带的 LibreSSL 也能
  正常工作）。密钥材料通过环境变量传给 openssl —— 绝不经过 `ps` 输出、命令行或磁盘。
- High Sierra 的 LibreSSL 不支持 `-pbkdf2`，所以密钥派生退回基于 MD5 的方式，安全性弱
  于现代 KDF —— 但仍远远好于把历史明文存盘。

### 用法

- 第一次运行时会让你设置口令（输两遍），紧接着可选设置密保（一个秘密问题）。之后每次
  启动问一次口令（输入时不显示）。没有重试次数限制，打错多少次都行。什么都不输入直接
  回车，则以「本次不保存历史」的方式启动。
- 忘记口令了？在提示处输入 `r`，通过密保答案恢复（只有设过密保才行）。恢复后可以马上
  设置新口令。密保答案不区分大小写，也忽略首尾和重复的空白。
- `advisor --resume` 继续上一次的对话；`advisor --list-history` 列出全部已保存的对话。
- `advisor --change-passphrase` 修改口令，`advisor --set-recovery` 设置或修改密保 ——
  两者都只是重新包装主密钥，已有历史不受影响。
- `advisor --no-history`（或 `CLAUDE_NO_HISTORY=1`）关闭本次保存 —— 完全不会问你口令。
- **如果口令和密保答案都忘了，已经保存的内容就全部无法读取。** 想重新开始，删掉
  `~/.claude-agent/history/` 再重新设置即可。

> 注意：一个能被猜到的密保答案（比如「第一辆车」）是整套方案里最弱的一环。请选一个像
> 真密码那样不好猜的东西，或者接受这个取舍。

## 关于智能体（`agent/claude-agent.pl`）

- 单文件，零外部 CPAN 依赖
- 手写 JSON 编解码（递归下降解析器）
- 四个工具：`read_file` / `write_file` / `list_dir` / `run_shell`（写入和 shell 执行
  会先请求确认）
- 内部对话历史始终用 Anthropic 的 content-block 格式保存，只在每次 Gemini API 调用
  前后转换成 Gemini 的 `contents`/`parts` 格式 —— 工具执行和输入处理代码完全不需要
  感知当前是哪个厂商
- 处理了 Gemini 3 的 `thoughtSignature` 要求（回传 functionCall 时必须原样带上，
  否则 API 返回 400）
- HTTP 通过以子进程方式调用 `curl` 完成（把 TLS 处理完全交给系统）
- 历史加密通过调用 `openssl` 完成（见上）
- `CLAUDE_CURL` / `CLAUDE_CACERT` 环境变量可以换用自建工具链给 Tier A 机器使用
  （若 `~/claude-toolchain` 存在，`setup.sh` 会自动优先使用它）

## 支持的 AI 与自定义模型

内置 7 个厂商，各自读自己的环境变量（`/deepseek` 之类的命令会在对话中提示你粘贴）：

| 厂商 | 命令 | 环境变量 | 默认模型 |
|---|---|---|---|
| Anthropic | `/claude` | `ANTHROPIC_API_KEY` | `claude-sonnet-5` |
| Google | `/gemini` | `GEMINI_API_KEY` | `gemini-3.5-flash-lite` |
| OpenAI | `/openai` | `OPENAI_API_KEY` | `gpt-4o` |
| DeepSeek | `/deepseek` | `DEEPSEEK_API_KEY` | `deepseek-chat` |
| 通义千问（阿里云） | `/qwen` | `DASHSCOPE_API_KEY` | `qwen-plus` |
| Kimi（月之暗面） | `/kimi` | `MOONSHOT_API_KEY` | `kimi-k2-0905-preview` |
| GLM（智谱） | `/glm` | `ZHIPU_API_KEY` | `glm-4.6` |

后五家走的是 OpenAI 兼容协议，共用同一套适配器。要加自己的模型，在 `models.txt`
里加一行：

```
<模型ID>|<日文说明>|<英文说明>|<中文说明>|<provider>|<base_url>|[flags]
```

- `provider` 必须是上面 7 个之一（想接别家 OpenAI 兼容服务就写 `openai`）
- `base_url` 是 OpenAI 兼容端点，程序会自己接上 `/chat/completions`
- 第 4 列之后都可以省略，省略时按前几列工作
- `flags` 目前只有 `notools`（该模型不支持函数调用时加上，程序就不会发送工具定义）
- 想整体换掉端点（比如走自建代理），设 `CLAUDE_BASE_URL` 即可，优先级高于表格

厂商层面的信息（读哪个环境变量、默认模型、密钥页地址、显示名）集中在
`providers.txt`，一行一家：

```
provider|key_env|default_model|key_url|日文名|英文名|中文名
```

GUI 的首启下拉和模型菜单都读这个文件，所以改这里就够了，不用动代码。
CI 会核对 `providers.txt`、`models.txt`、代码里的注册表三者是否一致。

> 模型 ID 请以各厂商文档为准 —— 内置值只是方便起步的默认。

## 关于费用

本仓库本身免费，但要真正和 AI 对话，你需要自己的 API 密钥。代码里任何地方都不包含
API 密钥。

- **Gemini**：用任意 Google 账号在
  [aistudio.google.com/apikey](https://aistudio.google.com/apikey) 申请 —— 免费额度
  （无需绑卡）足够舒服地起步。
- **Anthropic**：在 [console.anthropic.com](https://console.anthropic.com/) 申请，
  并在 Billing 里充值少量额度（这是单独的按量计费，和 claude.ai 的 Pro/Max 订阅不是
  一回事）。

## 许可证

[MIT License](LICENSE)
