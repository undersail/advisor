# Mac 真机验收清单

本机（Linux）只能验到「协议构造 + 逻辑分支 + 控件结构」这一层。下面这些**只有
macOS 真机能确认**，按顺序做一遍大概 15 分钟。

每一步都写了「应该看到什么」和「不对的话把什么发给我」。发之前扫一眼有没有
密钥 —— 不要贴 key，贴到 `****` 之后的即可。

---

## 0. 准备

```bash
git clone git@github.com:undersail/advisor.git
cd advisor
```

需要：macOS 10.9 或更新（Tier B）+ 系统自带 perl/python3。
Xcode Command Line Tools **只有打 zip 包才需要**，装普通版不需要。

---

## 1. 终端版跑通（不装 GUI）

```bash
export DEEPSEEK_API_KEY=你的key      # 或先不设，看它是否给出指引
perl agent/claude-agent.pl
```

**应该看到**
- 中文环境：`=== high_sierra Advisor ===` + 历史记录提示
- 没有 key 时：`DEEPSEEK_API_KEY を設定してください`（或对应语言）
- 有 key 时：`有什么需要？>`

**顺手验三项**
| 操作 | 应该看到 |
|---|---|
| 输入 `/model` | 先列 **7 家厂商**（不是 12 个模型） |
| 接着输 `4` | 列出 DeepSeek 的两个模型 |
| 接着只按回车 | `已取消`，回到对话 |
| 输入 `/deepseek`（已有 key） | `已切换到 [deepseek / deepseek-chat]` |
| 输入 `/foo` | 当成普通发言发出去，不报"未知命令" |
| 输入 `/help` | 中文帮助 |

**这里最容易露的两处**：`/model` 是否真是两级、`/deepseek` 切换后 `model_lbl` 是否跟着变。

---

## 2. setup.sh 安装

```bash
bash setup.sh
```

**应该看到**
- 中文向导，厂商列表是 **7 项**（Gemini / Anthropic / OpenAI / DeepSeek /
  通义千问 / Kimi / GLM），不是原来的 2 项
- 选一家后：`需要 <厂商名> 的 API 密钥` + 密钥页 URL
- 粘贴后：`→ 使用 ...` + `已保存到 ~/.claude-agent-env`
- 最后 `检查 API 连通性` → `API 连接正常`

**不对的话**：把 `消息里的中文提示` + `HTTP 状态码` 发我。特别注意
`APIエラー(HTTP xxx)` 里的数字 —— 401 是 key 无效、403 是这家封了你的地区、
000 是网络根本不通。

然后重开终端：
```bash
advisor --version     # advisor (high_sierra_claude) <VERSION 文件里的版本>
advisor --list-models # 12 条，带中文说明
advisor -m glm-4.6    # 指定模型起一轮
```

---

## 3. GUI：首启画面

```bash
open ~/Applications/Advisor.app     # setup.sh 生成的双击版
# 或
python3 gui/advisor_gui.py
```

（若已存在 `~/.claude-agent-env` 且里面有 key，会直接进主界面 —— 想重看首启就
`mv ~/.claude-agent-env /tmp/env.bak`）

**应该看到**
- 一个下拉，**7 项**，中文环境显示中文厂商名（`通义千问（阿里云）` 这种）
- 切换下拉 → 下面那个蓝色「获取密钥」按钮的跳转地址跟着变（点开看一眼域名对不对）
- 粘 key → 校验通过 → 进主界面

**重点看观感**（这部分我没法在本机验）：
下拉框宽度够不够、厂商名有没有被截断、按钮与输入框的间距、整体是否居中。

---

## 4. GUI：模型菜单两级

主界面菜单栏点开「切换」那一项。

**应该看到**：7 个分组，鼠标悬停展开子菜单，列出该厂商的模型；当前在用的那条
后面带「使用中」。

点一个 → 顶部模型标签跟着变 → 下一句话由新模型回答。

---

## 5. 真机才可能暴露的坑（按怀疑度排序）

