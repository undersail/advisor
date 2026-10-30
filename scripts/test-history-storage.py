#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""历史存储方式（v0.2.5 起默认明文、加密可选）的测试。

要守住的是三条容易被改回去的约定：
  ① **默认不问口令**，会话以明文 `*.json` 存，权限 0600、目录 0700；
  ② **不悄悄降级**：目录里已经有 key.enc / *.json.enc 时，仍然走口令流程；
  ③ **可以要加密**：`--encrypt-history` 回到口令流程，且明文模式下的
     `--change-passphrase` / `--set-recovery` 给出明确说明而不是崩掉。
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_harness as H

SCRIPT = H.Script()


def run_cli(home, *args, extra=None):
    """直接跑一次 agent（不走 RPC），用来验 --list-history / --change-passphrase。"""
    env = {
        'HOME': home,
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'CLAUDE_PROVIDER': 'deepseek',
        'DEEPSEEK_API_KEY': 'dummy-key-for-tests',
        'CLAUDE_LANG': 'zh',
        'TERM': 'dumb',
        'TMPDIR': os.path.join(home, 'tmpdir'),
    }
    env.pop('CLAUDE_HIST_PASS', None)
    if extra:
        env.update(extra)
    os.makedirs(env['TMPDIR'], exist_ok=True)
    p = subprocess.run(['perl', H.AGENT] + list(args), env=env, cwd=home,
                       capture_output=True, text=True, timeout=120)
    return p.returncode, (p.stdout or '') + (p.stderr or '')


def session_files(hist_dir, suffix):
    if not os.path.isdir(hist_dir):
        return []
    return sorted(f for f in os.listdir(hist_dir) if f.endswith(suffix))


def main():
    if not os.path.exists(H.AGENT):
        H.check(False, 'agent 存在', H.AGENT)
        return H.finish('history')

    work = tempfile.mkdtemp(prefix='hist-')
    srv, base = H.make_server(SCRIPT)
    try:
        home = os.path.join(work, 'home')
        os.makedirs(home)
        hist = os.path.join(home, '.claude-agent', 'history')

        # ---- A) 默认：明文保存，不问口令
        a = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'})
        H.check(a.hello is not None, '默认模式能正常握手')
        H.check((a.hello or {}).get('history') == 1,
                '默认模式历史是开启的（不必先输口令）', str(a.hello)[:200])
        a.turn('第一句：记住这次对话')
        files = session_files(hist, '.json')
        H.check(len(files) == 1, '默认生成一个 *.json 明文会话文件', str(os.listdir(hist) if os.path.isdir(hist) else []))
        H.check(session_files(hist, '.json.enc') == [], '默认不生成 *.json.enc')
        path = os.path.join(hist, files[0]) if files else ''
        if path:
            mode = oct(os.stat(path).st_mode & 0o777)
            H.check(mode == '0o600', '明文会话文件权限 0600', mode)
            body = open(path, encoding='utf-8').read()
            H.check('第一句' in body, '明文里能直接读到对话内容', body[:120])
        dir_mode = oct(os.stat(hist).st_mode & 0o777) if os.path.isdir(hist) else ''
        H.check(dir_mode == '0o700', '历史目录权限 0700', dir_mode)
        a.stop()

        # ---- B) 再来一次能列出上一场（不需要口令）
        rc, out = run_cli(home, '--list-history')
        H.check(rc == 0, '--list-history 退出码 0', out[:200])
        H.check('明文' in out, '--list-history 说明当前是明文保存', out[:200])
        H.check('第一句' in out, '--list-history 能列出上一场对话（不用口令）', out[:300])

        # ---- C) --no-history：什么都不写
        before = len(session_files(hist, '.json'))
        a = H.Agent(home, base)     # harness 默认就带 CLAUDE_NO_HISTORY=1
        H.check((a.hello or {}).get('history') == 0, '--no-history 时历史是关的', str(a.hello)[:160])
        a.turn('这场不该落盘')
        a.stop()
        H.check(len(session_files(hist, '.json')) == before, '--no-history 真的一个文件都不写')

        # ---- D) 不悄悄降级：目录里有 key.enc 时仍走口令流程
        home2 = os.path.join(work, 'home2')
        hist2 = os.path.join(home2, '.claude-agent', 'history')
        os.makedirs(hist2)
        open(os.path.join(hist2, 'key.enc'), 'w').write('placeholder')
        rc, out = run_cli(home2, '--list-history')
        H.check('明文' not in out, '已有加密历史时不进明文模式（不悄悄降级）', out[:200])
        H.check('口令' in out, '已有加密历史时仍然问口令', out[:200])

        # ---- E) 孤儿 *.json.enc（没有 key.enc）：仍然按明文模式走
        # 那些文件本来就没有主密钥、谁也解不开；若因为它们把会话拖回口令流程，
        # 已经切到明文的用户会莫名其妙被要口令（这个坑测试里踩到过）。
        home3 = os.path.join(work, 'home3')
        hist3 = os.path.join(home3, '.claude-agent', 'history')
        os.makedirs(hist3)
        open(os.path.join(hist3, '20260101-000000.json.enc'), 'w').write('x')
        rc, out = run_cli(home3, '--list-history')
        H.check('明文' in out, '只剩孤儿 *.json.enc 时仍是明文模式（不被拖回口令）', out[:200])
        H.check('key.enc' in out, '并告诉用户那些加密文件要怎么打开', out[:300])

        # ---- F) --encrypt-history：回到口令流程
        home4 = os.path.join(work, 'home4')
        os.makedirs(home4)
        rc, out = run_cli(home4, '--encrypt-history', '--list-history')
        H.check('口令' in out and '明文' not in out,
                '--encrypt-history 走设口令流程', out[:240])

        # ---- G) 明文模式下的 --change-passphrase / --set-recovery 给明确说明
        rc, out = run_cli(home, '--change-passphrase')
        H.check(rc == 0, '明文模式下 --change-passphrase 正常退出（不是崩）', 'rc=%d %s' % (rc, out[:160]))
        H.check('没有口令可改' in out, '明文模式 --change-passphrase 说明没有口令', out[:200])
        rc, out = run_cli(home, '--set-recovery')
        H.check(rc == 0, '明文模式下 --set-recovery 正常退出', 'rc=%d %s' % (rc, out[:160]))
        H.check('没有密保问题' in out, '明文模式 --set-recovery 说明没有密保', out[:200])

        # ---- H) 两种格式混在：不崩，且能列出明文那一条
        open(os.path.join(hist, '20200101-000000.json.enc'), 'w').write('not-decryptable')
        rc, out = run_cli(home, '--list-history')
        H.check(rc == 0, '明文与加密文件混在时 --list-history 不崩', 'rc=%d %s' % (rc, out[:200]))
        H.check('第一句' in out, '混在时仍然列出明文那条', out[:300])
    finally:
        try:
            srv.shutdown()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)

    return H.finish('history')


if __name__ == '__main__':
    sys.exit(main())
