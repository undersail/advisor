# Advisor 开发计划

**基线**：fork 自 `watermark-hd/advisor` @ `7ab0b24`（2026-09-21）· 版本 `0.1`

---

## 0. 当前状态

| 项目 | 状态 |
|---|---|
| Tier B（10.9 ~ 10.13+）终端 + GUI | ✅ 上游已实现 |
| 双提供商（Claude / Gemini） | ✅ 已实现 |
| 加密历史 + 口令/合言葉双恢复 | ✅ 已实现 |
| 日英双语（自动跟随系统语言） | ✅ 已实现 |
| 内嵌 GUI key 注册 | ✅ 已实现 |
| standalone zip 分发 | ✅ 已实现（未签名） |
| **Tier A（10.6 ~ 10.8）** | ❌ 未开工 |
| CI / Gitee 镜像 / 文档骨架 | ✅ 本仓已落位（§1） |
| **中文支持** | ❌ 待做（方向一） |
| **OpenAI + 国产模型接口** | ❌ 待做（方向二） |
| **微信 / 企微 / 飞书远程接入** | ❌ 待做（方向三） |

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
| `agent/claude-agent.pl` → `my %S` | **91** | `key => ["日本語", "English"]`，`L()` 用 `$pair->[1]`/`[0]` 取 |
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
（`L()` 函数），剩下 91 + 59 条是纯数据替换。

**B. 语言解析改成三分支 + 回退链**

```
CLAUDE_LANG（手动覆盖，最高优先）
  → macOS AppleLocale（defaults read -g AppleLocale）
  → 匹配 ja* / zh*（zh-Hans / zh-Hant / zh_CN 都算） / 其他 → en
  → 取不到 → ja（保持上游现状，不破坏老用户）
回退链：zh 缺失的 key → en → ja。禁止出现空字符串。
```

**C. `models.txt` 扩成 4 列，保持向后兼容**

```
id|日本語|English|中文        ← 4 列（新）
id|日本語|English             ← 3 列（旧，中文回退英文）
id|日本語                     ← 2 列（更旧，原样兼容）
```
`split /\|/, $l, 4` 天然兼容列数变少。CI 卡口改为"列数 2~4"而不是"必须 3"。

**D. 文档**
- 新增 `README.zh.md`，并在 `README.md` / `README.en.md` 顶部互加语言切换链接
- 新增 `release/ReadMe_ZH.txt`（standalone zip 里的中文引导；注意包内文件名必须
  **纯 ASCII** —— 上游专门为此改过一次名，别再踩）
- `docs/` 本来就用中文写，无需改

### 3.3 任务清单

- [ ] `agent/claude-agent.pl`：`%S` 91 条补中文 + `L()` 改 hashref + `$LANGCODE` 三分支
- [ ] `agent/claude-agent.pl`：`print_help`（帮助全文，非 `%S` 条目）补中文
- [ ] `gui/advisor_gui.py`：`_S` 59 条补中文 + `L()` + `_detect_lang()` 三分支
- [ ] `gui/advisor_gui.py`：GUI 里零散硬编码文案（菜单、对话框标题）扫一遍
- [ ] `setup.sh`：`IS_EN` 改 `LANGCODE`，87 处 `msg()` 补第三语
- [ ] `models.txt`：4 列格式 + 5 个模型补中文标签
- [ ] `README.zh.md` + 语言切换链接
- [ ] `release/ReadMe_ZH.txt`（ASCII 文件名）+ `build_standalone_app.sh` 打包列表
- [ ] **CI 卡口**：三语 key 集合一致性
      （`%S` / `_S` 抽出 key 列表，比较 `ja`、`en`、`zh` 三边是否等长同集合）

### 3.4 陷阱

- `%s` 占位符数量与顺序**必须**与日英一致，否则 `sprintf` 会崩或错位
- `setup.sh` 的 heredoc 里嵌了给 `~/bin/advisor` 生成的代码，**那段是生成给
  bash 3.2 用的**，中文字面量在里面要留意引号嵌套
- 别翻译 `run_shell` 类工具名、`--flag` 名、环境变量名 —— 只翻人类可读文案
- 上游日后同步会在这 91+59 条上冲突，**同步时要整段手动合并**，不要盲信
  `git merge` 的自动结果

**规模**：约 237 条文案 + 6 处逻辑分派。**风险低**（纯数据 + 一处读取逻辑），
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
| DeepSeek 深度求索 | `https://api.deepseek.com/v1` | `deepseek-chat` / `deepseek-reasoner` |
| Moonshot Kimi | `https://api.moonshot.cn/v1` | |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | |
| 通义千问（DashScope） | `https://dashscope.aliyuncs.com/compatible-mode/v1` | |
| 豆包（火山方舟） | `https://ark.cn-beijing.volces.com/api/v3` | model 填 endpoint id |
| MiniMax | `https://api.minimax.chat/v1` | |
| 零一万物 Yi | `https://api.lingyiwanwu.com/v1` | |
| 硅基流动 SiliconFlow | `https://api.siliconflow.cn/v1` | 聚合多家，一家通吃 |

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

