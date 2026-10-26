#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""版本号与文档数字的防漂移卡口。

两件事：

1. **版本号只有一个来源** —— 仓库根目录的 `VERSION` 文件。
   agent 的 `--version`、setup.sh 生成的 Info.plist 与 wrapper、发布脚本打的
   zip 名、Release 的 tag，全部必须与它一致。历史上版本号散在 7 个地方
   （agent 一行、setup.sh 五处、构建脚本一处），改一处漏一处没人会报错。

2. **文档里写的条数必须是真的** —— 文案条数（%S / _S / msg()）、厂商数、
   模型数在文档里出现过多次，代码一改文档就腐。这里逐条对实际值。

    python3 scripts/check-version.py [-v]
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERBOSE = '-v' in sys.argv
errs = []
info = []


def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8') as f:
        return f.read()


# ---------------------------------------------------------------- 1. 版本
if not os.path.exists(os.path.join(ROOT, 'VERSION')):
    errs.append('缺少 VERSION 文件（版本号的唯一来源）')
    VERSION = None
else:
    VERSION = read('VERSION').strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', VERSION):
        errs.append('VERSION 内容不是 X.Y.Z 形态：%r' % VERSION)
    info.append('VERSION = %s' % VERSION)

if VERSION:
    # agent 的 --version 必须报同一个版本
    p = subprocess.run(['perl', os.path.join(ROOT, 'agent', 'claude-agent.pl'), '--version'],
                       capture_output=True, text=True, cwd=ROOT)
    out = (p.stdout or '').strip()
    if not out.endswith(VERSION):
        errs.append('`perl agent/claude-agent.pl --version` 输出 %r，结尾不是 %s' % (out, VERSION))
    else:
        info.append('--version 输出 = %s' % out)

    # setup.sh / 构建脚本里不许再出现版本字面量
    for path, pats in (
        ('setup.sh', [r'<string>\d+\.\d+\.\d+</string>', r'CFBundleVersion"\s*:\s*"\d+\.\d+'],
                     ),
        ('release/build_standalone_app.sh', [r'VERSION="\d+\.\d+']),
    ):
        try:
            body = read(path)
        except OSError:
            continue
        for pat in pats:
            for m in re.finditer(pat, body):
                line = body[:m.start()].count('\n') + 1
                errs.append('%s:%d 有写死的版本号 %r —— 应该读 VERSION' % (path, line, m.group(0)))

    # setup.sh 必须真的读了 VERSION
    if 'APP_VERSION="$(cat "$SCRIPT_DIR/VERSION"' not in read('setup.sh'):
        errs.append('setup.sh 没有从 VERSION 读取 APP_VERSION')

    # 发布 workflow 必须校验 tag 与 VERSION 一致
    rw = read('.github/workflows/release.yml')
    if 'VERSION' not in rw or '不一致' not in rw:
        errs.append('.github/workflows/release.yml 没有校验 tag 与 VERSION 一致')

# ---------------------------------------------------------------- 2. 文档数字
import importlib.util
_spec = importlib.util.spec_from_file_location('ci', os.path.join(ROOT, 'scripts', 'check-i18n.py'))
if _spec is None or _spec.loader is None:
    print('无法载入 scripts/check-i18n.py')
    sys.exit(1)
ci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ci)

n_perl = len(ci.perl_entries() or [])
n_gui = len(ci.gui_entries() or [])
setup_blocks = ci.setup_msg_blocks() or {}
n_msg = len(setup_blocks[0]) if setup_blocks else 0
providers = [l for l in read('providers.txt').split('\n')
             if l.strip() and not l.strip().startswith('#')]
models = [l for l in read('models.txt').split('\n')
          if l.strip() and not l.strip().startswith('#')]
info.append('实际: Perl=%d  GUI=%d  msg=%d  厂商=%d  模型=%d'
            % (n_perl, n_gui, n_msg, len(providers), len(models)))

dev_plan = read('docs/dev_plan.md')
design = read('docs/design_doc_advisor.md')
manual = read('docs/manual_test_mac.md')

checks = [
    ('dev_plan 的 %S 条数', dev_plan, r'\|\s*`agent/claude-agent\.pl`\s*→\s*`my %S`\s*\|\s*\*\*(\d+)\*\*', n_perl),
    ('dev_plan 的 _S 条数', dev_plan, r'\|\s*`gui/advisor_gui\.py`\s*→\s*`_S`\s*\|\s*\*\*(\d+)\*\*', n_gui),
    ('dev_plan 的 msg() 条数', dev_plan, r'`msg\(\)`\s*[^\n]*?实际\s*(\d+)\s*条', n_msg),
]
for name, body, pat, actual in checks:
    m = re.search(pat, body)
    if not m:
        errs.append('%s：文档里找不到这条（格式变了？卡口需要同步）' % name)
    elif int(m.group(1)) != actual:
        errs.append('%s：文档写 %s，实际 %d' % (name, m.group(1), actual))

# 手册里的模型条数
m = re.search(r'advisor --list-models[^\n]*?(\d+)\s*条', manual)
if m and int(m.group(1)) != len(models):
    errs.append('manual_test_mac 写 %s 条模型，实际 %d' % (m.group(1), len(models)))
m = re.search(r'/model`\s*\|\s*先列\s*\*\*(\d+)\s*家厂商\*\*', manual)
if m and int(m.group(1)) != len(providers):
    errs.append('manual_test_mac 写 %s 家厂商，实际 %d' % (m.group(1), len(providers)))

# design_doc 的 models.txt 列数（当前 7 列）
m = re.search(r'`models\.txt` 格式：[^\n]*', design)
if m:
    cols = m.group(0).count('|') + 1
    if cols != 7:
        errs.append('design_doc 的 models.txt 格式描述是 %d 列，应为 7' % cols)

# ---------------------------------------------------------------- 结果
if VERBOSE:
    for i in info:
        print('  ' + i)
if errs:
    print('版本/文档防漂移检查未通过：')
    for e in errs:
        print('  · ' + e)
    sys.exit(1)
print('版本与文档数字一致：%s' % '；'.join(info))
sys.exit(0)
