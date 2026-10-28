#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GUI 保存密钥的权限路径（真机报障：「.claude 文件没权限」）。

在独立子进程里 import gui/advisor_gui.py（它的 ENV_FILE_PATH 在 import 时
按 HOME 算好），分三种情况验证：
  A. 配置文件 0400（模拟别的用户建的 / 只读）→ 仍应写成功（目录可写即可）
  B. 目录只读 → 应抛 RuntimeError，且文案里带路径、属主、权限、修复命令
  C. 正常情况 → 内容正确、权限 600
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = r'''
import os, sys, stat
sys.path.insert(0, os.path.join(%r, "gui"))
import advisor_gui as G

def lines_of(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

case = sys.argv[1]
envp = G.ENV_FILE_PATH
if case == "readonly_file":
    with open(envp, "w", encoding="utf-8") as f:
        f.write("export DEEPSEEK_API_KEY=old\n")
    os.chmod(envp, 0o400)
    G.save_onboard_env("deepseek", "sk-new-1234")
    print("WROTE")
    print(lines_of(envp))
    print("MODE", oct(os.stat(envp).st_mode & 0o777))
elif case == "readonly_dir":
    with open(envp, "w", encoding="utf-8") as f:
        f.write("export DEEPSEEK_API_KEY=old\n")
    os.chmod(os.path.dirname(envp), 0o500)
    try:
        G.save_onboard_env("deepseek", "sk-new-1234")
        print("NO_ERROR")
    except RuntimeError as e:
        print("ERROR_TEXT")
        print(str(e))
    finally:
        os.chmod(os.path.dirname(envp), 0o700)
else:
    G.save_onboard_env("deepseek", "sk-new-1234")
    print("WROTE")
    print(lines_of(envp))
    print("MODE", oct(os.stat(envp).st_mode & 0o777))
''' % (ROOT,)

PASS = FAIL = 0
FAILS = []


def check(name, ok, detail=None):
    global PASS, FAIL
    if ok:
        PASS += 1
        print('  ok   %s' % name)
    else:
        FAIL += 1
        FAILS.append(name)
        print('  FAIL %s%s' % (name, ('  <- ' + str(detail)) if detail else ''))
        if os.environ.get('CI'):
            print('::error::test-gui-keyenv 失败：%s %s' % (name, detail or ''))


def run(case):
    home = tempfile.mkdtemp(prefix='guikey-')
    env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE_')}
    env['HOME'] = home
    p = subprocess.run([sys.executable, '-c', SCRIPT, case], env=env,
                       capture_output=True, encoding='utf-8', errors='replace', timeout=60)
    out = (p.stdout or '') + (p.stderr or '')
    if case in ('readonly_file', 'readonly_dir'):
        os.chmod(home, 0o700)
        for root, dirs, files in os.walk(home):
            for d in dirs:
                try:
                    os.chmod(os.path.join(root, d), 0o700)
                except OSError:
                    pass
    shutil.rmtree(home, ignore_errors=True)
    return out


print('::notice::配置文件只读（模拟别的用户建的 ~/.claude-agent-env）')
out = run('readonly_file')
check('文件 0400 时 GUI 仍能写入（靠临时文件 + 原子替换）', 'WROTE' in out, out[-300:])
check('写入后权限回到 0600', 'MODE 0o600' in out, out[-200:])
check('写进去的是新的那把 key', 'sk-new-1234' in out, out[-300:])

print('::notice::目录不可写')
out2 = run('readonly_dir')
check('目录不可写时报错而不是静默失败', 'ERROR_TEXT' in out2, out2[-300:])
check('报错里给出路径', '.claude-agent-env' in out2)
check('报错里给出属主与权限', 'owner' in out2 or '属主' in out2 or '/' in out2)
check('报错里给出修复命令（sudo rm）', 'sudo rm' in out2, out2[-300:])

print('::notice::正常情况')
out3 = run('plain')
check('正常写入并落盘', 'sk-new-1234' in out3 and 'MODE 0o600' in out3, out3[-300:])

print()
if FAIL:
    print('%d/%d 通过，失败：%s' % (PASS, PASS + FAIL, ', '.join(FAILS)))
    sys.exit(1)
print('%d/%d 通过' % (PASS, PASS + FAIL))
