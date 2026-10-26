# Advisor 开发计划

**基线**：fork 自 `watermark-hd/advisor` @ `7ab0b24`（2026-09-21）· 版本 `0.1`

---

## 0. 当前状态

| 项目 | 状态 |
|---|---|
| Tier B（10.9 ~ 10.13+）终端 + GUI | ✅ 上游已实现 |
| 双提供商（Claude / Gemini） | ✅ 上游已实现 |
| **7 提供商（+ OpenAI / DeepSeek / 通义千问 / Kimi / GLM）** | ✅ 本 fork 已实现（M4）|
| 加密历史 + 口令/合言葉双恢复 | ✅ 已实现 |
| 日英双语（自动跟随系统语言） | ✅ 已实现 |
| 内嵌 GUI key 注册 | ✅ 已实现 |
| standalone zip 分发 | ✅ 已实现（未签名） |
| **Tier A（10.6 ~ 10.8）** | ❌ 未开工 |
| CI / Gitee 镜像 / 文档骨架 | ✅ 本仓已落位（§1） |
| **中文支持** | ❌ 待做（方向一） |
| **OpenAI + 国产模型接口** | ❌ 待做（方向二） |
| **企业微信 / 飞书远程接入** | ❌ 待做（方向三，微信已排除） |

---

## 1. 本仓已铺好的工程骨架

| 文件 | 作用 |
|---|---|
| `.editorconfig` | utf-8 / LF / 2 空格（`.pl` `.py` 为 4） |
| `.github/workflows/ci.yml` | perl -c、`--version` 冒烟、py_compile、bash -n、`models.txt` 格式卡口、CRLF 检查；矩阵 ubuntu + macos |
| `.github/workflows/sync-gitee.yml` | main + tag → `gitee.com/undersail/advisor` 镜像；凭据 `oauth2:`→`undersail:` 自动回退 |
| `docs/design_doc_advisor.md` | 架构、JSON 行协议、加密密钥层级、已知限制、改动规则 |
| `docs/releases/` | 发布说明，文件名 = tag 名 |

**CI 刻意不做什么**：不调真实 API（要密钥且计费）、不跑 GUI（无显示器）、
不打包 `.app`（需 macOS + py2app）。

---

## 2. 本 fork 的方向（已确认）

上游是"日英双语 + 双提供商 + 单机"的成品。本 fork 在它之上做三件事，
按**依赖顺序**排列（后一项依赖前一项的抽象，不是随便排的）：

```
方向一 中文化 ──────────────┐（独立，可先做，零风险）
                            ├──→ 方向三 远程接入
方向二 多模型接入 ──────────┘（远程对话总得能选国内模型）
```

> 顺序理由：远程接入必然要选模型（国内用户多半用国内模型）+ 要中文界面，
> 所以 ①② 是 ③ 的前置。①② 之间无依赖，可并行。

---

## 3. 方向一 · 中文化

### 3.1 现状实测（不是估计）

| 位置 | 条数 | 现有结构 |
|---|---|---|
| `agent/claude-agent.pl` → `my %S` | **96** | 原为 `key => ["日本語", "English"]`；已改为 `{ ja => , en => , zh => }` |
| `gui/advisor_gui.py` → `_S` | **59** | 同上，`L()` 里 `ja, en = _S[key]` |
| `setup.sh` → `msg()` | **87** 处调用 | `IS_EN=0/1` 二元 case |
| `models.txt` | 5 行 | `id|日本語ラベル|English label` |
| 文档 | README.md(ja) / README.en.md / release/ReadMe_JP.txt / ReadMe_EN.txt | 日英各一份 |

**关键缺陷**：语言判定是**二元的**，不是"支持 ja/en"这么简单 ——
`$LANGCODE eq 'en' ? $pair->[1] : $pair->[0]`，即**非 en 一律出日文**；
GUI 侧 `_detect_lang()` 是"非 `ja*` 一律出英文"。所以**今天一个中文用户
在 GUI 上看到英文、在终端上看到日文**。中文化必须先把二元判断改成三分支。

### 3.2 设计决定

**A. `%S` / `_S` 从 arrayref 改成 hashref**

