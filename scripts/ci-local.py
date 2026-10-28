#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真正执行 ci.yml 里的每个 run 步骤（不做手抄复现），用于本地预演 CI。

${{ matrix.os }} 之类的表达式用占位值替换，仅影响那一条打印信息的措辞。

`--pristine`：用一个**干净环境**跑每一步（最小 PATH + 临时 HOME，不继承
TMPDIR / CLAUDE_* / 代理）。为什么要它：本机预演绿、CI 红的情况，几乎都是
测试悄悄依赖了本机环境 —— 例如把「范围外」的目录建在 /tmp 下，而本机 TMPDIR
指向别处，于是同一个断言在云端就翻了（真实发生过一次）。

    python3 scripts/ci-local.py             # 常规预演（用当前 shell 环境）
    python3 scripts/ci-local.py --pristine  # 模拟 runner 的干净环境
    python3 scripts/ci-local.py --only 交互模式
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

import yaml

ap = argparse.ArgumentParser()
ap.add_argument('--pristine', action='store_true',
                help='用干净环境执行（更接近 GitHub runner）')
ap.add_argument('--only', default='', help='只跑名字里含该子串的步骤')
args = ap.parse_args()

wf = yaml.safe_load(open('.github/workflows/ci.yml', encoding='utf-8'))
OSES = ['ubuntu-latest', 'macos-15-intel']   # 与 ci.yml 的矩阵保持一致（见那里的注释）
fail = 0
ran = 0
skipped = 0


def clean_env():
    """runner 上的最小环境。故意不含 TMPDIR / CLAUDE_* / 代理等本机变量。"""
    home = tempfile.mkdtemp(prefix='ci-local-home-')
    return {
        'HOME': home,
        'PATH': '/usr/local/bin:/usr/bin:/bin',
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
        'SHELL': '/bin/bash',
        'GITHUB_ACTIONS': 'true',
    }


for job_name, job in wf['jobs'].items():
    for os_name in OSES:
        print('=== job=%s os=%s ===' % (job_name, os_name))
        for st in job['steps']:
            name = st.get('name') or st.get('uses') or '(unnamed)'
            run = st.get('run')
            if not run:
                skipped += 1
                print('  ⏭  %s（非 run 步骤，跳过）' % name)
                continue
            if args.only and args.only not in name:
                skipped += 1
                continue
            script = re.sub(r'\$\{\{[^}]*\}\}', os_name, run)
            env = clean_env() if args.pristine else None
            r = subprocess.run(['bash', '-e', '-c', script],
                               capture_output=True, text=True, cwd='.',
                               env=env, stdin=subprocess.DEVNULL)
            ok = r.returncode == 0
            ran += 1
            print(('  ✅ ' if ok else '  ❌ ') + name)
            if not ok:
                fail += 1
                for line in (r.stdout + r.stderr).strip().split('\n')[-12:]:
                    print('      ' + line)

mode = '（pristine 干净环境）' if args.pristine else ''
print('\n结论%s：%s' % (mode, '全部步骤通过 ✅' if fail == 0 else '%d 个步骤失败 ❌' % fail))
print('执行 %d 步，跳过 %d 步' % (ran, skipped))
sys.exit(0 if fail == 0 else 1)
