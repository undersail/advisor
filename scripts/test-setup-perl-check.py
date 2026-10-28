#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证 setup.sh 的 perl 自检：正常放行、坏文件在**写配置之前**停下。"""
import os
import re
import shutil
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ok = fail = 0


def check(name, cond, detail=''):
    global ok, fail
    if cond:
        ok += 1
        print('  ok   %s' % name)
    else:
        fail += 1
        print('  FAIL %s  %s' % (name, detail[:400]))


def run(repo, home, stdin=b''):
    env = {'HOME': home, 'PATH': '/usr/local/bin:/usr/bin:/bin',
           'CLAUDE_LANG': 'zh',          # 语言判定以 CLAUDE_LANG 最优先，锁定中文才好断言文案
           'TERM': 'dumb', 'ADVISOR_SETUP_VERBOSE': '1'}
    p = subprocess.run(['/bin/bash', os.path.join(repo, 'setup.sh')], input=stdin,
                       capture_output=True, env=env, timeout=180)
    return p.returncode, (p.stdout or b'').decode('utf-8', 'replace') + \
        (p.stderr or b'').decode('utf-8', 'replace')


# ---------- A. 坏 agent 文件：必须在写配置之前停下 ----------
tmp = tempfile.mkdtemp(prefix='perlc-bad-')
repo = os.path.join(tmp, 'repo')
home = os.path.join(tmp, 'home')
os.makedirs(home)
shutil.copytree(ROOT, repo, ignore=shutil.ignore_patterns('.git', '__pycache__', '.wrangler'))
agent = os.path.join(repo, 'agent', 'claude-agent.pl')
src = open(agent, encoding='utf-8').read()
# 注入一个**在本机 perl 上真的编译不过**的写法。
# 注意不能写 `use v5.36;` —— 本机是 5.38，那反而能编译通过，测不出失败路径。
open(agent, 'w', encoding='utf-8').write('my $broken = ;\n' + src)
rc, out = run(repo, home, b'4\n\n')
check('坏掉的 agent：安装中止（非 0 退出）', rc != 0, 'rc=%s out=%s' % (rc, out[-400:]))
check('坏掉的 agent：指出是 perl 编译不通过', '编译不通过' in out, out[-500:])
check('坏掉的 agent：报出本机 perl 版本', 'perl 是' in out or 'perl' in out, out[-300:])
check('坏掉的 agent：给出真实报错行（不能只说「坏了」）',
      re.search(r'syntax error|requires|Perl v5|near', out) is not None, out[-600:])
check('坏掉的 agent：没有写 ~/.claude-agent-env（不留半装状态）',
      not os.path.exists(os.path.join(home, '.claude-agent-env')))
check('坏掉的 agent：没有建 ~/bin/advisor',
      not os.path.exists(os.path.join(home, 'bin', 'advisor')))
shutil.rmtree(tmp, ignore_errors=True)

# ---------- B. 正常仓库：自检放行（后面没输入会自己退出，不算失败） ----------
tmp2 = tempfile.mkdtemp(prefix='perlc-ok-')
home2 = os.path.join(tmp2, 'home')
os.makedirs(home2)
rc2, out2 = run(ROOT, home2, b'')          # stdin 立即 EOF：走到选厂商那步会退出
check('正常仓库：perl 自检放行（没有报编译失败）', '编译不通过' not in out2, out2[-400:])
check('正常仓库：打印了本机 perl 版本（verbose 下）', 'perl 是' in out2, out2[-400:])
shutil.rmtree(tmp2, ignore_errors=True)

print('\n%d/%d 通过' % (ok, ok + fail))
raise SystemExit(1 if fail else 0)