| 怀疑点 | 怎么验 | 出问题的表现 |
|---|---|---|
| **`/deepseek` 真调用** | 选 DeepSeek 问一句 | 400/422 → 请求体它不认；`tool_calls` 不返回 → 函数调用不可用 |
| **工具调用闭环** | 让它「读一下 ~/.zshrc」 | 卡住不动 / 报 `tool_result` 相关错误 |
| **`max_tokens` 上限** | 让它写长一点的东西 | 报参数非法（各家的字段名和上限不一致） |
| **Kimi/GLM 上下文与限流** | 连续问 5 轮 | 429 限流；错就错在限速，不是功能 |
| **`setup.sh` 的 bash 3.2** | 跑一遍安装 | `mapfile: command not found` 之类 → 说明误用了 bash 4 特性 |
| **包装脚本报错** | `advisor --list-models` | 说明 `provider_of` 取不到 provider |
| **py2app 打包** | `bash release/build_standalone_app.sh` | 需要 Xcode CLT；只在要分发时做 |

---

## 6. 打可分发 zip（可选）

```bash
xcode-select --install          # 若没装过
bash release/build_standalone_app.sh
```

产物在 `release/` 下。**这一步在本机完全没验过**（Linux 没有 py2app），
如果失败把完整报错发我。

---

## 7. 想更彻底：用脚本验协议

```bash
export DEEPSEEK_API_KEY=你的key
python3 scripts/live-check.py deepseek
```

10 项断言，只打印 PASS/FAIL，**不含 key**。想验别家就换参数
（`openai` / `dashscope` / `moonshot` / `zhipu`；`anthropic` / `gemini` 走另外两种
请求形状，脚本目前只覆盖 OpenAI 兼容那五家）。

## 6. 远程接入（可选，M5）

远程和本地是两套东西，先确认本地能跑再做这一步。

### 6.1 只验通知（最快，1 分钟）

1. 建 `~/.claude-agent/remote.conf`，写一行（企微群 → 群机器人 → 复制 webhook 地址）：
   ```
   WECOM_WEBHOOK = https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...
   ```
2. 跑：`perl remote/notify.pl --test`
3. 应看到：`通知已发送：WECOM_WEBHOOK`，手机上群里收到一条
   「advisor 通知连通性测试 —— 收到即成功。」
4. 不对时看：`通知发送失败：WECOM_WEBHOOK（errcode 93000: ...）` —— 93000 是
   key 无效或地址抄错；报 `url must start with https` 说明粘成了 http。

### 6.2 验网关（远程只读）

1. 同目录加白名单（先随便写你自己的 ID，随便什么串都行，这里只验证拦截逻辑）：
   ```
   ALLOW = alice
   ```
2. 跑一条：`perl remote/gateway.pl --once --from alice --text "列一下当前目录"`
3. 应看到：正常的中文回答（说明 agent 被网关驱动起来了）
4. 换成不在白名单的人：`perl remote/gateway.pl --once --from bob --text "ls"`
   应看到：**什么都没有输出**（不回"无权限"，避免暴露机器人存在），
   但 `~/.claude-agent/audit.log` 里有一行 `drop_sender from=bob`。
5. 试让它写文件：「在 /tmp 建个文件」 —— 应被拒绝，且 `/tmp` 下不会出现文件。
   拒绝理由会回给模型，模型会转述给你。

### 6.3 验收要点（对着看，别只看"跑通了"）

- [ ] `~/.claude-agent/audit.log` 存在且权限 `-rw-------`
- [ ] 白名单外的人：无输出、有审计
- [ ] 让写文件：没写成，且回答里说明了不能写
- [ ] `remote.conf` 里没有 `HIST_PASS` 时，`~/.claude-agent/history/` 不该多出东西

## 7. 平台端收发（真机 + 真平台）

本地已用自造凭据验过验签/解密/白名单/回推（`scripts/test-platform.py` 25 项），
真机要验的是「平台真的能连上你」：

- [ ] `perl remote/platform.pl --init` 录入凭据，`--check` 显示配置齐全
- [ ] 企微：管理后台填回调 URL（`https://<域名>/wecom`），点保存能通过验证
      （会打到你的 `--serve` 上，走 GET + echostr 解密）
- [ ] 手机上给应用发一条消息，几秒内收到回复
- [ ] 把 `ALLOW` 里删掉自己，再发一条 —— 应该**没有回复**，
      但 `~/.claude-agent/audit.log` 里出现 `drop_sender`
- [ ] `--test-push "测试" --to <你的ID>` 能收到
- [ ] 飞书：事件订阅里填回调地址，能通过 challenge 验证；发消息有回复
