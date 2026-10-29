#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""远程能力与本地核心的「解耦」卡口。

为什么要有这道检查：
    远程模式靠「核心的两个通用能力（--tools 收窄、--no-config 不许改配置）」实现，而不是往核心
    里塞 `if ($REMOTE) { ... }`。一旦有人为了省事在核心加远程分支，本地
    行为就会跟着远程的安全设定走 —— 那是不可接受的耦合。
    这道检查把那条界写死成机器可判的形式。

    python3 scripts/check-decoupling.py       # 通过 exit 0
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, 'agent', 'claude-agent.pl')
PLATFORM = os.path.join(ROOT, 'remote', 'platform.pl')
GATEWAY = os.path.join(ROOT, 'remote', 'gateway.pl')
NOTIFY = os.path.join(ROOT, 'remote', 'notify.pl')
WECOM_WS = os.path.join(ROOT, 'remote', 'wecom-ws.pl')

errs = []


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def perl_code_only(src):
    """去掉行尾注释：# 之后的内容。注释里提到 remote.conf / 白名单 是正常说明，不算违规。"""
    out = []
    for line in src.split('\n'):
        i = line.find('#')
        out.append(line if i < 0 else line[:i])
    return '\n'.join(out)


core = read(CORE)
gw = read(GATEWAY)
plat = read(PLATFORM)
note = read(NOTIFY)
wecom_ws = read(WECOM_WS) if os.path.exists(WECOM_WS) else ''

# 1) 核心里不能出现远程开关/远程字样（注释也算，免得被"顺手"接上）
for pat in (r'\$REMOTE\w*', r'remote/', r'REMOTE_TOOLS',
            r'aibot_', r'openws\.work\.weixin', r'WebSocket'):
    m = re.search(pat, core)
    if m:
        line = core[:m.start()].count('\n') + 1
        errs.append('核心 agent/claude-agent.pl 第 %d 行出现 %r —— 远程逻辑必须留在 remote/ 里'
                    % (line, m.group(0)))

# 2) 核心必须只有「通用能力过滤」，且是收窄语义
if '@TOOLS_ALLOWED' not in core:
    errs.append('核心缺少 @TOOLS_ALLOWED（--tools 通用过滤）')
if re.search(r"unlink|rmtree", core) and 'TOOLS_ALLOWED' not in core:
    errs.append('核心的工具过滤不见了')

# 3) 网关注入给 agent 的能力必须写死成只读
m = re.search(r'my\s+@REMOTE_TOOLS\s*=\s*qw\(([^)]*)\)', gw)
if not m:
    errs.append('remote/gateway.pl 缺少 `my @REMOTE_TOOLS = qw(...)` 这一行')
else:
    tools = m.group(1).split()
    bad = [t for t in tools if t not in ('read_file', 'list_dir')]
    if bad:
        errs.append('远程允许的工具里出现了写/执行类：%s（远程没有人按 y/n，只允许 read_file / list_dir）'
                    % ', '.join(bad))
    if 'read_file' not in tools:
        errs.append('远程允许的工具里没有 read_file，等于什么都干不了')

# 4) 工具集不能被配置覆盖
if re.search(r"\$conf->\{TOOLS\}|conf->\{ALLOW_TOOLS\}|ALLOW_TOOLS", gw):
    errs.append('remote/gateway.pl 里出现了可配置的工具集 —— 只读必须写死，不做开关')

# 5) 网关必须真的把 --tools 传下去（连写形式，核心两种都认）
if "--tools=" not in gw:
    errs.append('remote/gateway.pl 没有把 --tools=... 传给 agent，能力收窄不会生效')
# 6) 网关必须把 --no-config 传下去：远程只对话，厂商/模型/模式/密钥都在本机配
if "'--no-config'" not in gw:
    errs.append('remote/gateway.pl 没有把 --no-config 传给 agent，远程就能改配置/收密钥了')
