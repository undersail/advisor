# 审计记录

按轮次归档。**先看最新那份的「当前状态」与「仍未做/未验」两节**，其余按需回溯。

| 文件 | 内容 | 什么时候看 |
|---|---|---|
| [`audit_advisor_v0.2.3.md`](audit_advisor_v0.2.3.md) | **v0.2.3 发版前全面审计**：交互模式三档 / `/key` 密钥策略 / 远程只对话 / 真机四个 bug；含反向探针 15/15、覆盖矩阵、进程清理 | 想知道现在是什么状态、这一版改了什么 |
| [`audit_advisor_v0.2.1_r2.md`](audit_advisor_v0.2.1_r2.md) | 第二轮（v0.2.1 之后）：GUI 自递归、Gitee 反拉保护、bash 3.2 两类坑、`.app` 弹窗挂死、测试进程泄漏、覆盖缺口 | 查历史 |
| [`audit_advisor_v0.2.1.md`](audit_advisor_v0.2.1.md) | tag `v0.2.1` 时的七维度全面审计（**快照**，文中的步数/项数是当时的数字） | 查历史决策与当时的待修项 |
| [`audit_security_platform.md`](audit_security_platform.md) | 专项：平台回调面的隐私与信息安全（验签 / AES / 白名单 / 审计日志 / 去重），含队列为什么从 KV 换成 Durable Object | 动 `remote/` 之前必看 |

审计的**固定方法**（每轮都这么做，不靠读代码"看着没问题"）：

1. `python3 scripts/ci-local.py` —— 真执行 `ci.yml` 的 `run:` 原文，不手抄逻辑；再跑一遍 `--pristine`
2. 逐个跑 6 个卡口脚本与 10 个测试脚本，数字以实际输出为准（不引用文档里的旧数字）
3. 新写的卡口做**反向探针**：`python3 scripts/audit-probes.py`（植入违规 → 必红 → 还原 → 再绿）
4. **覆盖矩阵**：`scripts/` 文件清单 减 `ci.yml` 引用清单，差集里每个文件都要有理由
5. 跑完看一眼 `ps` —— 断言全绿不代表没留下进程（实测泄漏过 37 对服务端进程）
6. 真环境对打：真实 Gitee 镜像、真实 git hook、`wrangler dev`、真 PTY

**每份审计都要写清盲区**：真机 GUI 观感、真 API key、真企微/飞书回调、macOS 打包与签名 ——
这些在 Linux 开发机上根本验不到，别让读者以为已经验过。真机清单见 `../manual_test_mac.md`。
