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
| CI / 镜像 / 文档骨架 | ✅ 本仓新增（见下） |

---

## 1. 本仓已铺好的工程骨架

| 文件 | 作用 |
|---|---|
| `.editorconfig` | utf-8 / LF / 2 空格（`.pl` `.py` 为 4） |
| `.github/workflows/ci.yml` | perl -c、py_compile、bash -n、models.txt 格式、CRLF 检查；矩阵 ubuntu + macos |
| `.github/workflows/sync-gitee.yml` | main → `gitee.com/undersail/advisor` 镜像（含 tag） |
| `docs/design_doc_advisor.md` | 架构、协议、加密层级、限制、改动规则 |
| `docs/releases/` | 发布说明，文件名 = tag 名 |

**CI 刻意不做什么**：不调真实 API（要密钥且计费）、不跑 GUI（无显示器）、
不打包 `.app`（需 macOS + py2app，见 M3）。

---

## 2. ⚠️ 待确认：本 fork 的目标

上游定位明确（救活旧 Mac、日英双语、零依赖），但**本 fork 要做什么还没定**。
这里不预设方向，把候选列清楚，等维护者勾选后再拆里程碑：

- [ ] **A. 跟随上游**：只做同步 + 修补，主要目的是加中文支持 / 国内可用性
- [ ] **B. 中文化**：把 `_S` 文案字典和 README 扩成日中英三语（目前 i18n 只认 ja/en）
- [ ] **C. Tier A 攻坚**：实现 Snow Leopard ~ Mountain Lion 的 toolchain 方案
- [ ] **D. 能力扩展**：加工具（如 `edit_file` 精确替换、`search_files`）、加提供商
- [ ] **E. 工程化**：补单元测试、把单文件 Perl 做可控拆分

**在上面勾选确定之前，不动 `agent/claude-agent.pl` 的核心逻辑。**

---

## 3. 里程碑（草案，待 §2 定了再改）

### M1 · 骨架落位（本次）
- [x] 克隆 + 配 `upstream` remote
- [x] `.editorconfig`
- [x] CI（语法/一致性/冒烟 + ubuntu×macos 矩阵）
- [x] Gitee 镜像 workflow
- [x] 设计文档 + 开发计划
- [ ] **人工步骤**：在 GitHub 仓库 Settings 添加 `GITEE_DEPLOY_KEY` 密钥
- [ ] **人工步骤**：确认 `gitee.com/undersail/advisor` 镜像仓可写（已确认存在）

### M2 · 中文化（若选 B）
- [ ] `gui/advisor_gui.py::_S` 增加 `zh`，`_detect_lang()` 识别 `zh_*`
- [ ] `agent/claude-agent.pl` 的日文提示 / 帮助文本 / `print_help` 增补中文
- [ ] `setup.sh` 的交互文案增补中文
- [ ] `README.zh.md`
- [ ] 保持 ja/en 不回归（比较三语文案 key 集合是否一致，可加进 CI）

### M3 · 发布链路（若需要）
- [ ] 加 `.github/workflows/release.yml`：打 tag → 建 GitHub Release，
      说明取 `docs/releases/<tag>.md`，缺省则自动生成
- [ ] macOS runner 上跑 `release/build_standalone_app.sh` 产出 standalone zip
- [ ] 明确 tag 命名（建议 `v<major>.<minor>.<patch>`）

### M4 · Tier A（若选 C，最重）
- [ ] 在 Linux 上交叉编译 OpenSSL + curl，产出可搬到 10.6~10.8 的 toolchain
- [ ] `setup.sh` 支持 `~/claude-toolchain` 自动检测（骨架已在）
- [ ] 在真机（或 VM）验证 TLS1.2 握手 + API 往返
- [ ] 文档写清"没有 Apple 开发者账号的用户怎么一步步准备"

---

## 4. 工作纪律

1. **绝不修改 `ezapps`** —— 那是另一个并行会话的仓库，只读参考。
2. 本会话只在 `the repo` 内改动。
3. 每次改动收尾：`git status` 干净、提交信息符合 `TYPE(scope) 中文描述`。
4. 提交前自查：没引入 CPAN 依赖、没用到新版 perl 语法、`perl -c` 通过。
5. 版本号 / tag 一律由维护者决定，不自动打。
6. 在 Linux 开发机上**能验证的**：Perl 逻辑、shell 脚本、协议层、文档。
   **不能验证的**（须在 Mac 上复核）：GUI 观感、`.app` 打包、Gatekeeper、
   真实 OS 兼容性、API 往返。