if '--no-config' not in core:
    errs.append('核心缺少 --no-config（受限会话不许改配置）')

# 6) 远程历史目录必须写死在网关里，且与本地不同名
if 'history-remote' not in gw:
    errs.append('remote/gateway.pl 没有把历史目录固定成 history-remote')
if re.search(r"HISTORY_DIR\s*=\s*\$conf", gw):
    errs.append('远程历史目录被做成可配置了')

# 7) 档① 通知：URL 是凭据，不能进命令行参数
notify = read(NOTIFY)
if not re.search(r"'-K'\s*,\s*'-'", notify):
    errs.append('remote/notify.pl 没有用 curl -K - 从 stdin 喂配置（URL 会出现在 ps 里）')
if re.search(r"exec\([^)]*\$url\s*,", notify):
    errs.append('remote/notify.pl 把 webhook URL 当命令行参数传了')

# 8) 审计日志必须只追加（只看 AUDIT_PATH 那一次 open，别把临时文件的写当审计）
audit_opens = re.findall(r"open\([^;]*\$AUDIT_PATH[^;]*\)", gw)
if not audit_opens:
    errs.append('remote/gateway.pl 里找不到对 $AUDIT_PATH 的 open')
elif not all("'>>" in a for a in audit_opens):
    errs.append('remote/gateway.pl 的审计日志不是追加打开（只追加才有意义）')

# 9) 企微长连接（API 模式）客户端：只做传输，判定一律复用网关
wecom_ws_code = perl_code_only(wecom_ws)
if wecom_ws:
    if "'--stdin'" not in wecom_ws_code:
        errs.append('remote/wecom-ws.pl 没有把消息交给 gateway.pl --stdin —— 白名单/只读/审计不许自己重新实现一遍')
    # 自己读白名单配置 = 把判定权从网关手里抢走了（注释里出现「白名单」三个字不算）
    # 只认「真去取白名单这个键」的写法：文案里提到 remote.conf 是正常提示，不算违规
    if re.search(r'\{ALLOW\}', wecom_ws_code):
        errs.append('remote/wecom-ws.pl 在自己读白名单（{ALLOW} / remote.conf）—— 判定权只该在 gateway.pl 手里')
    for pat in (r'--mode\b', r'--allow-write', r'\$?CLAUDE_MODE'):
        if re.search(pat, wecom_ws_code):
            errs.append('remote/wecom-ws.pl 里出现了 %s —— 远程只有对话，不带交互模式' % pat)
    # 只读工具集不许在这里出现（那是网关的事，出现说明有人在绕开网关自己起 agent）
    if re.search(r'claude-agent\.pl', wecom_ws_code):
        errs.append('remote/wecom-ws.pl 直接起了 agent（应经 gateway.pl）')

# --- 交互模式（--mode / --allow-write）はローカルの都合。远程には流さない ---
# bypass は「その場に居る人が結果を引き受ける」前提のトレードオフ。遠隔は
# 「ホワイトリストの誰かが携帯から一言」なので、同じ緩め方を共有してはいけない。
for name, body in (('remote/gateway.pl', gw), ('remote/platform.pl', plat),
                   ('remote/notify.pl', note)):
    if body == '':
        continue
    for pat in (r'--mode\b', r'--mode=', r'--allow-write', r'CLAUDE_MODE', r'CLAUDE_ALLOW_WRITE'):
        if re.search(pat, body):
            errs.append('%s 里出现了 %s —— 交互模式 / 可写范围是本地专用，不传给远程'
                        % (name, pat))

if errs:
    print('解耦检查未通过：')
    for e in errs:
        print('  · ' + e)
    sys.exit(1)

print('解耦检查通过：核心只有 --tools 收窄与 --no-config 两个通用能力；'
      '远程逻辑全在 remote/；远程工具写死只读、只对话；长连接客户端只做传输、判定复用网关')
sys.exit(0)
