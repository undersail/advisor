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


def run_cli(home, *args, extra=None, stdin_text=None):
    """直接跑一次 agent（不走 RPC），用来验 --list-history / --change-passphrase。

    stdin_text 是给「设口令」这类交互步骤喂答案用的（--encrypt-history 要连输两遍）。
    """
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
                       capture_output=True, text=True, timeout=180,
                       input=stdin_text if stdin_text is not None else '')
    return p.returncode, (p.stdout or '') + (p.stderr or '')


def session_files(hist_dir, suffix):
    if not os.path.isdir(hist_dir):
        return []
    return sorted(f for f in os.listdir(hist_dir) if f.endswith(suffix))


def case_local_only_no_key(tmp, base):
    """本地维护命令不联网，就不该要 API key（用户实际踩到的一次）。"""
    print('[维护命令] 没有 API key 也能转明文 / 列历史')
    home = os.path.join(tmp, 'home-nokey')
    os.makedirs(os.path.join(home, '.claude-agent', 'history'), exist_ok=True)
    os.makedirs(os.path.join(home, 'tmpdir'), exist_ok=True)
    # 只放一个「解不开的」密文 + 钥匙，用来看命令有没有被 key 挡住
    open(os.path.join(home, '.claude-agent', 'history', 'x.json.enc'), 'w').write('nope')
    open(os.path.join(home, '.claude-agent', 'key.enc'), 'w').write('nope-key')
    env = {'CLAUDE_PROVIDER': 'anthropic'}      # 没有 ANTHROPIC_API_KEY
    rc, out = run_cli(home, '--list-history', extra=env)
    H.check('请设置' not in out, '没有 key 时 --list-history 不被「请设置」挡住', out[:200])
    rc2, out2 = run_cli(home, '--make-plain-history', extra=env, stdin_text='whatever\n')
    H.check('请设置' not in out2, '没有 key 时 --make-plain-history 也不被挡住', out2[:200])
    H.check(('口令' in out2 or '打不开' in out2) and '请设置' not in out2,
            '钥匙不对时说的是历史打不开（不是 key 的问题）', out2[:200])


def main():
    if not os.path.exists(H.AGENT):
        H.check(False, 'agent 存在', H.AGENT)
        return H.finish('history')

    work = tempfile.mkdtemp(prefix='hist-')
    srv, base = H.make_server(SCRIPT)
    try:
        case_local_only_no_key(work, base)

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

        # ---- I) --make-plain-history：已有的加密历史转成明文，之后不再问口令
        print('[缺陷3] 已有 key.enc 的机器要能一次性转成明文')
        home6 = os.path.join(work, 'home6')
        os.makedirs(home6)
        hist6 = os.path.join(home6, '.claude-agent', 'history')

        # 明文环境里先跑一次，应该明确说「不需要转换」
        rc, out = run_cli(home6, '--make-plain-history')
        H.check(rc == 0 and '不需要转换' in out,
                '没有加密历史时说「不需要转换」并正常退出', out[:200])

        # 设一遍口令（两遍一致 + 不要密保问题），造出 key.enc
        rc, out = run_cli(home6, '--encrypt-history', '--list-history',
                          stdin_text='pw-for-test\npw-for-test\nn\n')
        H.check(os.path.isfile(os.path.join(hist6, 'key.enc')),
                '口令流程真的写出了 key.enc（后面的用例才有意义）', out[:200])

        # 造一个**真的**加密会话（用 key.enc 里的主密钥直接加密一段 JSON），
        # 这样才验得到「解密并写出明文」这段，而不只是删钥匙。
        have_openssl = shutil.which('openssl') is not None
        enc_name = '20260101-000000.json.enc'
        if have_openssl:
            unwrap = subprocess.run(
                ['openssl', 'enc', '-d', '-aes-256-cbc', '-md', 'md5',
                 '-pass', 'env:CLAUDE_HIST_PASS', '-in', os.path.join(hist6, 'key.enc')],
                capture_output=True, text=True,
                env=dict(os.environ, CLAUDE_HIST_PASS='pw-for-test'))
            master = ''
            for line in (unwrap.stdout or '').splitlines():
                if line.startswith('MASTER:'):
                    master = line[len('MASTER:'):]
            H.check(len(master) == 64, '拿到主密钥（后面的解密用例才有意义）', len(master))
            body = os.path.join(work, 'one-session.json')
            io_open = __import__('io').open
            with io_open(body, 'w', encoding='utf-8') as fh:
                fh.write('{"name":"enc1","messages":[{"role":"user",'
                         '"content":"加密保存的一句"}]}')
            subprocess.run(['openssl', 'enc', '-aes-256-cbc', '-md', 'md5', '-salt',
                            '-pass', 'env:CLAUDE_HIST_PASS', '-in', body,
                            '-out', os.path.join(hist6, enc_name)],
                           capture_output=True, env=dict(os.environ, CLAUDE_HIST_PASS=master))
            H.check(os.path.isfile(os.path.join(hist6, enc_name)),
                    '造出了一个可解密的历史文件', sorted(os.listdir(hist6)))

        # 口令错：什么都不许删
        rc, out = run_cli(home6, '--make-plain-history',
                          extra={'CLAUDE_HIST_PASS': 'wrong-one'})
        H.check(rc != 0 and '口令不对' in out,
                '口令不对时明确报错', out[:200])
        H.check(os.path.isfile(os.path.join(hist6, 'key.enc')),
                '口令不对时不清 key.enc（绝不能把人锁在外面）', sorted(os.listdir(hist6)))

        # 真的转：key.enc 消失，出现备份目录，且之后启动不再要口令
        rc, out = run_cli(home6, '--make-plain-history',
                          extra={'CLAUDE_HIST_PASS': 'pw-for-test'})
        H.check(rc == 0, '转换成功退出（rc=0）', 'rc=%d %s' % (rc, out[:300]))
        H.check(not os.path.isfile(os.path.join(hist6, 'key.enc')),
                '转换后 key.enc 被清掉（这才是不再问口令的关键）',
                sorted(os.listdir(hist6)))
        H.check('备份' in out, '转换时说了备份在哪', out[:400])
        parent6 = os.path.dirname(hist6)
        backups = [d for d in os.listdir(parent6) if d.startswith('history-backup-')]
        H.check(len(backups) == 1,
                '确实留下了一个备份目录（转换不可反悔，必须留底）', backups)

        rc, out = run_cli(home6, '--list-history')
        # 注意：「想要口令加密，用 --encrypt-history」这句本身含「口令」二字，
        # 所以不能拿「口令」当判据；要判的是「有没有要输入」。
        H.check('明文' in out and '输入的内容不会显示在屏幕上' not in out,
                '转换后 --list-history 直接是明文模式（不再问口令）', out[:240])
        if have_openssl:
            plain = os.path.join(hist6, enc_name.replace('.enc', ''))
            H.check(os.path.isfile(plain), '加密的会话被写成了明文文件', sorted(os.listdir(hist6)))
            if os.path.isfile(plain):
                content = open(plain, encoding='utf-8').read()
                H.check('加密保存的一句' in content,
                        '转换出来的内容没坏（不是把密文当明文塞进去）', content[:160])
                H.check(oct(os.stat(plain).st_mode & 0o777) == '0o600',
                        '明文历史仍是 0600（换格式不能把权限放宽）',
                        oct(os.stat(plain).st_mode & 0o777))
            H.check('加密保存的一句' in out, '--list-history 能读到转换后的会话', out[:240])

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