- [ ] 抽 `%PROVIDERS` 注册表，4 个函数改成查表
- [ ] `build_request_openai` / `parse_response_openai`（含 tool_calls ↔ tool_use 双向转换）
- [ ] `headers_openai`（`Authorization: Bearer`）+ base_url 可配置
- [ ] `models.txt` 扩列：`id|ja|en|zh|provider|base_url`（列数向后兼容）
- [ ] 多 key 存储（按 provider）
- [ ] 工具能力降级（`notools` 标记 → 纯对话）
- [ ] `reasoning_content` 剥离
- [ ] 两级模型菜单（终端 + GUI + bash 补全三处同步）
- [ ] GUI onboarding 支持新 provider
- [ ] **CI 卡口**：`models.txt` 里声明的 provider 必须都在 `%PROVIDERS` 里存在
- [ ] 真实连通性手测（需各厂商 key，本地做，不进 CI）

**规模**：注册表重构 1~2 人日；openai 适配器 + 双向转换 2~3 人日；
菜单两级化与 GUI 同步 2 人日；能力降级与坑 2~3 人日。**合计约 7~10 人日**。
**风险中**：主要风险在"各家行为不一致"，必须逐家手测，CI 帮不上。

---

## 5. 方向三 · 微信 / 企业微信 / 飞书远程接入

### 5.1 先说结论：三件事难度差一个数量级，别当一件事做

advisor 现在是**单机单用户**的 CLI + GUI，没有任何网络服务端。远程接入实质是
**加一个网关角色**，而三个平台的接入能力完全不同：

| 能力 | 微信（公众号/客服） | 企业微信 | 飞书 |
|---|---|---|---|
| 纯出站推送（不需要公网） | ❌ 无此能力 | ✅ 群机器人 webhook | ✅ 自定义机器人 webhook |
| 接收消息 | 需公网 HTTPS 回调 + 签名校验 + **5 秒内响应**（超时重试 3 次） | 应用消息需公网回调 URL / 可信 IP | 自建应用支持回调，也支持**长连接（WebSocket，不用公网 IP）** |
| 身份获取 | openid | userid（组织内确定） | open_id（组织内确定） |
| 零 CPAN Perl 可实现性 | 中（要写 HTTP server + 签名） | 中 | 实时双向：**差**（wss 客户端手写不现实） |

### 5.2 三档方案（按投入排序，建议按序推进）

#### ① 出站通知（最易，约 1~2 人日）
企业微信 / 飞书群机器人都是"POST 一个 JSON 到 webhook URL"。纯 curl 即可，
零依赖可行。用途：任务完成通知、错误告警、长任务进度。
**限制：只能发不能收，不是"远程对话"。**
价值在于**先跑通链路与凭据**，且即使后面做不成双向，这个也一直有用。

#### ② 轮询式中继（不需要公网 IP，约 3~5 人日）
```
老 Mac（NAT 后）  ──轮询──>  中继（Cloudflare Worker / VPS）  <──回调──  企微/飞书
       └──────────── POST 结果 ────────┘
```
- 老 Mac **主动轮询**取待处理消息，处理完 POST 回结果 → 无需公网入站、无需端口映射
- 平台回调仍要有公网 URL，但落在**中继**上（Cloudflare Worker 免费额度够）
- 代价：延迟（3~5 秒轮询间隔）、需维护一个中继服务、多一处信任边界
- **这是"没有公网 IP 也能双向对话"的现实解**

#### ③ 双向实时（体验最好，约 2~3 周）
- 飞书自建应用的**长连接模式**理论上不用公网 IP，但 wss 客户端在零 CPAN Perl 里
  手写 RFC6455 + TLS **不现实** → 若不破坏"零 CPAN"约束，只能走回调 + 隧道
- 可行实现：老 Mac 上跑极小 HTTP server（Perl `IO::Socket::INET` 零依赖可写，
  或 Python 标准库 `http.server`）+ Cloudflare Tunnel / ngrok / frp 打出公网 HTTPS
- 微信的 **5 秒响应上限**是硬约束：必须"立即 ack + 异步回推"，不能同步等模型
  出完整答案（模型一轮就要几秒到几十秒）

### 5.3 🔴 安全模型必须重做（这一条最重要，不做就不要上远程）

现在 `write_file` / `run_shell` 靠**本地 y/n 按键确认**（见设计文档 §4.1）。
远程模式下**没有本地用户按确认键** → 确认链断裂 → 等于把一台能执行任意
shell 的机器暴露给"任何能给这个账号发消息的人"。

必须做到：

1. **远程模式默认只读**：只放 `read_file` / `list_dir`；
   `write_file` / `run_shell` 默认**关闭**，需显式配置白名单开启
2. **强烈建议远程永不开 `run_shell`** —— 读 + 受限目录写已经是很大的便利，
   执行命令的风险/收益比太差
3. **发送者白名单**：`userid` / `open_id` 白名单，非白名单**直接丢弃**并记日志
   （不要回"无权限"—— 会暴露机器人存在）
4. **确认改走聊天回复**：若真开了写操作，确认提示发到聊天里，用户回 `y`，
   且提示里必须带**完整 diff / 完整命令**，让人看清再点