```perl
# 现在
need_key => ["%s を設定してください\n", "Please set %s\n"],
# 改成
need_key => { ja => '%s を設定してください', en => 'Please set %s', zh => '请设置 %s' },
```

理由：加语言不用改索引、不会错位。改动面其实很小 —— **读取点各自只有 1 处**
（`L()` 函数），剩下 96 + 59 条是纯数据替换。

**B. 语言解析改成三分支 + 回退链**

```
CLAUDE_LANG（手动覆盖，最高优先）
  → macOS AppleLocale（defaults read -g AppleLocale）
  → 匹配 ja* / zh*（zh-Hans / zh-Hant / zh_CN 都算） / 其他 → en
  → 取不到 → ja（保持上游现状，不破坏老用户）
回退链：zh 缺失的 key → en → ja。禁止出现空字符串。
```

**C. `models.txt` 扩列，保持向后兼容**

M2 先加第 4 列中文；M4 又把 provider / base_url / flags 加上，最终格式：

```
id|日本語|English|中文|provider|base_url|flags   ← 7 列（当前）
id|日本語|English|中文                            ← 4 列（M2 时期，provider 靠 ID 前缀推断）
id|日本語|English                                 ← 3 列（旧，中文回退英文）
id|日本語                                          ← 2 列（更旧，原样兼容）
```
`split /\|/, $l, 7` 天然兼容列数变少；缺列时 `provider` 留空、按
`model_prefix` 反推，`base_url` 留空、回落到注册表默认。
CI 只做结构性检查（2~7 列），provider / base_url / flags 的业务校验全在
`scripts/check-models.py`。

**D. 文档**
- 新增 `README.zh.md`，并在 `README.md` / `README.en.md` 顶部互加语言切换链接
- 新增 `release/ReadMe_ZH.txt`（standalone zip 里的中文引导；注意包内文件名必须
  **纯 ASCII** —— 上游专门为此改过一次名，别再踩）
- `docs/` 本来就用中文写，无需改

### 3.3 任务清单

- [x] `agent/claude-agent.pl`：`L()` 改 hashref/数组双支持 + `$LANGCODE` 三分支（zh→en→ja 回退）
- [x] `agent/claude-agent.pl`：`%S` 96 条补中文
- [x] `agent/claude-agent.pl`：`print_help`（单引号 heredoc，非 `%S` 条目）另起中文分支
- [x] `gui/advisor_gui.py`：`L()` 改 dict/tuple 双支持 + `_detect_lang()` 三分支
- [x] `gui/advisor_gui.py`：`_S` 59 条补中文
- [x] `gui/advisor_gui.py`：硬编码文案扫一遍 —— 主题名原只有 `label`/`label_en`，zh 下会显示日文，已加 `label_zh` 并改 `theme_label()`
- [x] `setup.sh`：`IS_EN` 改为由 `LANGCODE` 派生；`msg()` 实际 54 条（非 87，87 是调用点数）补中文，未命中落回原 en/ja
- [x] `models.txt`：4 列格式 + 5 个模型补中文标签（Perl 解析同步改限 4 段选列）
- [x] `README.zh.md` + 三份 README 互链 + 语言说明改三语
- [x] `release/ReadMe_ZH.txt`（ASCII 文件名）+ `build_standalone_app.sh` 打包列表
- [x] **CI 卡口**：`scripts/check-i18n.py` —— 抽出 `%S` / `_S` 的全部 key，比较同一 key 的 `ja`/`en`/`zh` 占位符个数是否一致（不一致时 sprintf/format 会崩或错位）；未译条目只报告不判死，收尾阶段可加 `--strict`。已接入 CI 第 5 步

### 3.4 陷阱

- `%s` 占位符数量与顺序**必须**与日英一致，否则 `sprintf` 会崩或错位
- `setup.sh` 的 heredoc 里嵌了给 `~/bin/advisor` 生成的代码，**那段是生成给
  bash 3.2 用的**，中文字面量在里面要留意引号嵌套
- 别翻译 `run_shell` 类工具名、`--flag` 名、环境变量名 —— 只翻人类可读文案
- 上游日后同步会在这 96+59 条上冲突，**同步时要整段手动合并**，不要盲信
  `git merge` 的自动结果

**规模**：约 242 条文案 + 6 处逻辑分派。**风险低**（纯数据 + 一处读取逻辑），
但机械量大。

