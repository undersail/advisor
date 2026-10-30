# Advisor

*为老 Mac 打造的轻量 AI 智能体 —— 终端能用，也有图形界面。*

Advisor 让一台老 Intel Mac（macOS 10.9 及以上）重新变成好用的 AI 助手：一个单文件的 Perl
智能体 + 一个 Python/tkinter 图形界面，不依赖云服务、不需要自建服务器，密钥和对话都留在你
自己的机器上。

> 本项目是纯本地桌面软件，不提供托管服务，也**不需要申请任何云资源**。仓库里不含任何人的
> 账号、令牌或云资源 id。

English: [README.en.md](README.en.md) ｜ 完整说明：[docs/user_manual.md](docs/user_manual.md)

## 能做什么

- **七家 AI 随时切换** —— Claude、Gemini、OpenAI、DeepSeek、通义千问、Kimi、GLM；
  对话中用 `/claude` `/gemini` `/openai` `/deepseek` `/qwen` `/kimi` `/glm` 切。
  Gemini 有免费额度，可以零成本先试。
- **终端与图形界面是同一套东西** —— 敲 `advisor` 直接对话；双击 `Advisor.app` 进图形界面，
  三套主题（笔记 / 编程 / 黑客）按心情换。
- **能读写文件、能跑命令，但由你控制** —— 读文件从不询问；写文件与执行命令分三档
  （`default` 全问 / `accept-edits` 只自动写文件 / `bypass` 常规操作不问）。
  **`bypass` 仍会问两类**：危险命令、文件/目录操作（`rm`/`mv`/`cp`/`chmod`/`tar`…）；
  没人应答按拒绝处理。可写范围（白名单）只服务于 `accept-edits`，`bypass` 下不生效。默认只有当前目录和
  临时目录，`~/.ssh`、`~/.claude-agent` 这类目录即使显式加入也拒绝。
- **对话历史保存在本地，默认明文**（`0600`，目录 `0700`，启动不问口令）；
  想要加密就 `--encrypt-history`，用口令 + 可选密保问题保护；`--no-history` 可以整场不落盘。
  机器上还留着旧密钥、每次都要口令：`--make-plain-history` 一次性转成明文（先备份，再解密，最后删 `key.enc`）。
- **会话接续与找回**：`--continue` 直接接着最近一场（不弹菜单），`--name` 起名后
  `--continue 名字` 按名接，`--search 关键词` 在历史里全文搜索；会话内也能用 `/name`
  `/history` `/search`，图形界面还有「会话」菜单（接着上次 / 起名 / 搜索），不用记参数。手机远程时同一发送者
  会自动接上自己上一场，服务重启也不丢。
- **记得住你，也学得会套路** —— 长期事实写在 `~/.claude-agent/memory.md`（明文 0600，
  `/remember` 记一条、`/memory` 增删看）；把「这类任务先做什么」写成 Markdown 放进
  `~/.claude-agent/skills/`，模型只看到名字和一行描述，用得上时才去读全文。
- **从手机派活（可选）** —— 企业微信「智能机器人 · 长连接」只要 BotID + Secret，
  不需要公网域名、不需要云账号；权限在 Mac 上启动时定档，需要确认的操作发到手机上回 `y`/`n`。
  飞书走回调模式（需要你自己的公网可达地址）。
- **界面中文为默认** —— 也可以切英文（历史版本留下的日文文案保留，不再新增）。

## 安装

### ① 下载即用（不需要终端）