5. **审计日志**：谁、何时、让 agent 做了什么操作，落 `~/.claude-agent/audit.log`
   （现有 `session.log` 扩展即可），只追加、不覆盖
6. **历史加密在远程模式下仍要生效**（口令由谁保管要想清楚；建议远程模式用
   独立的口令/独立的历史目录）

### 5.4 架构上的好消息

`emit_*` 抽象层（设计文档 §2）本来就是为"多前端"设计的。远程网关完全可以
**复用 `--gui` 的 JSON 行协议**，加一个 `--rpc` 模式当作第三前端：
智能体核心一行不用改。这是已实现的设计红利，务必利用，不要另起一套。

### 5.5 任务清单

- [ ] `--rpc` 模式：复用 JSON 行协议，作为第三前端
- [ ] 网关进程：接收平台消息 → 转 `--rpc` → 回推结果
- [ ] 档① 出站通知（企微群机器人 + 飞书自定义机器人）
- [ ] 档② 轮询中继（Worker + 老 Mac 轮询端）
- [ ] 档③ 择一平台做双向（建议**先飞书**：文档最全、回调机制最清晰；
      微信 5 秒限制最麻烦，放最后）
- [ ] 只读工具集 + 白名单 + 审计日志（**先于**任何写/执行能力上线）
- [ ] 远程模式的口令与历史目录隔离

**规模**：档① 1~2 人日；档② 3~5 人日；档③ 单平台 10~15 人日。
**风险高**：平台审核（公众号要认证主体）、5 秒限制、无公网 IP、安全边界。

---

## 6. 里程碑与排期

| 里程碑 | 内容 | 依赖 | 规模 |
|---|---|---|---|
| **M1** ✅ | 骨架落位（CI / Gitee 镜像 / 文档） | — | 已完成 |
| **M2** | 方向一 · 中文化（三语 + CI key 卡口） | 无 | 3~5 人日 |
| **M3** | 方向二 · 提供商注册表重构（先只做抽象，不加新厂商） | 无 | 1~2 人日 |
| **M4** | 方向二 · OpenAI 适配器 + 国产 8 家接入 + 两级菜单 | M3 | 6~8 人日 |
| **M5** | 方向三 · `--rpc` 模式 + 只读安全模型 + 档① 出站通知 | M2, M4 | 3~4 人日 |
| **M6** | 方向三 · 档② 轮询中继（双向对话可用） | M5 | 3~5 人日 |
| **M7** | 方向三 · 档③ 单平台双向实时（建议飞书） | M6 | 10~15 人日 |
| **M8** | 发布链路（tag → Release → macOS runner 打 standalone zip） | M2 | 1~2 人日 |
| **M9** | Tier A（10.6~10.8 toolchain） | 独立 | 未估（最重） |

> **M3 单独拆出来**是有意的：注册表重构只改结构、不加功能，能独立验证且
> 可回滚。等它绿了再往里塞新厂商，比"一次改到底"安全得多。

---

## 7. 待确认的决策点（需维护者拍板）

1. **中文化的默认语言**：中文 Mac 上自动出中文（跟随系统），还是不管系统
   一律默认中文？→ 建议**跟随系统**，上游 ja/en 行为不变。
2. **国产模型的首批清单**：上面 8 家里先上哪几家？→ 建议先 **DeepSeek + 通义
   + Kimi + 智谱** 四家（覆盖面最广），其余靠 base_url 手填即可用。
3. **远程接入的目标档位**：能接受"异步任务型"（发指令、稍后收结果）就只做
   档①②，省 10~15 人日；一定要"实时对话"才做档③。
4. **愿不愿意为远程维护一个中继服务**（Cloudflare Worker / VPS）？
   不愿意 → 档②做不了，只剩"有公网 IP"或"只做出站通知"两条路。
5. **微信是否必须**：公众号需要**已认证主体**、需公网回调、5 秒限制最麻烦。
   如果企微/飞书够用，建议**砍掉微信**，省下的力气放到体验上。
6. **远程模式是否允许写文件**：我强烈建议**只读**。放开写就必须接受
   "聊天账号被盗 = 文件被改"的风险。

---

## 8. 工作纪律

1. **绝不修改 `ezapps`** —— 那是另一个并行会话的仓库，只读参考。
2. 本会话只在 `the repo` 内改动。
3. 每次改动收尾：`git status` 干净、提交信息符合 `TYPE(scope) 中文描述`。
4. 提交前自查：没引入 CPAN 依赖、没用到新版 perl 语法、`perl -c` 通过。
5. 版本号 / tag 一律由维护者决定，不自动打。
6. 在 Linux 开发机上**能验证的**：Perl 逻辑、shell 脚本、协议层、文档、HTTP 出站。
   **不能验证的**（须在 Mac / 真机复核）：GUI 观感、`.app` 打包、Gatekeeper、
   真实 OS 兼容性、各家 API 真实往返、平台回调与审核。
7. 动 `agent/claude-agent.pl` 核心逻辑前，先确认改动落在哪个里程碑并已开工，
   不要顺手重构。