---

## 4. 方向二 · 模型配置支持 OpenAI 与中国常用模型

### 4.1 现状实测

提供商逻辑**硬编码在两个分支上**，分散在 4 个函数里：

| 函数 | 行 | 现在 |
|---|---|---|
| `configure_provider` | 325 | `if gemini / elsif anthropic / else die`，设 `$API_KEY $MODEL $API_URL $ANTHROPIC_VERSION` |
| `build_headers` | 715 | `if gemini → x-goog-api-key`，否则 → `x-api-key` + `anthropic-version` |
| `build_request` | 831 | 分流到 `build_request_anthropic` / `build_request_gemini` |
| `parse_response` | 914 | 分流到 `parse_response_anthropic` / `parse_response_gemini` |

**加第 3、4、5 个提供商不是"复制粘贴两个函数"就完事** —— 4 处 `if/elsif`
会长成 4 处 6 分支的 ladder，必错。必须先抽象。

### 4.2 核心洞察：一套适配器覆盖 OpenAI + 几乎所有国产模型

国产主流厂商**全部**提供 OpenAI Chat Completions 兼容端点。所以：

> **1 个 `openai` 适配器 + 1 张 base_url 表 = 覆盖 OpenAI + 8 家国产厂商。**
> 不需要为每家写适配器。

| 厂商 | base_url | 备注 |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | |
| **DeepSeek 深度求索** | `https://api.deepseek.com/v1` | **首批** · `deepseek-chat` / `deepseek-reasoner` |
| **通义千问（DashScope）** | `https://dashscope.aliyuncs.com/compatible-mode/v1` | **首批** |
| **Moonshot Kimi** | `https://api.moonshot.cn/v1` | **首批** |
| **智谱 GLM** | `https://open.bigmodel.cn/api/paas/v4` | **首批** |
| 豆包（火山方舟） | `https://ark.cn-beijing.volces.com/api/v3` | model 填 endpoint id |
| MiniMax | `https://api.minimax.chat/v1` | |
| 零一万物 Yi | `https://api.lingyiwanwu.com/v1` | |
| 硅基流动 SiliconFlow | `https://api.siliconflow.cn/v1` | 聚合多家，一家通吃 |

> **已定**：首批内置 **DeepSeek + 通义千问 + Kimi + 智谱** 四家（覆盖面最广）。
> 其余厂商**不进内置表也没关系** —— 用户用 `CLAUDE_BASE_URL` 手填即可直接用，
> 代码零改动。

### 4.3 重构方案

**A. 提供商注册表（替代 4 处 if/elsif）**

```perl
my %PROVIDERS = (
  anthropic => {
    key_env => 'ANTHROPIC_API_KEY', url => 'https://api.anthropic.com/v1/messages',
    headers => \&headers_anthropic,
    build   => \&build_request_anthropic,
    parse   => \&parse_response_anthropic,
  },
  gemini => { key_env => 'GEMINI_API_KEY', ... },
  openai => {   # ← 一族共用
    key_env => 'OPENAI_API_KEY',
    base_url => 'https://api.openai.com/v1',   # 可被 CLAUDE_BASE_URL 覆盖
    headers => \&headers_openai,
    build   => \&build_request_openai,
    parse   => \&parse_response_openai,
  },
);
```

四个原函数各变成"查表 + 调用"，`configure_provider` 认 `CLAUDE_BASE_URL`
覆盖 base_url —— 这样加一家国产厂商**只是加一行配置，不动代码**。

**B. 新增 `build_request_openai` / `parse_response_openai`**

内部格式**保持不变**（Anthropic content blocks 是内部唯一表示，见设计文档 §4.2），
只在 API 边界转换。三处格式差异必须处理对：

| 项 | Anthropic（内部格式） | OpenAI |
|---|---|---|
| 消息体 | `messages[{role, content}]` | 同，但 content 也可以是数组 |
| 工具定义 | `{name, description, input_schema}` | `{type:"function", function:{name, description, parameters}}` |
| 工具调用（模型） | `content[]` 里的 `tool_use` block | `message.tool_calls[]`（含 `id`） |
| 工具结果（回传） | `content[]` 里的 `tool_result` block | 独立消息 `{role:"tool", tool_call_id, content}` |
| 系统提示 | 顶层 `system` 字段 | `messages` 里 `role:"system"` 的一条 |
| 鉴权头 | `x-api-key` + `anthropic-version` | Authorization 头（Bearer + key） |

