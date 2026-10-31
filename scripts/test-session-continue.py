#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""会话接续与找回（参考 Hermes 的口径）。

守住的约定：
  ① `--continue` 直接接着最近一场，**不弹任何菜单**（--rpc/远程环境下也不能等输入）
  ② `--name` 起名后 `--continue 名字` 能精确接上那一场，且写回同一个历史文件
  ③ `--search` 在明文历史里全文命中；加密历史无口令时**跳过并说明**，不静默
  ④ 中文（argv）不能变成乱码 —— 这条踩过：--search 报价 曾显示成 æ¥ä»·
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_harness as H

SCRIPT = H.Script()


def run_cli(home, *args):
    env = {
        'HOME': home,
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'CLAUDE_PROVIDER': 'deepseek',
        'DEEPSEEK_API_KEY': 'dummy-key-for-tests',
        'CLAUDE_MODEL': H.default_model(),
        'CLAUDE_LANG': 'zh',
        'TERM': 'dumb',
        'TMPDIR': os.path.join(home, 'tmpdir'),
    }
    env.pop('CLAUDE_HIST_PASS', None)
    os.makedirs(env['TMPDIR'], exist_ok=True)
    p = subprocess.run(['perl', H.AGENT] + list(args), env=env, cwd=home,
                       capture_output=True, text=True, timeout=180)
    return p.returncode, (p.stdout or '') + (p.stderr or '')


def files(hist, suffix='.json'):
    if not os.path.isdir(hist):
        return []
    return sorted(f for f in os.listdir(hist) if f.endswith(suffix))


def read_msgs(path):
    with io.open(path, encoding='utf-8') as fh:
        return json.load(fh).get('messages', [])



def case_rpc_named_resume(tmp, base):
    """远程那种用法：同一个名字 + --continue，重启进程后必须接着上次。

    网关给每个发送者一个稳定键（remote:<md5 前12位>），服务重启后重新 spawn
    agent 时带的就是这两个参数 —— 这条路必须真能接上，不然手机每重启一次服务断片。
    """
    print('[远程口径] 同名 + --continue：进程重启后要接上')
    home = os.path.join(tmp, 'home-rpc')
    os.makedirs(home)
    hist = os.path.join(home, 'hist')
    key = 'remote:abcdef123456'
    # 注意 harness 默认 CLAUDE_NO_HISTORY=1，这里必须显式打开
    env = {'CLAUDE_HISTORY_DIR': hist, 'CLAUDE_NO_HISTORY': '0'}

    SCRIPT.reset()
    SCRIPT.push_text('第一次的回答')
    a = H.Agent(home, base, extra_args=['--name=' + key, '--continue=' + key], extra_env=env)
    a.turn('第一句')
    a.stop()
    files = sorted(os.listdir(hist)) if os.path.isdir(hist) else []
    H.check(len(files) == 1, '第一轮写出了历史文件', files)

    SCRIPT.reset()
    SCRIPT.push_text('第二轮的回答')
    b = H.Agent(home, base, extra_args=['--name=' + key, '--continue=' + key], extra_env=env)
    ev = b.turn('第二句')
    # 「载入了上次的会话」是握手阶段发的 note，在 b.events 里（不在本回合事件里）
    body = ''.join(H.texts(b.events)) + ''.join(H.texts(ev))
    H.check('载入' in body or 'continue' in body.lower() or '接着' in body,
            '第二轮启动时明确说「载入了上次的会话」', body[:200])
    # 请求体里应当带着上一轮的那句话（真接上，不是只打了个招呼）
    joined = '\n'.join(SCRIPT.requests[-1:])
    H.check('第一句' in joined, '第二轮请求里带着上一轮的内容（真接上）', joined[:300])
    b.stop()

