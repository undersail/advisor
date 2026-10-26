# Advisor v0.2.1 全面审计报告

- 审计对象：`undersail/advisor`（公开 fork），审计提交 `e72262f` 及其后续修复
- 上一版 tag：`v0.2.0`（`964d577`）
- 本次审计的产出：本报告 + `docs/releases/v0.2.1.md` + 若干修复提交 + 新卡口 `scripts/check-version.py`、`scripts/audit-commands.py`
- 只读声明：审计过程只读代码与运行测试，唯一写操作是修复与新增卡口本身；未触碰任何外部服务数据

## 结论总表

| 维度 | 结论 | 关键证据 |
|---|---|---|
| 1. 质量门 | 全绿 | 语法门 6 项、卡口 5 项、端到端 3 套（20+7+17 项）、CI 17 步 × 2 平台 |
| 2. 旧口径 / 死字段 | 发现 7 处，全部已修 | 见 §2 逐条 |
| 3. 「有引用」≠「有调用」 | 发现 1 个死脚本、2 个故意不在 CI | 见 §3 |
| 4. 线上数据 | 不适用 | 本项目无服务端、无用户数据（见 §4 盲区） |
| 5. 部署漂移 | GitHub 与 Gitee 同步正常 | Gitee 镜像 workflow 最近一次 success |
| 6. 口径自洽 | 发现版本号 7 个写入点 → 已收口为单源 | 见 §6 |
| 7. 文档腐烂 | 发现 8 处数字/章节/声明过期，全部已修 + 新增防漂移卡口 | 见 §7 |

---

## 1. 质量门（贴原数）

语法门：

```
perl -c agent/claude-agent.pl          → syntax OK
python3 -m py_compile gui/advisor_gui.py → OK
bash -n setup.sh                        → OK
bash -n release/build_standalone_app.sh → OK
perl -c remote/gateway.pl               → syntax OK
perl -c remote/notify.pl                → syntax OK
```

一致性卡口：

```
scripts/check-models.py     → 12 条模型；7 家；注册表 7 个 provider，一致性通过
scripts/check-i18n.py       → setup.sh msg() 三语各 41 条；占位符一致；未译 0 条
scripts/check-decoupling.py → 核心零远程逻辑；远程工具写死只读
scripts/check-secrets.py --history → 泄漏检查通过（39 个已跟踪文件 + 全历史）
scripts/check-version.py    → VERSION=0.2.1；--version 一致；Perl=102 GUI=57 msg=41 厂商=7 模型=12

> 注：本报告里的数字是 **v0.2.1 当时**的实测值。之后新增了 GUI 前置条件相关的两条提示，
> `msg()` 已变成三语各 43 条；以 `python3 scripts/check-version.py -v` 的输出为准。
```

端到端（本地 mock，不碰真网络/真 key）：

```
scripts/test-remote.py           → 20/20
scripts/test-relay.py            → 7/7
scripts/test-release-workflow.py → 17/17
```

`scripts/ci-local.py` 真跑 `ci.yml`（不是手抄逻辑）：**17 步 × 2 平台全部通过**。

## 2. 旧口径 / 死字段（逐条判定）

| 命中 | 判定 | 处置 |
|---|---|---|
| `dev_plan` 「`%S` **96** 条」 | 过期：实际 102（M4 菜单、M5 新文案都在涨） | 改为 102 |
| `dev_plan` 「`_S` **59** 条」 | 过期：实际 57（M4-GUI 重写时并了几条） | 改为 57 |
| `dev_plan` 「`msg()` 实际 **54** 条」 | 过期：实际三语各 41 条 | 改为 41 |
| `dev_plan` 「剩下 96 + 59 条」「96+59 条冲突」 | 同上 | 同步改 |
| `manual_test_mac` 「`advisor --version` → 0.1」 | 过期：版本已收口到 `VERSION` | 改为引用 `VERSION` |
| `design_doc` 出现两个 `4.3`（新旧章节撞号） | 章节号错 | 新的远程章节改为 `4.5` |
| `README.md`（日文原版）里被插入了英文声明 | 三语错位 | 换回日文；英文声明补进 `README.en.md` |
| `dev_plan §0` 现状表仍写「中文待做 / 国产模型待做 / 远程待做」 | 严重过期（三项都已实现） | 整表重写，补 M5/M6/M7 与档②缺口 |