**C. key 存储要支持多把**

现在 `~/.claude-agent-env` 存的是单把 key 相关的变量。多提供商后需要按
provider 分开存（例如 `CLAUDE_API_KEY_OPENAI` / `_DEEPSEEK`），
否则切一次提供商就丢一次 key。

### 4.4 已知坑（逐条都要处理，否则会"能连上但不干活"）

1. **国产模型对 tool calling 支持参差** —— 部分小模型不支持 function calling。
   必须做**能力降级**：不支持就退化成纯对话（不注册工具），而不是报错。
   探测方式：模型列表里标一个 `notools` 标记，或首次失败后缓存"该模型无工具"。
2. **推理模型的 `reasoning_content`** —— DeepSeek-R1 一类会多返回
   `reasoning_content`，**不能回传**到下一轮 messages，否则 400。
3. **流式** —— 现在全非流式，暂不引入流式，保持简单。
4. **`max_tokens` 语义** —— 部分厂商用 `max_tokens`，部分要
   `max_completion_tokens`（新版 OpenAI 推理模型）。走配置项而非硬编码。
5. **错误体格式不同** —— 现在 `parse_response_*` 里有错误解析，新适配器要
   自己把 `{"error":{"message":...}}` 统一成内部错误文案。
6. **GUI 侧也要改** —— `gui/advisor_gui.py::validate_api_key` 里硬编码了
   Anthropic / Gemini 两个 URL（第 345、351 行），必须一并支持新 provider，
   否则 GUI 的 key 注册页只认两家。
7. **菜单会撑爆** —— 现在模型菜单是 5 个平铺项（`show_model_menu` 是数字选择）。
   6 家 × 各自 N 个模型会变成几十条。需要**两级菜单**：先选厂商、再选模型。
   这会同时影响：终端数字选择、GUI 下拉菜单、bash 补全。

### 4.5 任务清单

- [x] 抽 `%PROVIDERS` 注册表，4 个函数改成查表（M3 已完成）
- [x] `build_request_openai` / `parse_response_openai`（含 tool_calls ↔ tool_use 双向转换）
- [x] `headers_openai`：鉴权用 Authorization 头（值为 Bearer + key）+ base_url 可配置；首批四家 base_url 与推荐模型（另加 OpenAI 本体，共 5 个 base_url 型 provider）
- [x] `models.txt` 扩列：`id|ja|en|zh|provider|base_url|[flags]`（列数向后兼容，12 条模型）
- [x] 多 key 存储（按 provider）：`switch_provider` 读注册表的 `key_env`，各厂商独立环境变量
- [x] 工具能力降级（`notools` 标记 → 请求不带 tools）
- [x] `reasoning_content` 剥离（解析阶段丢弃，历史里不存在）
- [x] 两级模型菜单（终端 + GUI）——终端 `/model` 先厂商后模型；GUI 用 cascade 子菜单，点击发 `/model <id>` 而不是编号。bash 补全只补命令行参数与模型 ID，与菜单无关，无需同步
- [x] GUI onboarding 支持新 provider：首启改成 7 家下拉，密钥页链接/校验方式/默认模型全部从 `providers.txt` + `models.txt` 推导；`validate_api_key` 增加 OpenAI 兼容分支；保存 key 时不清掉别家的 key
- [x] `unknown_provider` 报错文案改为按注册表生成（M3 遗留已清）
- [x] **CI 卡口**：`scripts/check-models.py` —— provider 必须在注册表里、base_url 型必须有 base_url、ID 不重复、flags 词合法（已接入 CI 第 4b 步）
- [ ] 真实连通性手测（需各厂商 key，本地做，不进 CI）—— **未做**：已在本地用 mock 的 OpenAI 兼容服务验证完整链路，真 key 需你提供

**规模**：注册表重构 1~2 人日；openai 适配器 + 双向转换 2~3 人日；
菜单两级化与 GUI 同步 2 人日；能力降级与坑 2~3 人日。**合计约 7~10 人日**。
**风险中**：主要风险在"各家行为不一致"，必须逐家手测，CI 帮不上。

