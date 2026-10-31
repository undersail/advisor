# Advisor 开发计划

**基线**：fork 自 `watermark-hd/advisor` @ `7ab0b24`（2026-09-21）· 版本 `0.1`

---

## 0. 当前状态

| 项目 | 状态 |
|---|---|
| Tier B（10.9 ~ 10.13+）终端 + GUI | ✅ 上游已实现 |
| 双提供商（Claude / Gemini） | ✅ 上游已实现 |
| **7 提供商（+ OpenAI / DeepSeek / 通义千问 / Kimi / GLM）** | ✅ 本 fork 已实现（M4）|
| **中文化（跟随系统语言，三语 147 + 65 条）** | ✅ 本 fork 已实现（M2）|
| 加密历史 + 口令/合言葉双恢复 | ✅ 已实现 |
| 日英双语（自动跟随系统语言） | ✅ 已实现 |
| 内嵌 GUI key 注册（7 家下拉） | ✅ 已实现（M4-GUI）|
| 两级模型菜单（终端数字 / GUI `/model <id>`） | ✅ 已实现（M4）|
| **远程只读网关**（白名单 / 审计 / 工具写死只读） | ✅ 本 fork 已实现（M5）|
| **档① 出站通知**（企微群机器人 / 飞书自定义机器人） | ✅ 本 fork 已实现（M5）|
| ~~档② 轮询中继（Cloudflare Worker + Durable Object）~~ | ❌ **已移除**（长连接更轻，见下条；CF 维护面与部署成本不划算）|
| **平台端收发**（企微/飞书回调 → 派活 → 回复推回手机） | ✅ 本 fork 已实现（`remote/platform.pl`，需公网域名）|
| **企微智能机器人长连接**（API 模式 · BotID + Secret；**不用公网域名、不用 Cloudflare**） | ✅ 本 fork 已实现（`remote/wecom-ws.pl`）|
| **发布链路**（tag → macOS 打包 → Release） | ✅ 本 fork 已实现（M7）|
| standalone zip 分发 | ✅ 已实现（未签名，首次启动需右键打开）|
| CI / Gitee 镜像 / 文档骨架 | ✅ 本仓已落位（§1）|
| **Gitee 反拉保护**（会覆盖对方提交就中止 + 反拉流程） | ✅ 本仓已实现（§8.2）|
| **macOS 兼容卡口**（bash 3.2 两类坑 + GUI 自递归 + .app 弹窗） | ✅ 已实现（`check-shell-var-glue.py` / `test-gui-recursion.py` / `test-setup-py3.py`）|
| **交互模式（default / accept-edits / bypass）** | ✅ 已实现（M0~M5）；1 处偏差待定，见设计文档 §10.13 偏差 1 |
| **Tier A（10.6 ~ 10.8）** | ❌ 未开工 |
| ~~微信接入~~ | 已排除（认证主体 + 公网回调 + 5 秒硬超时）|

> 版本号只有一个来源：仓库根目录的 `VERSION`。`--version`、`setup.sh` 生成的
> Info.plist、发布 zip 名、Release 的 tag 全部跟它走；`scripts/check-version.py`
> 在 CI 里守着这条，写死版本号会红。

### 0.1 质量门现状（本机实际执行，2026-10-27）

| 项 | 现状 |
|---|---|
| 卡口脚本 | 6 个：`check-secrets` / `check-i18n` / `check-models` / `check-version` / `check-decoupling` / `check-shell-var-glue` |
| 测试脚本 | 22 个，合计 **612 项**（modes 60 · **platform 42** · release-workflow 26 · audit-commands 27 · setup-py3 35 · gui-keyenv 11 · remote-notify 22 · **remote 24** · **gateway-write 42** · **mirror-drift 21** · gui-modes 25 · key-policy 25 · hooks 10 · gui-recursion 8 · **setup-perl-check 8** · **wecom-ws 59** · **gui-remote 44** · **wss-tls 9** · **memory 34** · **skill 19** · **history-storage 23** · **session-continue 21**） |
| CI | `ci.yml` **3 个 job（gates 19 / core 11 / io 12 步，共 42 步）× 2 平台**（ubuntu + macOS）：`gates` 静态卡口 / `core` 慢测·核心 / `io` 慢测·输入输出；`timeout-minutes` 按平台给数值（ubuntu 25 / macOS 90） |
| 镜像同步 | `sync-gitee.yml` 带反拉保护 + `force` 逃生门（§8.2） |
| 提交门 | `core.hooksPath = scripts/hooks`，提交前跑泄漏 + 换行 + 调试残留 |
| 文案/注册表 | Perl `%S` 147 · GUI `_S` 123 · `setup.sh msg()` 52 · 厂商 7 · `models.txt` 12 条（`check-version.py` 守着） |
| 泄漏 | 70 个已跟踪文件 + 未跟踪文件 + 全历史，0 命中 |