1. 从[最新发布](https://github.com/undersail/advisor/releases/latest)下载
   `Advisor-v*-standalone.zip` 并解压
2. 把里面的 `Advisor` 拖进「应用程序」（或 Dock）
3. **仅第一次**右键（或 Control-点击）→「打开」→ 再点一次「打开」。
   没做 Apple 开发者签名，这一步是正常的
4. 首次启动会显示应用内的密钥登记页：选厂商 → 点按钮去申请 → 粘贴回来即可，全程不用终端

压缩包里附了 `ReadMe_ZH.txt`（中文）与 `ReadMe_EN.txt`（英文）。

### ② 从源码（终端）

```bash
git clone https://github.com/undersail/advisor.git
cd advisor
bash setup.sh
```

`setup.sh` 会走完：选厂商 → 存密钥 → 装 `advisor` 命令与补全 → 生成 `Advisor.app` →
跑一次连通性测试。

> **不要用 `sudo` 跑 `setup.sh`。** 它会把 `~/.claude-agent*` 的属主变成 root，
> 之后普通用户读不到，表现为「明明配好了却报没配」。

## 快速上手

```
advisor                     启动对话
/model  或  ?               显示模型列表，输入编号即可切换
/key <厂商>                 配置某家厂商的密钥（会话内唯一的密钥入口）
/mode [档位]                查看 / 切换交互模式
/allow-write <目录>         追加可写目录（可多个）
/approvals                  最近 10 条自动批准记录
exit  或 Ctrl-D             退出
```

常用的启动参数：

```
advisor --mode=<default|accept-edits|bypass>   指定交互模式
advisor --allow-write=<目录>                   追加可写目录（可重复）
advisor --resume                               继续上次的对话
advisor --list-history                         列出已保存的对话
advisor --no-history                           本次不保存历史
advisor --version                              版本
```

GUI 里页眉有 `[ 对话 ] [ 命令 ]` 两个标签、`[ 切换 AI ]`、`[ 继续上次 ]`、`[ 主题 ]`，
以及常驻的当前模式徽标。

## 支持的 AI

| 厂商 | 会话内命令 | 密钥环境变量 |
|---|---|---|
| Anthropic | `/claude` | `ANTHROPIC_API_KEY` |
| Google | `/gemini` | `GEMINI_API_KEY` |
| OpenAI | `/openai` | `OPENAI_API_KEY` |
| DeepSeek | `/deepseek` | `DEEPSEEK_API_KEY` |
| 通义千问（阿里云） | `/qwen` | `DASHSCOPE_API_KEY` |
| Kimi（月之暗面） | `/kimi` | `MOONSHOT_API_KEY` |
| GLM（智谱） | `/glm` | `ZHIPU_API_KEY` |

后五家走 OpenAI 兼容协议。想接别的兼容服务，在 `models.txt` 里加一行、把 `provider`
写成 `openai` 即可；想整体换端点（例如自建代理）设 `CLAUDE_BASE_URL`。

> 内置的模型名只是方便起步的默认值，**请以各厂商文档为准**；过时了改 `models.txt` 就行。

## 配置与数据放在哪

| 内容 | 位置 |
|---|---|
| 厂商与密钥 | `~/.claude-agent-env`（权限 0600，**必须归当前用户所有**） |
| 对话历史（加密） | `~/.claude-agent/history/` |
| 长期记忆（**明文**） | `~/.claude-agent/memory.md` |
| 技能 | `~/.claude-agent/skills/` |
| 远程白名单 / 通知 | `~/.claude-agent/remote.conf` |
| 企微长连接凭据 | `~/.claude-agent/wecom-ws.conf` |
| 远程审计日志（只追加） | `~/.claude-agent/audit.log` |
| 安装产物（`advisor` 命令、`Advisor.app`） | `~/claude-build/`、`~/bin/` |
| 模型表 / 厂商表 | 仓库内的 `models.txt`、`providers.txt` |

## 限制

- **系统版本**：macOS 10.9（Mavericks）～ 10.13（High Sierra）及更新可用。
  10.6～10.8 需要自行编译 OpenSSL/curl，**暂不支持**。
- **没有代码签名**：分发包是 ad-hoc 签名，首次打开要走右键 →「打开」。
- **要自备 API 密钥**：本仓库不含任何密钥；费用按各厂商自己的计费结算，Gemini 有免费额度。
- **历史口令忘了就没了**：口令与密保答案都忘记时，已保存的对话无法恢复，只能删掉
  `~/.claude-agent/history/` 重新开始。
- **远程接入**：企业微信长连接可用；飞书只有回调模式（需要公网可达地址），
  飞书长连接尚未实现。
- **远程权限起点在 Mac 上定**：档位只能在启动服务时指定，起来之后手机端改不了
  （`/mode` `/model` `/key` 一律被拒）。同一时间只允许一个远程服务实例，第二个会直接退出。
- **历史日文文案保留**：早期版本带日文界面文案，现在默认中文、可选英文，新内容不再写日文。

## 许可证

[MIT License](LICENSE)