---

## 5. 方向三 · 企业微信 / 飞书远程接入（微信已排除）

### 5.1 平台范围（已定：砍掉微信）

advisor 现在是**单机单用户**的 CLI + GUI，没有任何网络服务端。远程接入实质是
**加一个网关角色**，而两个（原三个）平台的接入能力完全不同：

| 能力 | 企业微信 | 飞书 | ~~微信（公众号/客服）~~ |
|---|---|---|---|
| 纯出站推送（不需要公网） | ✅ 群机器人 webhook | ✅ 自定义机器人 webhook | ❌ 无此能力 |
| 接收消息 | 应用消息需公网回调 URL / 可信 IP | 自建应用支持回调，也支持**长连接（WebSocket，不用公网 IP）** | 需公网 HTTPS + 签名校验 + **5 秒响应**（超时重试 3 次） |
| 身份获取 | userid（组织内确定） | open_id（组织内确定） | openid |
| 零 CPAN Perl 可实现性 | 中 | 实时双向：**差**（wss 客户端写不出来） | 中（要写 HTTP server + 签名） |

**微信为什么砍掉**：需**已认证主体**（个人号走不通）、需公网 HTTPS 回调、
**5 秒硬超时**（模型一轮就 30 秒，必须异步 ack + 重试去重），
投入最大而收益与企微/飞书重叠。**已排除，不在范围内。**

### 5.2 三档方案

#### 档① 出站通知（约 1~2 人日）✅ 采用
企业微信 / 飞书群机器人都是"POST 一个 JSON 到 webhook URL"。纯 curl 即可，
零依赖可行。用途：任务完成通知、错误告警、长任务进度。

> **它会喊你，但不会听你说话** —— 单向，你在手机上发的指令它收不到。

价值：先跑通链路与凭据，且即使档②做不成，这个也一直有用。

#### 档② 轮询式中继（约 3~5 人日）✅ 采用
```
老 Mac（NAT 后）  ──轮询──>  中继（Cloudflare Worker / VPS）  <──回调──  企微/飞书
       └──────────── POST 结果 ────────┘
```
- 老 Mac **主动轮询**取待处理消息，处理完 POST 回结果
  → **无需公网入站、无需端口映射、NAT 后面也能用**
- 平台回调仍要有公网 URL，但落在**中继**上（Cloudflare Worker 免费额度够）
- 代价：延迟（3~5 秒轮询间隔）、需维护一个中继服务、多一处信任边界

> 体验：像"发消息，过几秒回信"。这是**没有公网 IP 也能双向派活**的现实解。

#### 档③ 双向实时（逐字流式，约 10~15 人日）⏸ 暂缓
- 飞书自建应用的**长连接模式**理论上不用公网 IP，但 wss 客户端在零 CPAN Perl 里
  手写 RFC6455 + TLS **不现实** → 要么破"零 CPAN"约束，要么走回调 + 隧道
- 若做：老 Mac 上跑极小 HTTP server（Perl `IO::Socket::INET` 零依赖可写，
  或 Python 标准库 `http.server`）+ Cloudflare Tunnel / ngrok 打出公网 HTTPS
- 平台只等 5~10 秒而模型要跑 30 秒 → 必须"立即 ack + 异步回推"

**暂缓理由**：本项目的使用场景是"在手机上给家里 Mac 派活"，不是"跟它聊天"。
档② 已覆盖该场景；档③ 换来的主要是逐字流式体验，边际价值低，还多一个隧道
依赖（老 Mac 常断线，隧道需重连监控）。**真需要时随时可加，不破坏已有结构。**

### 5.3 🔴 安全模型必须重做（这一条最重要，不做就不要上远程）

现在 `write_file` / `run_shell` 靠**本地 y/n 按键确认**（见设计文档 §4.1）。
远程模式下**没有本地用户按确认键** → 确认链断裂 → 等于把一台能执行任意
shell 的机器暴露给"任何能给这个账号发消息的人"。

**已定策略：远程模式只读。**

1. **只放 `read_file` / `list_dir`**；`write_file` / `run_shell` 在远程模式
   **代码里硬关**，不做成"配置项可以打开" —— 一旦可开，迟早会被打开
