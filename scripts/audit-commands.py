#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""命令可达性审计：每个厂商命令 / 别名是否真的切到了对应厂商。

必须用 PTY：管道里一次喂多行会被读成一整块（项目已知坑），
那样 `"/deepseek\\nexit\\n"` 会被当成一句普通发言，测出来全是默认厂商。

    python3 scripts/audit-commands.py [-v]
"""
import os
import pty
import re
import select
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, 'agent', 'claude-agent.pl')
VERBOSE = '-v' in sys.argv

# 命令 → 期望出现的密钥变量名（说明确实切到了那家）
CASES = [
    ('claude',  'ANTHROPIC_API_KEY'),
    ('gemini',  'GEMINI_API_KEY'),
    ('openai',  'OPENAI_API_KEY'),
    ('deepseek', 'DEEPSEEK_API_KEY'),
    ('qwen',    'DASHSCOPE_API_KEY'),
    ('tongyi',  'DASHSCOPE_API_KEY'),      # 别名
    ('kimi',    'MOONSHOT_API_KEY'),
    ('glm',     'ZHIPU_API_KEY'),
    # 直接厂商名也应可达（与别名并存）
    ('anthropic', 'ANTHROPIC_API_KEY'),
    ('dashscope', 'DASHSCOPE_API_KEY'),
    ('moonshot',  'MOONSHOT_API_KEY'),
    ('zhipu',     'ZHIPU_API_KEY'),
]


def run_command(cmd, home, with_key=False):
    """在 PTY 里发一条 /cmd，等它的回显，再退出。返回命令之后的文本。"""
    env = dict(os.environ)
    env.update({'HOME': home, 'CLAUDE_LANG': 'zh', 'CLAUDE_NO_HISTORY': '1'})
    for k in list(env):
        if k.endswith('_API_KEY'):
            env.pop(k)
    # 默认厂商（anthropic）没有 key 时 agent 启动就退出，根本没有提示符 ——
    # 给一个假 key 让它进交互循环。不会真的发请求：只切厂商不说话。
    # 第一相（with_key=False）只给默认厂商，验「命令路由是否正确」；
    # 第二相（with_key=True）给全部厂商假 key，验「是否真的切过去」。
    env['ANTHROPIC_API_KEY'] = 'sk-audit-dummy'
    if with_key:
        for k in ('GEMINI_API_KEY', 'OPENAI_API_KEY', 'DEEPSEEK_API_KEY',
                  'DASHSCOPE_API_KEY', 'MOONSHOT_API_KEY', 'ZHIPU_API_KEY'):
            env[k] = 'sk-audit-dummy'
    pid, fd = pty.fork()
    if pid == 0:                                  # child
        os.execve('/usr/bin/perl', ['perl', AGENT], env)
        os._exit(127)

    buf = ''

    def pump(seconds, quiet=0.8):
        """读输出。收到过数据后，连续 quiet 秒没有新数据就提前返回（上限仍是 seconds）。

        原来是盲等满 seconds，27 个用例白白烧掉 4 分钟（CI 里这一步占 ubuntu 腿 73%）。
        没收到任何数据时行为与以前一致：等满上限，不会提前走。
        """
        nonlocal buf
        deadline = time.time() + seconds
        last = time.time()
        got = False
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                if got and time.time() - last >= quiet:
                    return True
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            buf += chunk.decode('utf-8', 'replace')
            last = time.time()
            got = True
        return True

    try:
        pump(6, quiet=1.2)                         # 启动横幅 / 提示符
        mark = len(buf)                            # ★ 记下命令之前的位置
        os.write(fd, ('/%s\n' % cmd).encode())
        pump(3)
        # 缺 key 的厂商会插「粘贴 key」提示；随后可能再问「是否保存」。
        # 一律用空行/不保存把它带过去（绝不写任何真 key）。
        for _ in range(3):
            seg = buf[mark:]
            if '尚未设置' in seg and not re.search(r'已切换|已经', seg):
                os.write(fd, b'\n')
            elif '[y/N]' in seg and not re.search(r'已切换|已经', seg):
                os.write(fd, b'n\n')
            else:
                break
            pump(2, quiet=0.6)
        os.write(fd, b'exit\n')
        pump(3)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    text = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', buf)
    # 只保留「发了命令之后」的部分：启动横幅里的默认厂商提示不算
    return text[mark:]


def menu_lines(home, steps, with_key=False, seconds=3):
    """在 PTY 里按顺序喂 steps（如 ['/model', '2']），返回整段回显。

    菜单要 models.txt 才知道有哪些模型：走 CLAUDE_MODELS_FILE 指到仓库里那份
    （setup.sh 装好之后指的是 ~/.claude-agent/models.txt）。
    """
    env = dict(os.environ)
    env.update({'HOME': home, 'CLAUDE_LANG': 'zh', 'CLAUDE_NO_HISTORY': '1',
                'CLAUDE_MODELS_FILE': os.path.join(ROOT, 'models.txt'),
                'CLAUDE_PROVIDERS_FILE': os.path.join(ROOT, 'providers.txt')})
    for k in list(env):
        if k.endswith('_API_KEY'):
            env.pop(k)
    env['ANTHROPIC_API_KEY'] = '\u00abredacted:sk-\u2026\u00bb'
    if with_key:
        for k in ('GEMINI_API_KEY', 'OPENAI_API_KEY', 'DEEPSEEK_API_KEY',
                  'DASHSCOPE_API_KEY', 'MOONSHOT_API_KEY', 'ZHIPU_API_KEY'):
            env[k] = '\u00abredacted:sk-\u2026\u00bb'
    pid, fd = pty.fork()
    if pid == 0:
        os.execve('/usr/bin/perl', ['perl', AGENT], env)
        os._exit(127)
    buf = ''

    def pump(sec, quiet=0.8):
        """同上：有输出后静默 quiet 秒即返回，没输出就等满 sec。"""
        nonlocal buf
        deadline = time.time() + sec
        last = time.time()
        got = False
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if not r:
                if got and time.time() - last >= quiet:
                    return
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk.decode('utf-8', 'replace')
            last = time.time()
            got = True

    try:
        pump(6, quiet=1.2)
        for st in steps:
            os.write(fd, (st + '\n').encode())
            pump(seconds)
        os.write(fd, b'exit\n')
        pump(2)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    return re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', buf)


def main():
    home = tempfile.mkdtemp(prefix='audit-cmd-')
    bad = 0
    print('第一相：命令路由（只给默认厂商 key，缺 key 时应显示对的那家的密钥页）')
    for cmd, key_env in CASES:
        out = run_command(cmd, home, with_key=False)
        ok = key_env in out or ('已经是 [' in out)
        if VERBOSE:
            print('  %-8s → %s   [%s]' % (cmd, 'ok' if ok else 'FAIL',
                                          ' '.join(out.split())[:80]))
        else:
            print('  %s /%s' % ('ok  ' if ok else 'FAIL', cmd))
        if not ok:
            bad += 1

    print('\n第二相：真正切换（七家都给假 key，应出现切换确认）')
    want_of = {'claude': 'anthropic', 'gemini': 'gemini', 'openai': 'openai',
               'deepseek': 'deepseek', 'qwen': 'dashscope', 'tongyi': 'dashscope',
               'kimi': 'moonshot', 'glm': 'zhipu',
               'anthropic': 'anthropic', 'dashscope': 'dashscope',
               'moonshot': 'moonshot', 'zhipu': 'zhipu'}
    for cmd, _ in CASES:
        want = want_of[cmd]
        out = run_command(cmd, home, with_key=True)
        ok = ('→ 已切换到 [%s' % want) in out or ('已经是 [%s' % want) in out
        if VERBOSE:
            print('  %-8s → %-10s %s   [%s]' % (cmd, want, 'ok' if ok else 'FAIL',
                                                ' '.join(out.split())[:80]))
        else:
            print('  %s /%s → %s' % ('ok  ' if ok else 'FAIL', cmd, want if ok else '未切到'))
        if not ok:
            bad += 1

    total = len(CASES) * 2

    # ---------------- 第三相：菜单要先把「没有密钥」说出来 ----------------
    # 真实反馈：连续对话里 /model 列出 7 个厂商，选了 Anthropic 才弹
    # 「ANTHROPIC_API_KEY 尚未设置」，看着像报错。列表不标注就等于挖坑。
    print('\n第三相：菜单标注（没配密钥的厂商要事先标出来）')
    menu = menu_lines(home, ['/model'], with_key=False)
    ok = True
    for name, has_key in (('Anthropic (Claude)', True), ('Google (Gemini)', False),
                          ('OpenAI', False), ('通义千问', False)):
        line = next((l for l in menu.splitlines() if name in l), '')
        marked = '[未配置密钥]' in line
        good = (not marked) if has_key else marked
        if not good:
            ok = False
            if VERBOSE:
                print('    %s 应有 key=%s 实际=%r' % (name, has_key, line.strip()))
    print('  %s 厂商列表标注未配密钥' % ('ok  ' if ok else 'FAIL'))
    bad += 0 if ok else 1
    total += 1

    ok2 = '← 使用中' in menu
    print('  %s 列表仍标出当前厂商' % ('ok  ' if ok2 else 'FAIL'))
    bad += 0 if ok2 else 1
    total += 1

    deep = menu_lines(home, ['/model', '2'], with_key=False)   # 2 = 第二家（gemini）
    ok3 = '还没有配置密钥' in deep and 'GEMINI_API_KEY' in deep
    if VERBOSE:
        print('    [%s]' % ' '.join(deep.split())[-160:])
    print('  %s 进到没密钥的厂商会先说明（含环境变量名）' % ('ok  ' if ok3 else 'FAIL'))
    bad += 0 if ok3 else 1
    total += 1

    print('\n%d/%d 通过' % (total - bad, total))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
