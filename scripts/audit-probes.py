#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""反向探针：本轮新增/改动的每条卡口，都要在「植入被禁止的写法」时真的变红。

**这个脚本故意不进 CI**：它会临时修改源码再还原（污染工作区），只能在人工审计时
单独跑（`python3 scripts/audit-probes.py`，约 3 分钟）。审计方法第 3 条要求的就是它。



只做两件事：先跑一次确认绿；植入违规；再跑一次必须红；还原后再确认绿。
任何一步不符就报出来（探针本身失效 = 卡口是装饰品）。
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OK = FAIL = 0
FAILS = []


def sh(cmd, timeout=600):
    env = dict(os.environ)
    env.setdefault('DISPLAY', ':99')
    p = subprocess.run(cmd, cwd=ROOT, shell=isinstance(cmd, str),
                       capture_output=True, encoding='utf-8', errors='replace', timeout=timeout)
    return p.returncode, (p.stdout or '') + (p.stderr or '')


def check(name, ok, detail=''):
    global OK, FAIL
    if ok:
        OK += 1
        print('  ok   %s' % name)
    else:
        FAIL += 1
        FAILS.append(name)
        print('  FAIL %s  %s' % (name, detail[:300]))


def probe(label, path, old, new, cmd):
    """植入 old→new，确认 cmd 变红，再把文件还原。"""
    bak = '/tmp/probe_%s.bak' % os.path.basename(path)
    shutil.copy2(os.path.join(ROOT, path), bak)
    try:
        rc0, out0 = sh(cmd)
        check('%s：植入前是绿的' % label, rc0 == 0, out0[-300:])
        src = open(os.path.join(ROOT, path), encoding='utf-8').read()
        if src.count(old) != 1:
            check('%s：锚点唯一（%d 处）' % (label, src.count(old)), False)
            return
        with open(os.path.join(ROOT, path), 'w', encoding='utf-8') as f:
            f.write(src.replace(old, new, 1))
        rc1, out1 = sh(cmd)
        check('%s：植入违规后变红' % label, rc1 != 0, '仍然绿了 —— 卡口没拦住')
    finally:
        shutil.copy2(bak, os.path.join(ROOT, path))
        os.unlink(bak)
    rc2, out2 = sh(cmd)
    check('%s：还原后重新变绿' % label, rc2 == 0, out2[-300:])


print('=== 1. 解耦卡口：网关必须把 --no-config 传下去 ===')
probe('解耦 --no-config', 'remote/gateway.pl',
      """        open3($in, $out, $errh, 'perl', $AGENT, '--rpc', '--no-config',
              '--tools=' . join(',', @REMOTE_TOOLS));""",
      """        open3($in, $out, $errh, 'perl', $AGENT, '--rpc',
              '--tools=' . join(',', @REMOTE_TOOLS));""",
      ['python3', 'scripts/check-decoupling.py'])

print('=== 2. setup 卡口：不带引号的 heredoc 里不许有反引号 ===')
probe('heredoc 反引号', 'setup.sh',
      '  # “giving up after”必须有：没有它 display dialog 会一直等人点「好」，',
      '  # `giving up after` 必须有：没有它 display dialog 会一直等人点「好」，',
      ['python3', 'scripts/test-setup-py3.py'])

print('=== 3. 密钥策略：受限会话必须拒绝配置类命令 ===')
probe('--no-config 生效', 'agent/claude-agent.pl',
      '    if ($NO_CONFIG) {',
      '    if (0) {   # probe',
      ['python3', 'scripts/test-key-policy.py'])

print('=== 4. GUI 存密钥：必须用原子替换（文件只读也能写） ===')
probe('GUI 原子写入', 'gui/advisor_gui.py',
      '    write_env_atomic(keep)',
      '    with open(ENV_FILE_PATH, "w", encoding="utf-8") as f:   # probe\n        f.writelines(keep)',
      ['python3', 'scripts/test-gui-keyenv.py'])

print('=== 5. GUI 焦点：忙完后必须把焦点交回写作框 ===')
probe('GUI 焦点', 'gui/advisor_gui.py',
      """        if not busy:
            # 返信が終わったら入力欄へ戻す（毎回クリックさせない）
            self._focus_write_zone()""",
      """        if not busy:
            pass   # probe""",
      ['xvfb-run', '-a', 'python3', 'scripts/test-gui-modes.py'])

print()
if FAIL:
    print('%d/%d 通过，失败：%s' % (OK, OK + FAIL, '、'.join(FAILS)))
    sys.exit(1)
print('%d/%d 通过（每条卡口都验过"会红"）' % (OK, OK + FAIL))
