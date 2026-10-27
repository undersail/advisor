#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""档① 出站通知（`remote/notify.pl`）的离线测试 —— 不需要真实 webhook。

断言的重点是"发出去的东西对不对"：报文字段形态、中文与转义、失败时的退出码、
以及 http:// 明文地址必须被拒（安全默认不能被绕过）。
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTIFY = os.path.join(ROOT, 'remote', 'notify.pl')
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
            print('::error::test-remote-notify 失败：%s %s' % (name, detail or ''))


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class FakeHook:
    """假 webhook 收集器；mode 控制返回什么（ok / errcode / http500）。"""

    def __init__(self):
        self.hits = []
        self.mode = 'ok'
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get('content-length') or 0)
                raw = self.rfile.read(n).decode('utf-8', 'replace')
                outer.hits.append({'path': self.path, 'raw': raw,
                                   'ctype': self.headers.get('content-type')})
                if outer.mode == 'errcode':
                    obj = {'errcode': 93000, 'errmsg': 'invalid webhook url'}
                    code = 200
                elif outer.mode == 'http500':
                    obj = {'error': 'boom'}
                    code = 500
                else:
                    obj = {'errcode': 0, 'errmsg': 'ok', 'code': 0}
                    code = 200
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header('content-type', 'application/json')
                self.send_header('content-length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.port = free_port()
        self.srv = ThreadingHTTPServer(('127.0.0.1', self.port), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def url(self, path='/hook'):
        return 'http://127.0.0.1:%d%s' % (self.port, path)

    def bodies(self):
        return [json.loads(h['raw']) for h in self.hits]

    def stop(self):
        self.srv.shutdown()


class Runner:
    """一份临时 HOME（可写 conf）+ 干净的 CLAUDE_* 环境。"""

    def __init__(self, hook, wecom=True, feishu=True, conf_lines=None):
        self.home = tempfile.mkdtemp(prefix='advisor-notify-home-')
        d = os.path.join(self.home, '.claude-agent')
        os.makedirs(d, exist_ok=True)
        self.conf = os.path.join(d, 'remote.conf')      # notify.pl 读的是 remote.conf
        lines = conf_lines
        if lines is None:
            lines = []
            if wecom:
                lines.append('WECOM_WEBHOOK = %s' % hook.url('/wecom'))
            if feishu:
                lines.append('FEISHU_WEBHOOK = %s' % hook.url('/feishu'))
        with open(self.conf, 'w') as f:
            f.write('\n'.join(lines) + '\n')
        os.chmod(self.conf, 0o600)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE_')}
        self.env['HOME'] = self.home

    def run(self, args, stdin=None):
        p = subprocess.run(['perl', NOTIFY] + args, env=self.env,
                           input=stdin, capture_output=True, text=True, timeout=90)
        return p.returncode, p.stdout, p.stderr

    def stop(self):
        shutil.rmtree(self.home, ignore_errors=True)


def main():
    hook = FakeHook()
    runners = []

    print('::notice::报文字段形态')
    r = Runner(hook)
    runners.append(r)
    code, out, err = r.run(['构建完成'])
    check('两个目标都配时：退出码 0', code == 0, 'code=%s err=%r' % (code, err[:120]))
    check('两个目标都发（各一条）', len(hook.hits) == 2, len(hook.hits))
    wc = [b for b in hook.bodies() if b.get('msgtype') == 'markdown']
    fs = [b for b in hook.bodies() if b.get('msg_type') == 'text']
    check('企微走 markdown 报文', len(wc) == 1, hook.bodies()[:1])
    check('企微正文正确', bool(wc) and wc[0]['markdown']['content'] == '构建完成',
          wc[0] if wc else None)
    check('飞书走 text 报文', len(fs) == 1, hook.bodies()[:1])
    check('飞书正文正确', bool(fs) and fs[0]['content']['text'] == '构建完成',
          fs[0] if fs else None)
    check('发送时带 content-type: application/json',
          all((h['ctype'] or '').lower().startswith('application/json') for h in hook.hits),
          [h['ctype'] for h in hook.hits])

    print('::notice::只配一个目标')
    hook.hits.clear()
    r2 = Runner(hook, feishu=False)
    runners.append(r2)
    code, _, _ = r2.run(['只有企微'])
    check('只配企微：只发一条且退出码 0', code == 0 and len(hook.hits) == 1, len(hook.hits))
    hook.hits.clear()
    r3 = Runner(hook, wecom=False)
    runners.append(r3)
    code, _, _ = r3.run(['只有飞书'])
    check('只配飞书：只发一条且退出码 0', code == 0 and len(hook.hits) == 1, len(hook.hits))

    print('::notice::没有配置 / 空文本')
    r4 = Runner(hook, wecom=False, feishu=False)
    runners.append(r4)
    code, out, err = r4.run(['没人收'])
    check('未配置目标：退出码 1', code == 1, code)
    check('未配置目标：给出提示而不是静默成功', '通知目标未配置' in err, err[:120])
    code, _, err = r.run(['   '])
    check('空文本：退出码 2 并报错', code == 2 and '没有可发送的文本' in err, 'code=%s' % code)

    print('::notice::平台报错时的行为')
    hook.hits.clear()
    hook.mode = 'errcode'
    code, out, err = r.run(['平台拒收'])
    check('企微 errcode != 0：退出码 1', code == 1, code)
    check('企微 errcode != 0：输出里点名是哪个目标失败',
          'WECOM_WEBHOOK' in out and '失败' in out, out[:160])
    hook.mode = 'http500'
    hook.hits.clear()
    code, out, err = r.run(['HTTP 500'])
    check('HTTP 500：退出码 1', code == 1, code)
    hook.mode = 'ok'

    print('::notice::安全默认')
    hook.hits.clear()
    r5 = Runner(hook, conf_lines=['WECOM_WEBHOOK = http://example.com/hook'])
    runners.append(r5)
    code, out, err = r5.run(['明文地址'])
    check('非本机 http:// 地址被拒（不明文发通知）',
          code == 1 and len(hook.hits) == 0, 'code=%s hits=%d' % (code, len(hook.hits)))
    check('被拒原因写清楚了', 'https' in out or 'https' in err, (out + err)[:160])

    print('::notice::stdin 与转义')
    hook.hits.clear()
    payload = '第一行\n第二行\t制表符 "引号" \\反斜杠'
    code, out, err = r.run(['-'], stdin=payload)
    check('从 stdin 读入：退出码 0', code == 0, 'code=%s err=%r' % (code, err[:120]))
    got = [b for b in hook.bodies() if b.get('msgtype') == 'markdown']
    want = payload.split('\n')[0] + '\n' + payload.split('\n')[1]
    check('换行/制表符/引号/反斜杠都正确转义（JSON 能解析回来）',
          bool(got) and got[0]['markdown']['content'] == want,
          got[0]['markdown']['content'] if got else None)
    code, out, err = r.run(['--test'])
    check('--test 用内置文案且成功', code == 0, 'code=%s' % code)

    print('::notice::控制字符与超长文本')
    hook.hits.clear()
    code, _, _ = r.run(['含控制字符\x01\x02的文本'])
    got = [b for b in hook.bodies() if b.get('msgtype') == 'markdown']
    check('控制字符被剔除（JSON 不会不合法）',
          bool(got) and got[0]['markdown']['content'] == '含控制字符的文本',
          got[0]['markdown']['content'] if got else None)
    hook.hits.clear()
    long_text = 'a' * 6000
    code, _, _ = r.run([long_text])
    got = [b for b in hook.bodies() if b.get('msgtype') == 'markdown']
    check('超长文本按原样发出（不静默截断，超平台上限要使用者自己看得见）',
          bool(got) and len(got[0]['markdown']['content']) == 6000,
          len(got[0]['markdown']['content']) if got else None)

    for x in runners:
        x.stop()
    hook.stop()

    print()
    total = PASS + FAIL
    if FAIL:
        print('%d/%d 通过，%d 失败：%s' % (PASS, total, FAIL, ', '.join(FAILS)))
        return 1
    print('%d/%d 通过' % (PASS, total))
    return 0


if __name__ == '__main__':
    sys.exit(main())