**保留不改**的命中（描述历史或上游，属正确表述）：
`双提供商（Claude / Gemini）｜✅ 上游已实现`、`models.txt` 的 2/3/4 列历史格式说明、
`design_doc` 里「老的三列表仍可直接用」、决策记录里「M2 改成 4 列、M4 又改 6 列」的教训。

## 3. 「有引用」不等于「有调用」

| 对象 | 结果 |
|---|---|
| `scripts/check-version.py` | **死脚本**：新增后没进任何 workflow → 已加进 CI |
| `scripts/ci-local.py` | 只被文档引用 —— 设计如此（开发者在本地跑 CI，CI 自己不需要它） |
| `scripts/live-check.py` | 只被文档引用 —— 设计如此（使用者在自己机器上用真 key 跑） |
| `providers.txt` 的 `key_url` | 有读取点：GUI 首启页（`advisor_gui.py:551`、`:914`）、`live-check.py:123` |
| `models.txt` 的 `notools` 旗标 | 有读取点：`claude-agent.pl:1065`、`:1111`，`check-models.py` 认识它 |
| 12 个厂商命令/别名 | PTY 两相实测 **24/24 通过**（12 命令 × 路由/真切换） |
| `providers.txt` 的 ja/en/zh 三列 | 被 GUI 读取（首启页与模型菜单） |

命令可达性用 PTY 真终端验（管道喂多行会被读成一整块，是项目已知坑）：

- **第一相（只给默认厂商假 key）**：缺 key 时每条命令都应显示**对的那一家**的密钥页与变量名 → 验「路由」
- **第二相（七家都给假 key）**：应出现 `→ 已切换到 [<provider> / <model>]` → 验「真的切过去」

实测结果：**24/24 通过** —— 12 条命令（7 个厂商名 `anthropic / gemini / openai /
deepseek / dashscope / moonshot / zhipu` + 5 个别名 `claude / qwen / tongyi / kimi / glm`）
在第一相都指向正确的密钥页，第二相都真的切到了对应 provider 与默认模型。

过程中的一个重要发现：**缺 key 时切换命令不会真的切**，它插入「粘贴 key」提示，空回车即取消。
这不是 bug（没有 key 切过去也用不了），但意味着脚本化/远程使用时不能假设「发命令就切了」。

## 4. 线上数据审计 —— 不适用

本项目没有服务端、没有用户数据、没有账号体系。全部状态都在本机
（`~/.claude-agent/`）。因此「存档总数 / 测试号残留 / 资金守恒」这类审计无对象。

## 5. 部署漂移

- GitHub `main` 与工作区一致（审计前 `e72262f`，提交前复查 `git status` 为空）
- Gitee 镜像：`Sync to Gitee Mirror` 对最近提交 success
- **盲区**：本机没有 Gitee 凭据，无法直接读取镜像侧的 HEAD sha 做逐字比对，
  只能依赖 workflow 的成功状态

## 6. 口径自洽（不变量逐条断）

| 不变量 | 结果 |
|---|---|
| `models.txt` 的 `base_url` 主机与 `provider` 列一致 | 12/12 自洽 |
| `providers.txt` 的 `default_model` 都存在于 `models.txt` | 7/7 存在 |
| `providers.txt` ↔ `models.txt` ↔ `%PROVIDERS` 三方一致 | `check-models.py` 通过 |
| 三语占位符个数一致 | 通过；未译 0 |
| GUI / setup.sh / agent 共读同一份厂商表 | 是（`providers.txt` 单一来源） |
| **版本号只有一个来源** | **原来有 7 个写入点 → 本次收口** |

### 版本号收口（本次主要修复）