def main():
    if not os.path.exists(H.AGENT):
        H.check(False, 'agent 存在', H.AGENT)
        return H.finish('continue')

    work = tempfile.mkdtemp(prefix='cont-')
    srv, base = H.make_server(SCRIPT)
    try:
        home = os.path.join(work, 'home')
        os.makedirs(home)
        hist = os.path.join(home, '.claude-agent', 'history')

        case_rpc_named_resume(work, base)

        # ---- A) 第一场：普通会话，之后 --continue 接着它
        a = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'})
        H.check((a.hello or {}).get('history') == 1, '历史开启', str(a.hello)[:160])
        a.turn('第一场的第一句')
        a.stop()
        first = files(hist)
        H.check(len(first) == 1, '第一场留下一个会话文件', str(first))
        path1 = os.path.join(hist, first[0])
        n1 = len(read_msgs(path1))
        H.check(n1 >= 2, '文件里有对话记录', str(n1))

        # --continue：不弹菜单、不新增文件、写回同一个文件
        b = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'}, extra_args=['--continue'])
        H.check(b.hello is not None, '--continue 能正常启动（没有卡在输入上）')
        b.turn('接上以后再说一句')
        b.stop()
        H.check(len(files(hist)) == 1, '--continue 没有新建会话文件', str(files(hist)))
        n2 = len(read_msgs(path1))
        H.check(n2 > n1, '两轮对话写回了同一个文件（%d → %d）' % (n1, n2), str(n2))
        body = json.dumps(read_msgs(path1), ensure_ascii=False)
        H.check('第一场的第一句' in body, '上一场的消息还在（真的接着而不是重开）', body[:160])
        H.check('接上以后再说一句' in body, '新的一句也进来了', body[:160])

        # ---- B) --name 起名 + --continue 名字
        a = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'},
                    extra_args=['--name=项目甲'])
        a.turn('这是项目甲的会话')
        a.stop()
        named = [f for f in files(hist)
                 if '项目甲' in json.dumps(read_msgs(os.path.join(hist, f)), ensure_ascii=False)]
        H.check(len(named) == 1, '带名字的会话被写下来了', str(files(hist)))
        rec = json.load(io.open(os.path.join(hist, named[0]), encoding='utf-8'))
        H.check(rec.get('name') == '项目甲', '历史文件里有 name 字段', str(rec.get('name')))

        named_size = os.path.getsize(os.path.join(hist, named[0]))
        a = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'},
                    extra_args=['--continue=项目甲'])
        a.turn('项目甲的第二句')
        a.stop()
        H.check(os.path.getsize(os.path.join(hist, named[0])) > named_size,
                '--continue 名字 接的是那一场（文件变大）')
        body = json.dumps(read_msgs(os.path.join(hist, named[0])), ensure_ascii=False)
        H.check('项目甲的第二句' in body, '新的一句写进了同名那场', body[:160])

        # 接一个不存在的名字：不崩、当新会话
        a = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'},
                    extra_args=['--continue=没有这个名'])
        H.check(a.hello is not None, '接不存在的名字也能启动（当新会话）')
        a.stop()

        # ---- C) --search（明文）+ 中文不乱码
        rc, out = run_cli(home, '--search', '项目甲')
        H.check(rc == 0, '--search 退出码 0', out[:200])
        H.check('项目甲' in out, '中文检索词没有变成乱码', out[:200])
        H.check('[项目甲]' in out, '命中结果里显示会话名字', out[:300])
        H.check('项目甲的第二句' in out, '命中的内容片段被列出来了', out[:400])
        rc, out = run_cli(home, '--search', '压根没有的词xyzzy')
        H.check(rc == 0 and '没有匹配' in out, '查不到时明确说没有匹配', out[:200])
        rc, out = run_cli(home, '--search')
        H.check(rc == 2 and '需要一个词' in out, '--search 不带词时退出码 2 并说明', 'rc=%d %s' % (rc, out[:160]))

        # ---- C2) 会话内三条命令：/name /history /search（不用退出再敲参数）
        a = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'})
        ev = a.turn('/name 我的实验')
        blobs = ''.join(H.texts(ev))
        H.check('我的实验' in blobs, '/name 报告改名成功', blobs[:200])
        ev = a.turn('/history')
        blobs = ''.join(H.texts(ev))
        H.check('[我的实验]' in blobs, '/history 列出来的名字已更新', blobs[:300])
        H.check('--continue' in blobs, '/history 顺带提示怎么接着（--continue）', blobs[:300])
        ev = a.turn('/search 第一场')
        blobs = ''.join(H.texts(ev))
        H.check('搜索' in blobs and '第一场' in blobs, '/search 在会话内就能查', blobs[:300])
        ev = a.turn('/search')
        blobs = ''.join(H.texts(ev))
        H.check('用法' in blobs, '/search 不带词时给用法', blobs[:200])
        ev = a.turn('/name')
        blobs = ''.join(H.texts(ev))
        H.check('我的实验' in blobs and '用法' in blobs, '/name 不带名字时给用法并显示现在的名字', blobs[:200])
        a.stop()
        # /name 立刻落盘（不等这一轮结束）
        hit = [f for f in files(hist)
               if '我的实验' in io.open(os.path.join(hist, f), encoding='utf-8').read()]
        H.check(bool(hit), '/name 之后名字已经在历史文件里', str(files(hist)))

        # 受限会话（远程/嵌入式）：三条命令一律拒绝
        r = H.Agent(home, base, extra_env={'CLAUDE_NO_HISTORY': '0'}, no_config=True)
        for cmd, label in (('/name 远程起名', '/name'), ('/history', '/history'), ('/search x', '/search')):
            ev = r.turn(cmd)
            blobs = ''.join(H.texts(ev))
            H.check('不能修改配置' in blobs, '受限会话里 %s 被拒绝' % label, blobs[:200])
        r.stop()

        # ---- D) 加密历史：无口令时跳过并说明（不静默、也不崩）
        home2 = os.path.join(work, 'home2')
        hist2 = os.path.join(home2, '.claude-agent', 'history')
        os.makedirs(hist2)
        io.open(os.path.join(hist2, '20260101-000000.json.enc'), 'w').write('not-decryptable')
        rc, out = run_cli(home2, '--search', '任何')
        H.check(rc == 0, '加密历史读不了时 --search 仍正常退出', 'rc=%d %s' % (rc, out[:200]))
        H.check('跳过' in out, '并且说明有文件被跳过', out[:300])
    finally:
        try:
            srv.shutdown()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)

    return H.finish('continue')


if __name__ == '__main__':
    sys.exit(main())
