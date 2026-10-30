# Advisor

*A lightweight AI agent for older Macs — usable from the terminal and from a GUI.*

Advisor turns an older Intel Mac (macOS 10.9 and later) back into a useful AI assistant:
a single-file Perl agent plus a Python/tkinter GUI. No cloud service, no server of your own —
your keys and your conversations stay on your machine.

> This project is a purely local desktop app. It hosts nothing for you and requires **no cloud
> resources**. The repository contains no account, token, or cloud resource id of anyone.

Chinese: [README.md](README.md) ｜ Full guide: [docs/user_manual.md](docs/user_manual.md)

## What it does

- **Seven providers, switchable mid-conversation** — Claude, Gemini, OpenAI, DeepSeek,
  Qwen (Alibaba), Kimi (Moonshot), GLM (Zhipu). Use `/claude` `/gemini` `/openai`
  `/deepseek` `/qwen` `/kimi` `/glm`. Gemini has a free tier, so you can try the whole
  thing at zero cost.
- **One app, two faces** — run `advisor` for the terminal, or double-click `Advisor.app`
  for the GUI with three themes (Notes / Coding / Hacker).
- **It can read, write, and run commands — under your control** — reading never asks.
  Writing and shell execution have three modes (`default` asks for both, `accept-edits`
  auto-writes but still asks for commands, `bypass` skips routine prompts).
  **Dangerous commands are still confirmed even in `bypass`**, and no answer means denied.
  Writable scope defaults to the current directory and temp only; `~/.ssh` and
  `~/.claude-agent` are refused even if you add them explicitly.
- **Local history, plain text by default** (mode `0600`, directory `0700`, no passphrase prompt);
  start with `--encrypt-history` to protect it with a passphrase plus an optional recovery
  question, or `--no-history` to keep nothing on disk.
- **It remembers you, and learns procedures** — durable facts live in
  `~/.claude-agent/memory.md` (plain text, mode 0600; `/remember` adds one, `/memory` shows and
  prunes). Write "how this kind of task should go" as Markdown in `~/.claude-agent/skills/`:
  the agent sees only a name and a one-line description, and reads the file when it fits.
- **Work from your phone (optional)** — WeCom (WeChat Work) "smart robot · long connection"
  needs only a BotID and a Secret: no public domain, no cloud account. Permissions are fixed
  when the service starts on the Mac, and anything needing confirmation is sent to your phone
  for a `y`/`n` answer. Feishu is supported in callback mode only (needs your own public URL).
- **Chinese by default** — English is available too (older Japanese UI strings are kept as-is
  and no new ones are added).

## Install

### 1. Download and run (no terminal)

1. Get `Advisor-v*-standalone.zip` from the
   [latest release](https://github.com/undersail/advisor/releases/latest) and unzip it
2. Drag `Advisor` into Applications (or the Dock)
3. **The first time only**, right-click (or Control-click) → Open → Open again.
   The build is not signed by an Apple Developer ID, so this is expected
4. On first launch you get an in-app key setup page: pick a provider → open its key page →
   paste the key. No terminal involved

The zip ships `ReadMe_ZH.txt` (Chinese) and `ReadMe_EN.txt` (English).

### 2. From source (terminal)

```bash
git clone https://github.com/undersail/advisor.git
cd advisor
bash setup.sh
```

`setup.sh` walks through: choose a provider → store the key → install the `advisor` command
and completion → build `Advisor.app` → run a connectivity test.

> **Do not run `setup.sh` with `sudo`.** It would leave `~/.claude-agent*` owned by root,
> and your normal user could no longer read them — which shows up as
> "I configured it, but it says nothing is configured".

## Quick start

```
advisor                     start a conversation
/model  or  ?               show the model list; type a number to switch
/key <provider>             set a provider's API key (the only in-session key entry)
/mode [mode]                show / switch the interaction mode
/allow-write <dir>          add a writable directory (repeatable)
/approvals                  last 10 auto-approvals
exit  or Ctrl-D             quit
```

Common startup flags:

```
advisor --mode=<default|accept-edits|bypass>   interaction mode
advisor --allow-write=<dir>                    add a writable directory (repeatable)
advisor --resume                               resume the last conversation
advisor --list-history                         list saved conversations
advisor --no-history                           do not save history this run
advisor --version                              version
```

In the GUI the header holds `[ Chat ] [ Command ]`, `[ Switch AI ]`, `[ Resume ]`, `[ Theme ]`,
plus a persistent badge showing the current mode.

## Supported providers

| Provider | In-session command | Key environment variable |
|---|---|---|
| Anthropic | `/claude` | `ANTHROPIC_API_KEY` |
| Google | `/gemini` | `GEMINI_API_KEY` |
| OpenAI | `/openai` | `OPENAI_API_KEY` |
| DeepSeek | `/deepseek` | `DEEPSEEK_API_KEY` |
| Qwen (Alibaba Cloud) | `/qwen` | `DASHSCOPE_API_KEY` |
| Kimi (Moonshot) | `/kimi` | `MOONSHOT_API_KEY` |
| GLM (Zhipu) | `/glm` | `ZHIPU_API_KEY` |

The last five use the OpenAI-compatible protocol. To add another compatible service, add a line
to `models.txt` with `provider` set to `openai`; to replace the endpoint entirely (your own proxy,
for example) set `CLAUDE_BASE_URL`.

> Built-in model ids are only convenient defaults — **always check the provider's own docs**.
> If one goes stale, edit `models.txt`.

## Where configuration and data live

| Item | Location |
|---|---|
| Providers and keys | `~/.claude-agent-env` (mode 0600, **must be owned by your user**) |
| Conversation history (encrypted) | `~/.claude-agent/history/` |
| Long-term memory (**plain text**) | `~/.claude-agent/memory.md` |
| Skills | `~/.claude-agent/skills/` |
| Remote allow-list / notifications | `~/.claude-agent/remote.conf` |
| WeCom long-connection credentials | `~/.claude-agent/wecom-ws.conf` |
| Remote audit log (append-only) | `~/.claude-agent/audit.log` |
| Installed artifacts (`advisor`, `Advisor.app`) | `~/claude-build/`, `~/bin/` |
| Model / provider tables | `models.txt`, `providers.txt` in the repo |

## Limitations

- **OS versions**: macOS 10.9 (Mavericks) through 10.13 (High Sierra) and newer.
  10.6–10.8 would need a self-built OpenSSL/curl and is **not supported**.
- **Not code-signed**: the distributed build is ad-hoc signed, so the first launch goes through
  right-click → Open.
- **Bring your own API keys**: no keys are included. You pay each provider directly;
  Gemini has a free tier that is enough to start.
- **A lost passphrase is unrecoverable**: if you forget both the passphrase and the recovery
  answer, saved conversations cannot be read — delete `~/.claude-agent/history/` and start over.
- **Remote access**: the WeCom long connection works. Feishu is callback-only (needs a publicly
  reachable URL); the Feishu long connection is not implemented.
- **Remote permissions are decided on the Mac**: the mode can only be chosen when the service
  starts and cannot be changed from the phone (`/mode` `/model` `/key` are all rejected).
  Only one remote service instance may run at a time; a second one exits immediately.
- **Older Japanese UI strings remain**: early builds shipped Japanese text. The default is now
  Chinese with English available, and nothing new is written in Japanese.

## License

[MIT License](LICENSE)
