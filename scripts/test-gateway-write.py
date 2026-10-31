#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""远程权限：档位来自启动参数 + 确认转发到手机（gateway.pl 侧）。

验的是用户定下的规则：

  · 在 Mac 上启动远程服务时选好档位（default / accept-edits / bypass），
    **启动之后远程端（手机）改不了** —— 消息里的 mode 一律不认
  · 需要确认的操作，由用户在手机端回 y / 没人回就按拒绝（fail-closed）
  · 不传档位 = 只读（历史行为），工具集里不许出现写/执行

怎么验：用一个「假 agent」替掉真 agent（CLAUDE_AGENT 指向它），这样 y/n 往返、
超时、argv 透传都能在 2 秒内跑完，不依赖模型、不烧钱。
"""

import json
import os
import select
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GW = os.path.join(ROOT, 'remote', 'gateway.pl')

PASS = 0
FAIL = 0
FAILS = []


def check(name, ok, detail=''):
    global PASS, FAIL
    if ok:
        PASS += 1
        print('  \u2713 %s' % name)
    else:
        FAIL += 1
        FAILS.append((name, detail))
        print('  \u2717 %s  %s' % (name, detail))


FAKE_AGENT = r'''#!/usr/bin/env perl
# 假 agent（必须是 perl —— 网关是用 `perl $AGENT` 起它的）。
# 只做协议：ready → 收 user → 报 tool → 要 confirm → 等 reply → 回 text + turn_done。
use strict;
use warnings;
$| = 1;
if (defined $ENV{FAKE_ARGV_FILE} && $ENV{FAKE_ARGV_FILE} ne '') {
    open(my $f, '>', $ENV{FAKE_ARGV_FILE}) or die $!;
    print $f join("\n", @ARGV);
    close $f;
}
print '{"t":"ready"}', "\n";
while (my $l = <STDIN>) {
    last if $l =~ /"t"\s*:\s*"bye"/;
    next unless $l =~ /"t"\s*:\s*"user"/;
    print '{"t":"tool","name":"write_file"}', "\n";
    print '{"t":"confirm","prompt":"allow write /tmp/a.txt ?","danger":false}', "\n";
    my $ans = 'none';
    while (my $l2 = <STDIN>) {
        if ($l2 =~ /"t"\s*:\s*"reply"/) {
            $ans = ($l2 =~ /"value"\s*:\s*"(\w+)"/) ? $1 : 'none';
            last;
        }
    }
    print '{"t":"text","text":"answer=' . $ans . '"}', "\n";
    print '{"t":"turn_done"}', "\n";
}
'''


def make_home():
    home = tempfile.mkdtemp(prefix='gw-write-')
    os.makedirs(os.path.join(home, '.claude-agent'), exist_ok=True)
    with open(os.path.join(home, '.claude-agent', 'remote.conf'), 'w', encoding='utf-8') as f:
        f.write('ALLOW=u1\nNOTIFY=0\n')
    agent = os.path.join(home, 'fake_agent.pl')
    with open(agent, 'w', encoding='utf-8') as f:
        f.write(FAKE_AGENT)
    # 一份「正常」的本机配置：厂商有效 + 该厂商的密钥非空（config_sanity 才不告警）
    with open(os.path.join(home, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export CLAUDE_PROVIDER=deepseek\nexport DEEPSEEK_API_KEY=sk-fake-test\n')
    return home, agent


def drive(args, text, answer=None, wait=20.0, home=None, agent=None,
          from_='u1', hist_pass=None):
    """跑一轮：发一条消息，必要时回一个 y/n，收齐 ask 与 reply。"""
    home = home or make_home()[0]
    agent = agent or os.path.join(home, 'fake_agent.pl')
    argv_file = os.path.join(home, 'argv.txt')
    if hist_pass is not None:
        # 远程历史口令走 remote.conf（网关读这个文件）。配了它才写历史。
        conf_dir = os.path.join(home, '.claude-agent')
        os.makedirs(conf_dir, exist_ok=True)
        with open(os.path.join(conf_dir, 'remote.conf'), 'w', encoding='utf-8') as f:
            f.write('HIST_PASS = %s\nALLOW = u1,wxid_alice,wxid_bob\n' % hist_pass)
    env = dict(os.environ)
    env.update({'HOME': home, 'CLAUDE_AGENT': agent, 'FAKE_ARGV_FILE': argv_file})
    if hist_pass is None:
        env['CLAUDE_NO_HISTORY'] = '1'
    else:
        env.pop('CLAUDE_NO_HISTORY', None)
    p = subprocess.Popen(['perl', GW, '--stdin'] + args, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, bufsize=1, env=env)
    asks, replies = [], []
    err = ''
    deadline = time.time() + wait
    try:
        p.stdin.write(json.dumps({'from': from_, 'text': text}) + '\n')
        p.stdin.flush()
        answered = False
        while time.time() < deadline:
            r, _, _ = select.select([p.stdout], [], [], max(0.1, deadline - time.time()))
            if not r:
                break
            line = p.stdout.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                j = json.loads(line)
            except Exception:
                continue
            if 'ask' in j:
                asks.append(j)
                if answer is not None and not answered:
                    p.stdin.write(json.dumps({'answer': answer}) + '\n')
                    p.stdin.flush()
                    answered = True
                continue
            if 'reply' in j:
                replies.append(j['reply'])
                break
    finally:
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.wait(timeout=5)
        except Exception:
            p.kill()
        err = (p.stderr.read() or '')
        p.stdout.close()
        p.stderr.close()
    argv = []
    if os.path.exists(argv_file):
        argv = open(argv_file, encoding='utf-8').read().split('\n')
    audit_path = os.path.join(home, '.claude-agent', 'audit.log')
    audit = open(audit_path, encoding='utf-8').read() if os.path.exists(audit_path) else ''
    return {'asks': asks, 'replies': replies, 'argv': argv, 'rc': p.returncode,
            'err': err, 'audit': audit, 'home': home}


def case_session_continue():
    print('[远程] 同一发送者接着上次的会话（--name/--continue 由网关传下去）')
    print('::notice::[远程] 同一发送者接着上次的会话')

    home = make_home()[0]
    r = drive([], '第一条', home=home, from_='wxid_alice', hist_pass='pw-remote')
    names = [a for a in r['argv'] if a.startswith('--name=remote:')]
    conts = [a for a in r['argv'] if a.startswith('--continue=remote:')]
    check('配了远程历史口令时，网关传下 --name', len(names) == 1, str(r['argv']))
    check('并且传下 --continue（同一发送者接上次）', len(conts) == 1, str(r['argv']))
    check('--name 与 --continue 用的是同一个键',
          names and conts and names[0].split('=', 1)[1] == conts[0].split('=', 1)[1],
          str((names, conts)))
    check('仍然带 --no-config（远程不给配置入口）', '--no-config' in r['argv'], str(r['argv']))
    check('审计里记了一条 session_resume', 'session_resume' in r['audit'], r['audit'][-300:])

    # 同一发送者两次 → 同一个键
    r2 = drive([], '第二条', home=home, from_='wxid_alice', hist_pass='pw-remote')
    key2 = [a for a in r2['argv'] if a.startswith('--name=remote:')]
    check('同一发送者两次的键一致（会接着同一场）',
          bool(key2) and key2[0] == names[0], str((names, key2)))

    # 不同发送者 → 不同的键
    r3 = drive([], '别人的第一条', home=home, from_='wxid_bob', hist_pass='pw-remote')
    key3 = [a for a in r3['argv'] if a.startswith('--name=remote:')]
    check('不同发送者的键不同（各聊各的）', bool(key3) and key3[0] != names[0], str((names, key3)))
    check('发送者 ID 本身不进命令行参数', 'wxid_bob' not in ' '.join(r3['argv']), str(r3['argv']))
    # 审计日志照旧保留 from=（要追是谁发起的）。需要哈希的只有
    # 「会话文件名和 --name/--continue 的键」—— 那两处不能出现原始 ID。
    resume = [l for l in r3['audit'].splitlines() if 'session_resume' in l]
    check('session_resume 的键里没有原始发送者 ID',
          bool(resume) and all('wxid_bob' not in l for l in resume), str(resume))

    # 没配远程历史口令 → 不传 --continue（没历史可接）
    home2 = make_home()[0]
    r4 = drive([], '没配口令', home=home2, from_='wxid_alice')
    check('没配远程历史口令时不传 --continue',
          not [a for a in r4['argv'] if a.startswith('--continue=')], str(r4['argv']))


def main():
    if not os.path.exists(GW):
        print('找不到 remote/gateway.pl')
        return 1

    print('\u2460 不传档位 = 只读（历史行为不能变）')
    r = drive([], '你好')
    tools = [a for a in r['argv'] if a.startswith('--tools=')]
    check('默认档位下工具集只有 read_file,list_dir',
          tools == ['--tools=read_file,list_dir'], str(tools))
    check('默认档位不传 --mode（不是偷偷给个默认值）',
          not [a for a in r['argv'] if a.startswith('--mode')], str(r['argv']))

    print('\u2461 只读档：确认不打扰手机，直接拒')
    r = drive([], '写个文件')
    check('只读档不向手机发问（asks 为空）', r['asks'] == [], str(r['asks']))
    check('只读档回给 agent 的是 n', any('answer=n' in x for x in r['replies']), str(r['replies']))
    check('审计里记了 read-only 拒绝', 'confirm_refused' in r['audit'])

    print('\u2462 可写档：工具集与参数透传')
    r = drive(['--mode=accept-edits', '--allow-write=/tmp/a.txt,/tmp/b.txt'], '帮我改代码',
              answer='n')
    tools = [a for a in r['argv'] if a.startswith('--tools=')]
    check('accept-edits 的工具集含 write_file 与 run_shell',
          tools and 'write_file' in tools[0] and 'run_shell' in tools[0], str(tools))
    check('--mode 透传给 agent', '--mode=accept-edits' in r['argv'], str(r['argv']))
    roots = [a for a in r['argv'] if a.startswith('--allow-write=')]
    check('--allow-write 两个目录都透传（逗号拆分）',
          roots == ['--allow-write=/tmp/a.txt', '--allow-write=/tmp/b.txt'], str(roots))

    print('\u2463 可写档：确认转到手机 → 回 y 才放行')
    r = drive(['--mode=accept-edits', '--allow-write=/tmp'], '帮我写 /tmp/a.txt', answer='y')
    check('向手机发出了一条确认', len(r['asks']) == 1, str(r['asks']))
    check('确认里带 agent 的原话', r['asks'] and '/tmp/a.txt' in r['asks'][0].get('ask', ''),
          str(r['asks'][:1]))
    check('确认里标明不是危险操作', r['asks'] and r['asks'][0].get('danger') == 0, str(r['asks'][:1]))
    check('回 y 后 agent 收到 y', any('answer=y' in x for x in r['replies']), str(r['replies']))
    check('审计记了提问与回答',
          'confirm_asked' in r['audit'] and 'confirm_answered' in r['audit'])

    print('\u2464 可写档：回 n 就是拒绝')
    r = drive(['--mode=accept-edits', '--allow-write=/tmp'], '帮我写 /tmp/a.txt', answer='n')
    check('回 n 后 agent 收到 n', any('answer=n' in x for x in r['replies']), str(r['replies']))

    print('\u2465 没人回答 → 超时按拒绝（fail-closed）')
    r = drive(['--mode=accept-edits', '--allow-write=/tmp', '--confirm-wait=1'],
              '帮我写 /tmp/a.txt', answer=None, wait=25)
    check('超时后 agent 拿到的是 n', any('answer=n' in x for x in r['replies']), str(r['replies']))
    check('审计里标了 timeout=1', 'timeout=1' in r['audit'])

    print('\u2466 参数校验（配错了要当场说出来，别静默无效）')
    r = drive(['--mode=编辑器'], 'x', wait=10)
    check('未知档位 → 退出码 2', r['rc'] == 2, 'rc=%s' % r['rc'])
    check('未知档位 → 说明可选值', 'accept-edits' in r['err'], r['err'][:80])
    r = drive(['--allow-write=/tmp'], 'x', wait=10)
    check('只读档给可写目录 → 退出码 2', r['rc'] == 2, 'rc=%s' % r['rc'])
    check('并且说明原因', '只读' in r['err'], r['err'][:80])

    print('\u2467 档位只来自启动参数：会话审计里必须写明')
    r = drive(['--mode=bypass'], 'x', answer='n')
    check('审计里记了 mode=bypass', 'mode=bypass' in r['audit'])
    check('bypass 的工具集同样可写',
          any('write_file' in a for a in r['argv'] if a.startswith('--tools=')), str(r['argv']))

    print()
    if FAIL:
        print('%d/%d 通过，%d 项失败' % (PASS, PASS + FAIL, FAIL))
        for name, detail in FAILS:
            print('  \u2717 %s  %s' % (name, detail))
        return 1
    print('\u2465 session 起不来：必须报出真原因，不能静默')
    # 真机现象：手机发消息完全没反应，日志只有一句 session_not_ready，看不出任何原因。
    _h, _ = make_home()
    bad = os.path.join(_h, 'bad_agent.sh')
    with open(bad, 'w', encoding='utf-8') as f:
        f.write('#!/bin/sh\necho "致命错误：模型名 xyz 不存在" >&2\nexit 3\n')
    os.chmod(bad, 0o755)
    r = drive([], '你好', wait=25.0, home=_h, agent=bad)
    check('起不来时手机能收到一句话（不再「发了没反应」）',
          bool(r['replies']) and '没起来' in r['replies'][0], str(r['replies']))
    check('给用户的话里点明去哪看原因',
          bool(r['replies']) and ('审计' in r['replies'][0] or '终端' in r['replies'][0]),
          str(r['replies']))
    check('审计 session_not_ready 带上子进程的真实报错',
          'session_not_ready' in r['audit'] and '模型名 xyz 不存在' in r['audit'],
          r['audit'][-300:])
    check('终端也打出原因（盯着终端的用户能当场看到）',
          '模型名 xyz 不存在' in (r['err'] or ''), (r['err'] or '')[-300:])
    check('中文报错没变乱码（stderr 按 UTF-8 解码）',
          'è' not in (r['err'] or ''), (r['err'] or '')[-200:])

    print('\u2466 配置自检：厂商没定下来时，启动就说清楚（别等手机发消息才失败）')
    _h1, _ = make_home()
    with open(os.path.join(_h1, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export DEEPSEEK_API_KEY=sk-fake-test\nexport CLAUDE_PROVIDER=\n')
    r = drive([], '你好', wait=25.0, home=_h1)
    check('厂商值为空：启动就打配置自检告警', '配置自检' in (r['err'] or ''), (r['err'] or '')[-300:])
    check('告警点名 CLAUDE_PROVIDER（并解释为何报 ANTHROPIC）',
          'CLAUDE_PROVIDER' in (r['err'] or '') and 'ANTHROPIC' in (r['err'] or ''),
          (r['err'] or '')[-300:])
    check('告警也写进审计（config_warn）', 'config_warn' in r['audit'], r['audit'][-300:])
    check('自检从不打印密钥值', 'sk-fake-test' not in (r['err'] or ''), (r['err'] or '')[-200:])

    _h2, _ = make_home()
    with open(os.path.join(_h2, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export CLAUDE_PROVIDER=DeepSeek\nexport DEEPSEEK_API_KEY=sk-fake-test\n')
    r = drive([], '你好', wait=25.0, home=_h2)
    check('厂商名不认识：告警里列出可选择的名字',
          '不认识' in (r['err'] or '') and 'deepseek' in (r['err'] or ''),
          (r['err'] or '')[-300:])

    _h3, _ = make_home()
    r = drive([], '你好', wait=25.0, home=_h3)
    check('配置正常时不自检告警（不制造噪声）', '配置自检' not in (r['err'] or ''),
          (r['err'] or '')[-300:])

    print('\u2467 env 文件的各种写法都要认（别把用户配好的厂商整行吃掉）')
    # 原来只认 `export NAME=value`（等号两边不许有空格），于是
    # `export CLAUDE_PROVIDER = deepseek` / `CLAUDE_PROVIDER=deepseek`（没 export）
    # 都被整行丢弃 → agent 回退 anthropic → 报「请设置 ANTHROPIC_API_KEY」。
    shapes = [
        'export CLAUDE_PROVIDER=deepseek',
        'export CLAUDE_PROVIDER = deepseek',
        'CLAUDE_PROVIDER=deepseek',
        'export CLAUDE_PROVIDER="deepseek"',
        "export CLAUDE_PROVIDER='deepseek'",
        'export CLAUDE_PROVIDER=deepseek   # 主要用这个',
        'export CLAUDE_PROVIDER="deepseek"  # 主要用这个',
    ]
    bad_shapes = []
    for shape in shapes:
        _h, _ = make_home()
        with open(os.path.join(_h, '.claude-agent-env'), 'w', encoding='utf-8') as f:
            f.write(shape + '\nexport DEEPSEEK_API_KEY=sk-fake-test\n')
        r = drive([], '你好', wait=25.0, home=_h)
        if '配置自检' in (r['err'] or ''):
            bad_shapes.append((shape, (r['err'] or '')[-160:]))
    check('七种常见写法都能读出 CLAUDE_PROVIDER（不被整行吃掉）',
          bad_shapes == [], str(bad_shapes[:2]))

    _h, _ = make_home()
    with open(os.path.join(_h, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export CLAUDE_PROVIDER=deepseek\r\nexport DEEPSEEK_API_KEY=sk-fake-test\r\n')
    r = drive([], '你好', wait=25.0, home=_h)
    check('CRLF（Windows 编辑器存过的文件）也能认',
          '配置自检' not in (r['err'] or ''), (r['err'] or '')[-200:])

    _h, _ = make_home()
    with open(os.path.join(_h, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export DEEPSEEK_API_KEY=sk-fake-test\n')      # 干脆没有厂商这一行
    r = drive([], '你好', wait=25.0, home=_h)
    check('真没有厂商时仍然要告警（宽容解析不等于不检查）',
          '配置自检' in (r['err'] or ''), (r['err'] or '')[-200:])

    print('\u2468 env 文件读不到（属主是 root）要说清楚，别误导成「没配厂商」')
    if os.geteuid() == 0:
        print('  （以 root 运行，权限检查不适用，跳过）')
    else:
        _h, _ = make_home()
        _f = os.path.join(_h, '.claude-agent-env')
        with open(_f, 'w', encoding='utf-8') as f:
            f.write('export CLAUDE_PROVIDER=deepseek\nexport DEEPSEEK_API_KEY=sk-fake-test\n')
        os.chmod(_f, 0o000)
        try:
            r = drive([], '你好', wait=25.0, home=_h)
            err = r['err'] or ''
            check('读不到时点明是「权限/读不到」而不是「没配厂商」',
                  ('读不到' in err) or ('权限' in err), err[-300:])
            check('读不到时给出修法（chown + chmod）',
                  ('chown' in err) and ('chmod' in err), err[-300:])
            check('读不到时的告警也进审计', 'config_warn' in r['audit'], r['audit'][-240:])
        finally:
            os.chmod(_f, 0o600)

    print('\u246a 中文不能被双重编码（真机：手机发中文，agent 收到「ä½ å¥½」）')
    _h, _ = make_home()
    echo = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fake-echo-agent.pl')
    r = drive([], '你好，世界', wait=25.0, home=_h, agent=echo)
    rep0 = r['replies'][0] if r['replies'] else ''
    check('中文原样到达 agent 再原样回来（没有「ä½ å¥½」这类乱码）',
          '你好' in rep0 and 'ä' not in rep0 and 'å' not in rep0, rep0)
    check('回复里没有 latin-1 双重编码的典型痕迹（Ã / Â）',
          'Ã' not in rep0 and 'Â' not in rep0, rep0)

    # --once 走命令行参数：argv 拿到的是原始字节，也必须显式解码
    argv_out = subprocess.run(
        ['perl', GW, '--once', '--from', 'u1', '--text', '中文测试'],
        capture_output=True,
        env=dict(os.environ, HOME=_h, CLAUDE_AGENT=echo, CLAUDE_NO_HISTORY='1'),
        timeout=40)
    out = argv_out.stdout.decode('utf-8', 'replace')
    check('--once 的中文参数也原样（argv 显式解码）',
          '中文测试' in out and 'ä' not in out, out[-200:])

    case_session_continue()

    print('%d/%d 通过' % (PASS, PASS + FAIL))
    return 0


if __name__ == '__main__':
    sys.exit(main())
