#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真正执行 ci.yml 里的每个 run 步骤（不做手抄复现），用于本地预演 CI。

${{ matrix.os }} 之类的表达式用占位值替换，仅影响那一条打印信息的措辞。
"""
import re
import subprocess
import sys

import yaml

wf = yaml.safe_load(open('.github/workflows/ci.yml', encoding='utf-8'))
OSES = ['ubuntu-latest', 'macos-latest']
fail = 0

for job_name, job in wf['jobs'].items():
    for os_name in OSES:
        print('=== job=%s os=%s ===' % (job_name, os_name))
        for st in job['steps']:
            name = st.get('name') or st.get('uses') or '(unnamed)'
            run = st.get('run')
            if not run:
                print('  ⏭  %s（非 run 步骤，跳过）' % name)
                continue
            script = re.sub(r'\$\{\{[^}]*\}\}', os_name, run)
            r = subprocess.run(['bash', '-e', '-c', script],
                               capture_output=True, text=True, cwd='.')
            ok = r.returncode == 0
            print(('  ✅ ' if ok else '  ❌ ') + name)
            if not ok:
                fail += 1
                for line in (r.stdout + r.stderr).strip().split('\n')[-10:]:
                    print('      ' + line)

print('\n结论：' + ('全部步骤通过 ✅' if fail == 0 else '%d 个步骤失败 ❌' % fail))
sys.exit(0 if fail == 0 else 1)