2. **发送者白名单**：`userid` / `open_id` 白名单，非白名单**直接丢弃**并记日志
   （不要回"无权限" —— 会暴露机器人存在）
3. **审计日志**：谁、何时、让 agent 做了什么，落 `~/.claude-agent/audit.log`
   （现有 `session.log` 扩展即可），只追加、不覆盖
4. **历史加密在远程模式下仍要生效**，且用**独立口令 + 独立历史目录**，
   不与本地会话共用

### 5.4 架构上的好消息

`emit_*` 抽象层（设计文档 §2）本来就是为"多前端"设计的。远程网关完全可以
**复用 `--gui` 的 JSON 行协议**，加一个 `--rpc` 模式当作第三前端：
智能体核心一行不用改。这是已实现的设计红利，务必利用，不要另起一套。

### 5.5 任务清单

- [ ] `--rpc` 模式：复用 JSON 行协议，作为第三前端
- [ ] 网关进程：接收平台消息 → 转 `--rpc` → 回推结果
- [ ] 档① 出站通知（企微群机器人 + 飞书自定义机器人）
- [ ] 档② 轮询中继（Cloudflare Worker + 老 Mac 轮询端）
- [ ] 只读工具集 + 白名单 + 审计日志（**先于**任何远程能力上线）
- [ ] 远程模式的独立口令与独立历史目录
- [ ] ~~档③ 双向实时~~（暂缓，见 §5.2）
- [ ] ~~微信接入~~（已排除）

**规模**：档① 1~2 人日；档② 3~5 人日。**风险中高**：主要在中继的可用性
与安全边界；平台审核（企微需企业主体、飞书需自建应用权限）需提前确认。

---

## 6. 里程碑与排期

| 里程碑 | 内容 | 依赖 | 规模 |
|---|---|---|---|
| **M1** ✅ | 骨架落位（CI / Gitee 镜像 / 文档） | — | 已完成 |
| **M2** ✅ | 方向一 · 中文化（三语 + CI key 卡口） | 无 | 已完成 |
| **M3** ✅ | 方向二 · 提供商注册表重构（只做抽象，不加新厂商） | 无 | 已完成 |
| **M4** ✅ | 方向二 · OpenAI 适配器 + 首批四家 + 两级菜单 + GUI onboarding + setup.sh 七家 | M3 | 已完成 |
| **M5** ✅ | 方向三 · 远程网关（白名单 / 审计 / 只读硬关）+ 档① 出站通知 | M2, M4 | 已完成 |
| **M6** 🚧 | 方向三 · 档② 轮询中继（队列 + 轮询端已完成；平台收发未做） | M5 ✅ | 剩平台凭据相关部分 |
| **M7** | 发布链路（tag → Release → macOS runner 打 standalone zip） | M2 | 1~2 人日 |
| **M8** | Tier A（10.6~10.8 toolchain） | 独立 | 未估（最重） |
| ~~档③~~ | 双向实时（仅飞书） | 触发条件见 §7.2 | 10~15 人日 |

> **M6 第一批（已完成）**：`remote/relay/worker.js`（Worker + KV 队列：`/push`、
> `/pull` 取走即删、`/result`、`/outbox`、`/health`；定长比较校验令牌）+ 网关
> `--poll` 模式（只拉白名单信箱，`--max-msgs` 便于测试）。
> 验证：`scripts/test-relay.py` 对「同契约本地假中继」7/7，对**真 Worker**
> （`wrangler dev --local`）同样 7/7。
>
> **M6 剩余**：把结果真正推回手机需要平台自建应用凭据（企微 corp secret /
> 飞书 app token），且接收端要做回调验签与 AES 解密 —— 这两件都要拿真凭据联调，
> 本会话没有，也不该由我替你申请。已写进 `remote/README.md` 末尾。