审计记录：`docs/audits/audit_advisor_v0.2.1.md`（v0.2.1 快照）、`docs/audits/audit_advisor_v0.2.1_r2.md`（之后的第二轮）。

## 1. 本仓已铺好的工程骨架

| 文件 | 作用 |
|---|---|
| `.editorconfig` | utf-8 / LF / 2 空格（`.pl` `.py` 为 4） |
| `.github/workflows/ci.yml` | 3 个 job（`gates` / `core` / `io`）共 42 步：perl -c（含 remote 三个）、`--version` 冒烟、全量 py_compile、全仓 bash -n、**7 个卡口脚本**、**22 个测试脚本**、泄漏 + 换行检查；矩阵 ubuntu-latest + **macos-15-intel** |
| `.github/workflows/sync-gitee.yml` | main + tag → `gitee.com/undersail/advisor` 镜像；**推之前先跑反拉保护**（会覆盖对方提交就中止，见 §8.2）；凭据 `oauth2:`→`undersail:` 自动回退 |
| `docs/design_doc_advisor.md` | 架构、JSON 行协议、加密密钥层级、已知限制、改动规则 |
| `docs/releases/` | 发布说明，文件名 = tag 名 |
| `docs/audits/` | 审计记录，按轮次编号（`_r2` = 第二轮），当前状态见最新那份 |

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
| `agent/claude-agent.pl` → `my %S` | **202**（交互模式新增 31 条，模型菜单标注新增 2 条）| 原为 `key => ["日本語", "English"]`；已改为 `{ ja => , en => , zh => }` |
| `gui/advisor_gui.py` → `_S` | **123** | 同上，`L()` 里 `ja, en = _S[key]` |
| `setup.sh` → `msg()` | **87** 处调用 | `IS_EN=0/1` 二元 case |
| `models.txt` | 5 行 | `id|<各语言标签>|English label` |
| 文档 | README.md(中文，默认) / README.en.md / release/ReadMe_ZH.txt / ReadMe_EN.txt | 中文为主、英文为辅 |

**关键缺陷**：语言判定是**二元的**，不是"支持 ja/en"这么简单 ——
`$LANGCODE eq 'en' ? $pair->[1] : $pair->[0]`，即**非 en 一律出日文**；
GUI 侧 `_detect_lang()` 是"非 `ja*` 一律出英文"。所以**今天一个中文用户
在 GUI 上看到英文、在终端上看到日文**。中文化必须先把二元判断改成三分支。

### 3.2 设计决定

**A. `%S` / `_S` 从 arrayref 改成 hashref**

```perl
# 现在（ja 分支的文案略，下同）
need_key => ["<ja 文案>\n", "Please set %s\n"],
# 改成
need_key => { ja => '<ja 文案>', en => 'Please set %s', zh => '请设置 %s' },
```

理由：加语言不用改索引、不会错位。改动面其实很小 —— **读取点各自只有 1 处**
（`L()` 函数），剩下 147 + 65 条是纯数据替换。

**B. 语言解析改成三分支 + 回退链**