审计前版本号散落在：`agent --version` 一行、`setup.sh` 五处（wrapper + Info.plist 两键 + py2app plist 两键）、
`release/build_standalone_app.sh` 一处。改一处漏一处不会报错，只会让产物名、plist、`--version` 各说各话。

现在唯一来源是仓库根目录的 `VERSION`：

- `agent` 的 `--version` 读它（找不到则 `unknown`）
- `setup.sh` 读它填 wrapper 与两处 Info.plist；读不到则 `0.0.0-dev`
- `release/build_standalone_app.sh` 读它决定 zip 名；**读不到直接报错退出**（不留假版本号）
- 发布 workflow 增加一步：tag 版本与 `VERSION` 不一致就红
- `scripts/check-version.py` 在 CI 里断言上述全部，并**禁止** `setup.sh` / 构建脚本再出现版本字面量

## 7. 文档腐烂与防漂移

处置见 §2。除此之外新增两件东西：

1. **`scripts/check-version.py`** —— 文档里写的条数（`%S` / `_S` / `msg()` / 厂商数 / 模型数 / `models.txt` 列数）
   与代码实际值逐条比对；`VERSION` 与 `--version`、tag 一致性也在这里。文档一腐，CI 就红。
2. **`scripts/audit-commands.py`** —— 命令可达性用 PTY 两相实测（本次 24/24），
   防止「菜单里写着某家、实际切不过去」这类看不见的腐烂。它不进 CI：
   单次要跑几分钟，放在发版前的审计里更合适。

## 问题清单

### 已修

| # | 问题 | 位置 |
|---|---|---|
| 1 | 版本号 7 个写入点，易漂移 | 全仓 → 收口到 `VERSION` |
| 2 | 构建脚本缺 `VERSION` 时用假兜底版本号 | `release/build_standalone_app.sh` |
| 3 | 发布 workflow 不校验 tag 与代码版本一致 | `.github/workflows/release.yml` |
| 4 | `check-version.py` 是死脚本（没进 CI） | `.github/workflows/ci.yml` |
| 5 | 文档条数 96/59/54 全部过期 | `docs/dev_plan.md` |
| 6 | `dev_plan §0` 现状表三项已实现仍标「待做」 | `docs/dev_plan.md` |
| 7 | `design_doc` 两个 `4.3` 撞号 | `docs/design_doc_advisor.md` |
| 8 | 日文 `README.md` 里插了英文声明；`README.en.md` 缺该声明 | 三份 README |
| 9 | 三份 README 都没提远程接入（用户可见的新能力） | 三份 README |

### 待修（需你点头或需外部条件）

| # | 问题 | 严重度 | 为什么没做 |
|---|---|---|---|
| 1 | 档② 平台端收发（结果推回手机） | 高（功能缺口） | 需企微 corp secret / 飞书 app token + 回调验签与 AES 解密，必须真凭据联调 |
| 2 | Tier A（macOS 10.6~10.8） | 中 | 需自建 OpenSSL+curl 交叉工具链，工程量最大，已明确暂缓 |
| 3 | 分发版未签名（首次启动需右键打开） | 中 | 需 Apple Developer ID（年费账号），不是代码问题 |
| 4 | 真 key 协议层差异（tools schema / `max_tokens` 语义） | 中 | 本会话无真 key，`scripts/live-check.py` 已备好给使用者自测 |

### 盲区（明确没验的）

- **py2app 打包与 `gh release create`**：只能在 macOS runner 上跑，本机没有 `gh`、没有 GitHub token，
  无法触发 workflow。`scripts/test-release-workflow.py` 只验到 workflow 里非 macOS 的那部分。
- **GUI 视觉排版**：只在 Xvfb 里做控件树内省，下拉宽度/间距/字号需真人过目。
- **真实厂商端点**：只验到网络层（四家 401 = 通路正常）；协议细节要真 key。
- **Gitee 镜像逐字一致性**：无凭据，只能看 workflow 成功状态。
- **长时间运行**：远程网关的 180 秒熔断只在 mock 场景下触发过，没有跑过真正的长任务。