> **M5 的落地方式（重要，和最初设想不同）**：一开始把远程做成核心里的
> `if ($REMOTE)` 分支，被否掉了 —— 那样本地功能会跟着远程的安全设定走。
> 最终是**分层**：
>
> | 层 | 位置 | 职责 |
> |---|---|---|
> | 核心 | `agent/claude-agent.pl` | 只加两个**通用**能力：`--tools=<a,b>`（能力收窄）与 `CLAUDE_HISTORY_DIR`（历史目录可覆盖）。零远程逻辑。 |
> | 网关 | `remote/gateway.pl` | 白名单、审计、每发送者一个常驻 agent 进程、工具集写死 `read_file,list_dir`、历史目录固定 `history-remote`、超时熔断。 |
> | 通知 | `remote/notify.pl` | 档① 出站（企微群机器人 / 飞书自定义机器人）。可独立当命令用。 |
>
> 判据是机器可检的：`scripts/check-decoupling.py` 一旦在核心里发现
> `$REMOTE*` / `remote/` / `REMOTE_TOOLS` 就红；远程工具里出现写/执行类也红。
> **删掉整个 `remote/` 目录，本地行为一字不变。**

> **M3 单独拆出来**是有意的：注册表重构只改结构、不加功能，能独立验证且
> 可回滚。等它绿了再往里塞新厂商，比"一次改到底"安全得多。

**M2 与 M3 无依赖，可并行**；M5 之前必须 M2 + M4 都完成。

---

## 7. 决策记录

### 7.1 已定（维护者确认）

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 中文化默认语言 | **跟随系统**：中文 Mac 自动出中文，上游 ja/en 行为不变 |
| 2 | 国产模型首批 | **DeepSeek + 通义千问 + Kimi + 智谱** 四家内置；其余靠 `CLAUDE_BASE_URL` 手填 |
| 3 | 远程平台范围 | **微信排除**（认证主体 + 公网回调 + 5 秒限制，性价比最低）；只做**企业微信 + 飞书** |
| 4 | 远程档位 | **做档①（出站通知）+ 档②（轮询中继）**；档③ 双向实时**暂缓** |
| 5 | 中继服务 | **接受维护**（Cloudflare Worker，免费额度足够） |
| 6 | 远程写权限 | **只读**：只开 `read_file` / `list_dir`；`write_file` / `run_shell` 远程模式硬关 |
| 7 | 本地预演 CI 的方式 | **必须执行 `ci.yml` 本身**（`python3 scripts/ci-local.py`），不许手抄检查逻辑。教训：M2 把 models.txt 改成 4 列、M4 又改成 6 列，手抄的复现脚本两次都写的是旧规则，本地"全绿"而线上红 / 险些红 |

### 7.2 待定（带触发条件）

| 项 | 何时再做 |
|---|---|
| 档③ 双向实时（仅飞书） | 档② 的 3~5 秒延迟**实际用起来不够**时再上 |
| 微信接入 | 除非出现"必须有微信"的硬需求，否则不做 |
| Tier A（10.6~10.8） | 等方向一二三落地后再评估，需要交叉编译 toolchain |

### 7.3 备忘：档①②③ 到底指什么

| 档 | 一句话 | 你能做什么 | 成本 |
|---|---|---|---|
| ① | 单向通知 | Mac 干完活 → 群里收到消息（**你不能发指令**） | 1~2 人日 |
| ② | 双向，延迟 3~5 秒 | 手机发"看看桌面那个报表" → 过几秒收到结果；**不用公网 IP** | 3~5 人日 |
| ③ | 双向实时，逐字出字 | 像真聊天；但要隧道 + 异步 ack | 10~15 人日 |

---

## 8. 工作纪律

1. **绝不修改参考用的 `ezapps` 仓库** —— 那是另一个并行会话的仓库，只读参考。
2. 本会话只在本仓库（`advisor`）内改动。
3. 每次改动收尾：`git status` 干净、提交信息符合 `TYPE(scope) 中文描述`。
4. 提交前自查：没引入 CPAN 依赖、没用到新版 perl 语法、`perl -c` 通过。
5. 版本号 / tag 一律由维护者决定，不自动打。
6. 在 Linux 开发机上**能验证的**：Perl 逻辑、shell 脚本、协议层、文档、HTTP 出站。
   **不能验证的**（须在 Mac / 真机复核）：GUI 观感、`.app` 打包、Gatekeeper、
   真实 OS 兼容性、各家 API 真实往返、平台回调与审核。
7. 动 `agent/claude-agent.pl` 核心逻辑前，先确认改动落在哪个里程碑并已开工，
   不要顺手重构。