```
CLAUDE_LANG（手动覆盖，最高优先）
  → macOS AppleLocale（defaults read -g AppleLocale）
  → 匹配 ja* / zh*（zh-Hans / zh-Hant / zh_CN 都算） / 其他 → en
  → 取不到 → zh（**项目口径：中文为默认**，见「语言政策」）
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
- 文档语言口径：**中文为主、英文为辅**（`README.md` 是中文，`README.en.md` 是英文；
  日文版 README 与 `release/ReadMe_JP.txt` 已删除，新内容不再写日文）
- 新增 `release/ReadMe_ZH.txt`（standalone zip 里的中文引导；注意包内文件名必须
  **纯 ASCII** —— 上游专门为此改过一次名，别再踩）
- `docs/` 本来就用中文写，无需改

### 3.3 任务清单

- [x] `agent/claude-agent.pl`：`L()` 改 hashref/数组双支持 + `$LANGCODE` 三分支（zh→en→ja 回退）
- [x] `agent/claude-agent.pl`：`%S` 补中文（现 202 条，随功能增长）
- [x] `agent/claude-agent.pl`：`print_help`（单引号 heredoc，非 `%S` 条目）另起中文分支
- [x] `gui/advisor_gui.py`：`L()` 改 dict/tuple 双支持 + `_detect_lang()` 三分支
- [x] `gui/advisor_gui.py`：`_S` 补中文（现 65 条）
- [x] `gui/advisor_gui.py`：硬编码文案扫一遍 —— 主题名原只有 `label`/`label_en`，zh 下会显示日文，已加 `label_zh` 并改 `theme_label()`
- [x] `setup.sh`：`IS_EN` 改为由 `LANGCODE` 派生；`msg()` 实际 52 条（三语各 52）补中文，未命中落回原 en/ja
- [x] `models.txt`：4 列格式 + 5 个模型补中文标签（Perl 解析同步改限 4 段选列）
- [x] 两份 README 互链（中文 / 英文），语言说明按「中文为主、英文为辅」重写
- [x] `release/ReadMe_ZH.txt`（ASCII 文件名）+ `build_standalone_app.sh` 打包列表
- [x] **CI 卡口**：`scripts/check-i18n.py` —— 抽出 `%S` / `_S` 的全部 key，比较同一 key 的 `ja`/`en`/`zh` 占位符个数是否一致（不一致时 sprintf/format 会崩或错位）；未译条目只报告不判死，收尾阶段可加 `--strict`。已接入 CI（步骤名「三语文案占位符卡口」）

### 3.4 陷阱

- `%s` 占位符数量与顺序**必须**与日英一致，否则 `sprintf` 会崩或错位
- `setup.sh` 的 heredoc 里嵌了给 `~/bin/advisor` 生成的代码，**那段是生成给
  bash 3.2 用的**，中文字面量在里面要留意引号嵌套
- 别翻译 `run_shell` 类工具名、`--flag` 名、环境变量名 —— 只翻人类可读文案
- 上游日后同步会在这 147+65 条上冲突，**同步时要整段手动合并**，不要盲信
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
- [x] **CI 卡口**：`scripts/check-models.py` —— provider 必须在注册表里、base_url 型必须有 base_url、ID 不重复、flags 词合法（已接入 CI，步骤名「models.txt 与注册表一致性」）
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

#### ~~档② 轮询式中继~~ ❌ 已实现后移除

曾用「本机轮询 + 云端队列」解决 NAT 后收不到回调的问题，后来发现企微「智能机器人 ·
API 模式 · 使用长连接」用更轻的方式解决同一件事（本机连出去，凭据只有 BotID + Secret，
不需要任何云资源，延迟还是实时的），于是整段删除。历史代码可从 git 取回
（`git log --diff-filter=D -- remote/relay`）。

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

- [x] `--rpc` 模式：复用 JSON 行协议，作为第三前端
- [x] 网关进程：接收平台消息 → 转 `--rpc` → 回推结果
- [x] 档① 出站通知（企微群机器人 + 飞书自定义机器人）
- [x] ~~档② 轮询中继（Cloudflare Worker + 老 Mac 轮询端）~~ → 已由企微长连接取代，代码已删
- [ ] 飞书长连接（方案已记录在 `design_doc` §4.5.2，**暂不实现**）
- [x] 只读工具集 + 白名单 + 审计日志（**先于**任何远程能力上线）
- [x] 远程模式的独立口令与独立历史目录
- [ ] ~~档③ 双向实时~~（暂缓，见 §5.2）
- [ ] ~~微信接入~~（已排除）

**规模**：档① 1~2 人日；~~档② 3~5 人日（已删）~~。**风险中低**：不需要再维护中继服务；主要成本在
与安全边界；平台审核（企微需企业主体、飞书需自建应用权限）需提前确认。

---

## 6. 里程碑与排期

| 里程碑 | 内容 | 依赖 | 规模 |
|---|---|---|---|
| **M1** ✅ | 骨架落位（CI / Gitee 镜像 / 文档） | — | 已完成 |
| **M2** ✅ | 方向一 · 中文化（三语 + CI key 卡口） | 无 | 已完成 |
| **M3** ✅ | 方向二 · 提供商注册表重构（只做抽象，不加新厂商） | 无 | 已完成 |
| **M4** ✅ | 方向二 · OpenAI 适配器 + 首批四家 + 两级菜单 + GUI onboarding + setup.sh 七家 | M3 | 已完成 |
| **M5** ✅ | 方向三 · 远程网关（白名单 / 审计 / 权限档位）+ 档① 出站通知 | M2, M4 | 已完成 |
| **M6** ✅→🗑 | 方向三 · 档② 轮询中继（曾全通，后因长连接更轻而整段删除） | M5 ✅ | 已由 `remote/wecom-ws.pl` 取代 |
| **M7** ✅ | 发布链路（tag → Release → macOS runner 打 standalone zip） | M2 | 已完成 |
| **M8** | Tier A（10.6~10.8 toolchain） | 独立 | 未估（最重） |
| ~~档③~~ | 双向实时（仅飞书） | 触发条件见 §7.2 | 10~15 人日 |

> **M7（已完成）**：`.github/workflows/release.yml` —— tag `v*` 触发，在
> `macos-15-intel`（Intel 池；`macos-latest` 现在是 macOS 26 arm64，容量紧张时领不到机器）
> 上用 venv + py2app 打 standalone 包，`gh release create` 建
> Release，正文取 `docs/releases/<tag>.md`（缺失则警告并回退自动生成）。
> 产物先过一次结构校验（内嵌 `claude-agent.pl` / `models.txt` / `providers.txt`
> 与中文说明缺一不可），再算 SHA256。另有 `workflow_dispatch` 可手动演练
> （只构建存 artifact，不发布）。
>
> 本地能验的都验了：`scripts/test-release-workflow.py` 从 `release.yml` 里
> **取出 `run:` 原文真跑**（版本解析 v0.2.0→0.2.0、v1.10.3 不被截断；产物
> 校验的正例通过、缺文件必红），17/17。**py2app 打包与 `gh release create`
> 只能在 macOS runner 上验** —— 这一层本会话无法验证，首次真发布见分晓。

> **M6（历史，代码已删）**：曾用 Worker + 队列做轮询中继，全通后因「长连接更轻」整段移除，
> 由 `remote/wecom-ws.pl` 取代（协议与重连由 `scripts/test-wecom-ws.py` 覆盖）。

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

### 6.1 交互模式（已实现）

设计见 `docs/design_doc_advisor.md` §10。三个已定的关键取舍（不是默认值，是维护者拍的）：

1. **三档都做**：`default` / `accept-edits` / `bypass`；`accept-edits` 只放宽写文件，命令照旧确认。
2. **危险命令改为弹确认**（不硬拒）：三档通用；因此必须配「无人应答 fail-closed」——
   60 秒超时即拒绝、无 tty 无 GUI 直接拒绝，绝不把「没人回答」当同意，也绝不挂死会话。
3. **可写目录是会话级白名单、可多个**：`--allow-write`（可重复）/ `CLAUDE_ALLOW_WRITE`（冒号分隔）/
   `/allow-write` 会话内增删查；`write_file` 与命令写目标共用同一份列表；
   `~/.claude-agent`、`/etc`、`/usr` 等**即使显式加入也不放行**。

开发顺序 M0 → M5：超时与输出上限 → 模式骨架 → 危险命令与 fail-closed → 可写范围 →
自动批准 + 审计 + 可见性 → 会话内切换 + 测试卡口。

## 7. 决策记录

### 7.1 已定（维护者确认）

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 中文化默认语言 | **跟随系统**：中文 Mac 自动出中文，上游 ja/en 行为不变 |
| 2 | 国产模型首批 | **DeepSeek + 通义千问 + Kimi + 智谱** 四家内置；其余靠 `CLAUDE_BASE_URL` 手填 |
| 3 | 远程平台范围 | **微信排除**（认证主体 + 公网回调 + 5 秒限制，性价比最低）；只做**企业微信 + 飞书** |
| 4 | 远程档位 | **做档①（出站通知）+ 企微长连接**；CF 中继已删；飞书长连接暂缓 |
| 5 | 中继服务 | **不再需要**（长连接由本机连出，没有中继要维护） |
| 6 | 远程写权限 | **只读**：只开 `read_file` / `list_dir`；`write_file` / `run_shell` 远程模式硬关 |
| 7 | 本地预演 CI 的方式 | **必须执行 `ci.yml` 本身**（`python3 scripts/ci-local.py`），不许手抄检查逻辑。教训：M2 把 models.txt 改成 4 列、M4 又改成 6 列，手抄的复现脚本两次都写的是旧规则，本地"全绿"而线上红 / 险些红 |
| 8 | 交互模式档位 | **三档都做**：`default` / `accept-edits` / `bypass`；`accept-edits` 只放宽写文件，`run_shell` 仍逐次确认 |
| 9 | bypass 下危险命令 | **弹确认**（不硬拒）+ 无人应答 fail-closed（60s 超时即拒绝、无 tty 无 GUI 直接拒绝） |
| 10 | 可写范围 | **会话级多目录白名单**：`--allow-write`（可重复）/ `CLAUDE_ALLOW_WRITE`（冒号分隔）/ `/allow-write`；`~/.claude-agent`、`/etc`、`/usr` 等即使显式加入也不放行 |

### 7.2 待定（带触发条件）

| 项 | 何时再做 |
|---|---|
| 飞书长连接 | 企微长连接跑稳、且确实需要飞书无公网接入时再做（协议要照 SDK 反向实现） |
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

2. 本会话只在本仓库（`advisor`）内改动。
3. 每次改动收尾：`git status` 干净、提交信息符合 `TYPE(scope) 中文描述`。
4. 提交前自查：没引入 CPAN 依赖、没用到新版 perl 语法、`perl -c` 通过。
5. 版本号 / tag 一律由维护者决定，不自动打。
6. 在 Linux 开发机上**能验证的**：Perl 逻辑、shell 脚本、协议层、文档、HTTP 出站。
   **不能验证的**（须在 Mac / 真机复核）：GUI 观感、`.app` 打包、Gatekeeper、
   真实 OS 兼容性、各家 API 真实往返、平台回调与审核。
7. 动 `agent/claude-agent.pl` 核心逻辑前，先确认改动落在哪个里程碑并已开工，
   不要顺手重构。
8. **Linux 绿、macOS 红一律先当成本仓库的真 bug**（哪怕看起来像测试问题）。
   已经踩出来的有：bash 3.2 把全角字符算进变量名、`case … continue ;;` 语法错误
   （放进 hook 等于 hook 从不执行）、`osascript display dialog` 无超时永久挂住、
   测试子进程不给 stdin 导致 `read` 阻塞。卡口见 `scripts/check-shell-var-glue.py`。
9. **新增脚本必须同时进 CI**，否则它只是"本地手工跑过一次"。审计方法：把
   `scripts/` 清单与 `ci.yml` 的引用做差集，差集里的每个文件都要有理由。

### 8.1 提交前卡口（git hook）

```bash
bash scripts/install-git-hooks.sh     # 每个克隆做一次（core.hooksPath → scripts/hooks）
```

装上之后 `git commit` 会自动拦：本机家目录等泄漏、疑似 API key、CRLF、调试残留。
确需跳过用 `git commit --no-verify`。hook 自身有测试（`scripts/test-hooks.py`
在临时仓库里真提交一次），CI 会跑，避免「装了等于没装」。

### 8.2 Gitee 镜像的写入约定（反拉保护）

GitHub 是唯一写入源，Gitee 是**只读镜像**（`--all --force` + `--tags --force`）。

如果有人直接在 Gitee 上提交/tag，下次同步会覆盖它们 —— 所以同步前会先跑
`scripts/check-mirror-drift.sh`：只要发现「推上去会覆盖镜像侧独有的提交或同名 tag」，
就**中止同步**并打印反拉步骤（不会静默丢弃）。

反拉回来：

```bash
git remote add gitee https://gitee.com/undersail/advisor.git   # 只需一次
git fetch gitee
git log --oneline main..gitee/main        # 看 Gitee 上多了什么
git cherry-pick <需要的提交>               # 或 git merge gitee/main
git push origin main                      # 再同步回去
```

确认那些改动可以丢弃时，在 Actions 里手动触发 Sync to Gitee Mirror 并勾选 `force`。

判定表：

| 情况 | 行为 |
|---|---|
| 镜像同名分支有未进入本地的提交 | 中止同步，打印反拉步骤 |
| 镜像同名 tag 指向本地历史之外 | 中止同步 |
| 已 cherry-pick（补丁等价，按 patch-id 判） | 放行 —— 否则按上面这套流程修完，同步反而永久卡住 |
| 镜像独有的分支（`--all` 不会删除）/ 不同名 tag / 镜像滞后 | 只提示或放行，不卡死 |
| 读不到镜像 | 中止，不盲目强推 |

测试 `scripts/test-mirror-drift.py`（20 项，本地裸仓模拟 Gitee；其中一项盯「工作流要在推 tag 时也同步」）。
诊断开关：`ADVISOR_MIRROR_DEBUG=1` 会把探测到的分支/tag 名单打到 stderr。

### 8.3 本机预演要跑两种环境

`python3 scripts/ci-local.py` 用的是**当前 shell 环境**；runner 是干净环境。
两者不一致时会出现「本机绿、CI 红」，实测踩过一次（测试把「范围外」的目录
建在 `/tmp` 下，而本机 `TMPDIR` 指向别处，云端 `/tmp` 恰好是可写根）。

因此本地预演要跑两遍：

```bash
python3 scripts/ci-local.py              # 常规
python3 scripts/ci-local.py --pristine   # 干净环境（最小 PATH、临时 HOME、无 TMPDIR）
```

新写的测试**不得依赖宿主的 `TMPDIR`/`HOME`/`PATH` 具体取值**：需要环境的
地方自己显式设定（测试自己指定 `TMPDIR`、`cwd`，别用 `tempfile` 的宿主默认值）。

## 语言政策

- **中文为默认语言**：界面文字、终端提示、`setup.sh` 消息、文档、README，默认都写中文。
- **英文为辅**：`README.en.md`、`release/ReadMe_EN.txt` 与代码里的 `en` 文案表是英文对应物，
  新增条目要同时写中文和英文。
- **新内容不写日文**：日文版 README 与 `release/ReadMe_JP.txt` 已删除。代码里已有的日文文案
  （`%S` / `_S` 里的 `ja` 列）作为历史保留，`check-i18n.py` 仍校验其占位符一致性，但**不再新增**。
- **运行时语言的判定顺序**：`CLAUDE_LANG`（`zh`/`en`/`ja`）→ macOS 系统语言
  （`defaults read -g AppleLocale`）→ 都取不到就用**中文**。

## 12. 长期记忆与技能（v0.2.5）

设计见 `docs/design_doc_advisor.md` §4.7。落地清单：

- [x] `agent/claude-agent.pl`：
  - 新增 `memory_path()` / `skills_dir()`（`CLAUDE_MEMORY_FILE` / `CLAUDE_SKILLS_DIR` 可覆盖）
  - 新增 `read_memory()`（带上限截断）、`read_memory_raw()`、`memory_add()`、
    `memory_remove_line()`、`memory_clear()`、`print_memory()`
  - 新增 `skills_list()` / `skill_entry()` / `print_skills()`（`<名>/SKILL.md` 与 `<名>.md` 都收）
  - `system_prompt()` 追加两段：记忆全文（含「当前对话优先」与截断说明）、技能清单
  - 新命令 `/memory`（查看 / `rm <n>` / `clear`）、`/remember <事实>`、`/skills`
  - 新工具 `remember`：**任何模式都先 confirmation**，用户回 y 才写
  - `--no-config`（远程、嵌入式）里 `/memory` `/remember` `/skills` 一并拒绝
  - `%S` 新增 18 条（中文 + 英文；按语言政策不再加日文，`ja` 走回退到 `en`）
- [x] `scripts/agent_harness.py`：两个测试共用的假端点 + `--rpc` 驱动（含取 system prompt / tool_result）
- [x] `scripts/test-memory.py` **34 项**、`scripts/test-skill.py` **19 项**，都已进 CI
- [x] 文档：`user_manual.md` §6（记忆与技能）、§8 数据位置表、§3 命令表；
  `design_doc_advisor.md` §4.7；两份 README 的功能与限制
- [ ] 真机验收（用户）：记忆在重启后仍生效；放一个真技能（比如备份流程）让模型按它做一遍

## 13. 历史存储默认值反转（v0.2.5）

设计见 `docs/design_doc_advisor.md` §5。

- [x] 默认改为**明文**保存：`history/<时间戳>.json`，`0600`，目录 `0700`，启动不问口令
- [x] `--encrypt-history` / `CLAUDE_ENCRYPT_HISTORY=1` 回到口令加密（`*.json.enc` + `key.enc`）
- [x] **不悄悄降级**：存在 `key.enc`（或旧 `.check`）时仍走口令流程
- [x] **孤儿 `.json.enc` 不拖人下水**：无 `key.enc` 的加密文件不改变模式，`--list-history` 里说明怎么打开
- [x] 混合格式：`history_files()` 认 `.json` 与 `.json.enc`，`hist_decrypt()` 按后缀决定解不解
- [x] 明文模式下 `--change-passphrase` / `--set-recovery` 给明确说明（不是崩，也不假装成功）
- [x] `%S` 新增 5 条（中/英），`--help` 增 `--encrypt-history` 与 `CLAUDE_ENCRYPT_HISTORY`（中/日）
- [x] `scripts/test-history-storage.py` **23 项**，已进 CI
- [ ] 真机验收（用户）：默认启动不问口令；`--list-history` 能看到旧会话；`--encrypt-history` 能设口令

## 14. bypass 模式口径调整（v0.2.5）

设计见 `docs/design_doc_advisor.md` §10.2.1。

- [x] `bypass` 下 `write_file` 不再受可写范围限制（永久禁止目录仍直接拒绝）
- [x] `bypass` 下 `run_shell`：新增 `is_fs_mutation()`，文件/目录操作（`rm`/`mv`/`cp`/`chmod`/
      `tar`/`unzip`/`rsync`/`dd`/`find -delete`/`git clean` …）确认；其余不问
- [x] 白名单判定只在 `accept-edits` 生效（`default` 本来就问，`bypass` 不再看名单）
- [x] 只认命令名，参数里的字样不误判（`echo rm -rf nothing` 不问）
- [x] 审计新增 `confirmed_fs_op` / `refused_fs_op`
- [x] `%S` 新增 2 条（`confirm_fs_op` / `fs_op_refused`）；bypass 的模式说明与切换警告文案重写
- [x] `test-modes` 两个用例按新语义重写（范围外直接写成功、`cp`/`mv`/`mkdir` 必问、`/etc` 仍拒）
- [ ] 真机验收（用户）：`--mode=bypass` 下写白名单外文件不提示；`rm -rf` 仍提示

## 15. 会话接续与找回（v0.2.5）

设计见 `docs/design_doc_advisor.md` §5.2（参考 Hermes 的 `--continue` / 会话检索口径）。

- [x] `--continue` / `-c`：接着最近一场，**不弹菜单、不读 STDIN**，写回同一个文件
- [x] `--continue <名字>` + `--name <名字>`：按名字分线（名字存历史 JSON 的 `name` 字段）
- [x] `--search <词>`：全文检索，命中处按**字符**截前后 40 字；最多 20 场；解不开的计数说明
- [x] `--list-history` 显示 `[名字]`
- [x] 远程网关：按发送者 `remote:<md5前12位>` 传 `--name` / `--continue`，服务重启后同一人接回自己那场
      （原始 ID 不进键；审计 `from=` 保持原样）
- [x] **argv 统一按 UTF-8 解码**（`--search 报价` 曾变成 `æ¥ä»·`）
- [x] `%S` 172 → **178**（新增 6 条）
- [x] 测试：新增 `scripts/test-session-continue.py` **21 项**；`test-gateway-write` 42 → **52 项**
- [ ] 真机验收（用户）：`--continue` 直接接上；`--search 中文` 不乱码；手机重启服务后仍接着上一场

## 16. 会话内命令与 GUI 入口（v0.2.5）

- [x] `/name <名字>`：改名并**立刻落盘**（不等本轮结束），下次 `--continue 名字` 能接上
- [x] `/history`：列出已保存的对话（复用 `history_lines()`，与 `--list-history` 同一实现）
- [x] `/search <词>`：全文搜索（复用 `search_history_lines()`，与 `--search` 同一实现）
- [x] 三条命令在 `--no-config`（手机远程）里一律拒绝，文案与 `/mode` `/key` 一致
- [x] GUI 菜单 **会话**：接着上次 / 接着指定 / 列出现有对话 / 起名 / 搜索；
      前两个 = 带 `--continue` 重启后端，并明确提示「上面内容不重放」
- [x] `%S` 202 → **184**（新增 6 条）；GUI `_S` 123 → **113**
- [x] 测试：`test-session-continue` 21 → **31 项**（含受限会话拒绝）；`test-gui-modes` 25 → **35 项**
      （菜单五项齐全、`--continue` 真的进了后端命令行、起名走普通一轮输入）
- [ ] 真机验收（用户）：GUI「会话 → 接着上次」后能接上；菜单里没有需要手敲参数的地方

## 17. 已有加密历史的退路（本轮）

| 项目 | 内容 |
|---|---|
| 命令 | `--make-plain-history`：备份 → 解密 → 写出 `*.json` → 删 `key.enc` |
| 安全 | 备份先行；有文件解不开就中止且不删；明文仍 `0600` |
| 根因修复 | `hist_plain_encrypted()` 把 `key.enc`/`.check` 误判为明文，导致口令永远打不开 |
| 配套 | CLI 解口令时可读 `CLAUDE_HIST_PASS`（自动化与远端同一条路） |
| 测试 | `test-history-storage` 23 → 38 项（真实加解密、口令错不删钥匙、必须留备份） |

## 18. GUI 打不了字：焦点看护与按键兜底（本轮）

| 项目 | 内容 |
|---|---|
| 现象 | 窗口出来了，打什么字都不进去（macOS 上窗口没成为「前台应用」时发生） |
| 做法1 | 启动时 `deiconify` / `lift` / `topmost` 闪一下 / `focus_force` |
| 做法2 | 启动后 5 秒内每 400ms 自查：焦点不在输入框就再抢；**12 次仍不行才放弃** |
| 做法3 | 放弃时在状态栏与会话里说明「点一下输入框」，不让人干瞪眼 |
| 做法4 | 兜底：焦点在任何地方打的**可打印字符**都被送进输入框（带 Ctrl 的组合键不拦） |
| 测试 | `test-gui-modes` 38 → 42（放弃要说、正常不插噪声、焦点外按键不丢、focus 在内不重复插） |

## 19. 中文会话里冒出日文（本轮）

**现象**：远程要求中文，回复是中文，但工具调用前后的旁白是日文
（「先确认一下」这类日文短句）。

**根因**：`read_file` / `write_file` / `list_dir` / `run_shell` 四个工具的
description 与参数说明写的是日文。模型会照工具文档的语言写自己的旁白，
而系统提示只说「reply in the same language」，没有覆盖「进度说明/状态行」。

**修法**：① 工具说明改成中性英文（不带任何语言倾向）；② 系统提示升级为
语言锁定条款——回复、进度说明、状态行、工具调用前后写的话，全部必须用用户
语言，并明说「工具说明是英文，但这不改变你的输出语言」「中文会话绝不出现
日文」。

**测试**：`scripts/test-lang-lock.py`（4 项，已进 CI）：工具说明无假名、
系统提示覆盖三类文字、明确「不改变输出语言」、明确「中文不出现日文」。

## 20. 源码去日文化（本轮）

**口径**：代码里不再有日文。注释——技术/中性写英文，其余简体中文；写死的用户文案一律中文。
**保留**：i18n 词条（`%S` 的 `ja =>`、GUI 的 `"ja":`、`setup.sh` `msg()` 的 ja 分支、日语 `--help`
文本、`/^(y|はい)$/` 之类接受日语确认词的匹配）——这是「可选日语界面」本身，删掉等于删功能。

| 文件 | 清理前含假名行 | 清理后 | 剩余内容 |
|---|---|---|---|
| `agent/claude-agent.pl` | 805 | 212 | 166 条 `ja =>` + 其续行 + 日语 `--help` heredoc + 确认词正则 |
| `gui/advisor_gui.py` | 485 | 119 | 112 条 `"ja":` 及其续行、主题三语 label、真实字体名、macOS 原生菜单（仅 ja 模式执行） |
| `setup.sh` | 175 | 81 | `msg()` 的 ja 分支与生成 wrapper 的三语块 |
| `release/build_standalone_app.sh` / `remote/*.pl` | 76 | 0 | — |
| `models.txt` / `providers.txt` / `scripts/*` | 27 | 1 | `audit-probes.py` 的探针锚点（必须与目标文件逐字一致） |

**纪律**：这类机械替换最容易碰坏行为，所以每批都跑了 `perl -c` / `py_compile` / `bash -n` +
`check-i18n`（防止误删 i18n 词条）+ `check-models`（防止改坏数据文件），并逐文件核对 diff 只有注释与字符串。

**顺带修的探针**：`scripts/audit-probes.py` 有两处锚点因为注释被翻译而失效（GUI 焦点、解耦 `--no-config`），
已同步成现在的代码；探针本身 21/21 通过 —— 这也说明「卡口自己也得被验」。

## 23. 远程确认的两个口径修正（v0.2.6）

| 现象 | 用户回 y 却收到「确认超时，这次操作没有执行」 |
|---|---|
| 根因 1 | 网关只认 cid 匹配的答复，而**老版本长连接客户端不回声 cid** ⇒ 每次回答都被当成「上一道题迟到的答复」丢掉 |
| 根因 2 | 网关等待缩到 55 秒（agent 60 − 5），手机上看题+回话经常来不及 |
| 修法 | ① 带 cid 的答复必须对上；**不带 cid 的照收**（跨题串台交给「问之前清陈旧答复」+ 长连接端的 wait 清除）② 远程口径独立：agent 与网关都用 120s（网关 115s 收尾），手机消息里写明「请在 N 秒内回复」 |
| 测试 | `test-gateway-write` 68→70（不带 cid 也认、提问前就到的旧答复被丢弃）；真 agent + 真网关 e2e 复核：带 cid 执行 / 不带 cid 执行 / 不回不执行 |
| 已知小坑 | Perl 的 `readline` 会把管道内容预读进自己的缓冲区，`IO::Select` 看不到，所以「问之前清陈旧答复」这条防线对预读内容不生效；此时靠 cid 不匹配兜住（两条防线任一生效即可） |

## 24. HTTP 422「content should be a string or a list」（v0.2.6）

**现象**：长会话里突然报
`API 错误（HTTP 422）：Failed to deserialize the JSON body … messages[271]: content should be a string or a list`。

**根因**：`build_request_openai` 组装带工具调用的 assistant 消息时，只有「有文本」才赋
`content`；**只调工具、没有文本**时它一直是 `undef` → `MiniJSON::encode` 编成 `null`。
OpenAI 接受 `content:null`，但 DeepSeek 这类服务（Rust serde，报错文案就是它）不接受，
直接 422。长会话才炸，是因为前面那些工具调用恰好都带了文本；`messages[271]` 是这条会话里
第一个「纯工具调用」的位置。

**修法**：
- 根因处：`$m->{content} = @texts ? join("\n", @texts) : '';`（永远给字符串）
- 兜一层：`build_request_openai` 出口处扫一遍，任何 `content` 为 undef 的消息补成 `''`
  —— 老会话文件、手工改过的历史、第三方导入都可能带 `null`；带 `CLAUDE_DEBUG=1` 时会
  打一行 notice 说明补了几条。

**测试**：`scripts/test-modes.py` 新增 `case_content_never_null`（只给工具调用不给文本，
断言请求体里没有 `"content":null`、且带 `tool_calls` 的 assistant 消息 `content` 是字符串）。
`test-modes` 73→75。
