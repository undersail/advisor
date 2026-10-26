#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""档② 轮询中继的端到端验证：gateway --poll ⇄ 中继 ⇄ 假模型。

中继用同契约的本地假实现（CI 里不装 wrangler）。
真 Worker 单独验：`npx wrangler dev --local` 起在 8787，然后
    RELAY_URL=http://127.0.0.1:8787 RELAY_TOKEN=devtoken python3 scripts/test-relay.py --real
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATEWAY = os.path.join(ROOT, 'remote', 'gateway.pl')
MODELS = os.path.join(ROOT, 'models.txt')
REAL = '--real' in sys.argv

_results = []


def check(name, ok, detail=None):
    _results.append((name, bool(ok)))
    print(('  ok   ' if ok else '  FAIL ') + name + (('  ← ' + str(detail)) if (detail and not ok) else ''))


class MockModel(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def log_message(self, format, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        json.loads(self.rfile.read(n) or b'{}')
        msg = {'role': 'assistant', 'content': '中继通路正常，收到你的话。'}
        out = json.dumps({'choices': [{'message': msg}]}).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class FakeRelay(BaseHTTPRequestHandler):
    """与 remote/relay/worker.js 同契约的最小实现。"""
    protocol_version = 'HTTP/1.0'
    token = 'test-token-123'
    inbox = {}
    outbox = {}
    seq = 0

    def log_message(self, format, *args):
        pass

    def _auth(self):
        return (self.headers.get('authorization') or '') == 'Bearer ' + self.token

    def _send(self, obj, code=200):
        out = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        if not self._auth():
            return self._send({'error': 'unauthorized'}, 401)
        n = int(self.headers.get('content-length', 0))
        body = json.loads(self.rfile.read(n) or b'{}')
        if self.path == '/push':
            FakeRelay.seq += 1
            msg = {'id': '%08d' % FakeRelay.seq, 'from': body['from'], 'text': body['text']}
            FakeRelay.inbox.setdefault(body['from'], []).append(msg)
            return self._send({'ok': True, 'id': msg['id']})
        if self.path == '/result':
            FakeRelay.outbox.setdefault(body['from'], []).append(
                {'from': body['from'], 'reply': body['reply']})
            return self._send({'ok': True})
        return self._send({'error': 'not found'}, 404)

    def do_GET(self):
        if self.path.startswith('/health'):
            return self._send({'ok': True})
        if not self._auth():
            return self._send({'error': 'unauthorized'}, 401)
        if self.path.startswith('/pull'):
            to = self.path.split('to=')[1].split('&')[0]
            msgs = FakeRelay.inbox.pop(to, [])
            return self._send({'ok': True, 'messages': msgs})
        if self.path.startswith('/outbox'):
            to = self.path.split('to=')[1].split('&')[0]
            return self._send({'ok': True, 'replies': FakeRelay.outbox.pop(to, [])})
        return self._send({'error': 'not found'}, 404)


def serve(handler):
    srv = HTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def make_home(model_port, relay_url, relay_token, allow='alice'):
    home = tempfile.mkdtemp(prefix='adv-relay-')
    os.makedirs(os.path.join(home, '.claude-agent'), exist_ok=True)
    with open(os.path.join(home, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export CLAUDE_PROVIDER=deepseek\nexport DEEPSEEK_API_KEY=sk-local\n'
                'export CLAUDE_MODEL=deepseek-chat\n')
    lines = []
    with open(MODELS, encoding='utf-8') as f:
        for line in f.read().split('\n'):
            if line.startswith('deepseek-chat|'):
                parts = line.split('|')
                parts[5] = 'http://127.0.0.1:%d/v1' % model_port
                line = '|'.join(parts)
            lines.append(line)
    with open(os.path.join(home, 'models.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
    with open(os.path.join(home, '.claude-agent', 'remote.conf'), 'w', encoding='utf-8') as f:
        f.write('ALLOW = %s\nNOTIFY = 0\nAGENT_ENV_FILE = %s/.claude-agent-env\n'
                'RELAY_URL = %s\nRELAY_TOKEN = %s\nPOLL_INTERVAL = 1\n'
                % (allow, home, relay_url, relay_token))
    return home


def main():
    model_srv, model_port = serve(MockModel)
    relay_srv = None
    try:
        if REAL:
            relay_url = os.environ.get('RELAY_URL', 'http://127.0.0.1:8787')
            token = os.environ.get('RELAY_TOKEN', 'devtoken')
            print('对真 Worker 测试：%s' % relay_url)
        else:
            relay_srv, relay_port = serve(FakeRelay)
            relay_url = 'http://127.0.0.1:%d' % relay_port
            token = FakeRelay.token
            print('对本地假中继测试（同契约）')

        home = make_home(model_port, relay_url, token, allow='alice')
        env = dict(os.environ)
        env['HOME'] = home
        env['CLAUDE_MODELS_FILE'] = os.path.join(home, 'models.txt')

        # 起网关 --poll，处理 2 条就退出
        proc = subprocess.Popen(['perl', GATEWAY, '--poll', '--max-msgs', '2'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=env)

        def push(frm, text):
            subprocess.run(['curl', '-s', '-X', 'POST',
                            '-H', 'authorization: Bearer ' + token,
                            '-H', 'content-type: application/json',
                            '-d', json.dumps({'from': frm, 'text': text}),
                            relay_url + '/push'], capture_output=True, timeout=20)

        def outbox(who):
            r = subprocess.run(['curl', '-s', '-H', 'authorization: Bearer ' + token,
                                relay_url + '/outbox?to=' + who],
                               capture_output=True, text=True, timeout=20)
            return json.loads(r.stdout or '{}').get('replies', [])

        time.sleep(2)
        push('alice', '第一条：中继能用吗')
        time.sleep(3)
        push('mallory', '我不是白名单里的人')      # 应被丢弃，不产生结果
        push('alice', '第二条')
        try:
            out, err = proc.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            check('网关 --poll 能自行退出（收到 2 条后）', False, '超时未退出')
        else:
            check('网关 --poll 处理完 2 条后自行退出', proc.returncode == 0, proc.returncode)

        replies = outbox('alice')
        check('两条消息都拿到了结果', len(replies) == 2, len(replies))
        check('结果内容是模型的回答',
              all('中继通路正常' in r.get('reply', '') for r in replies),
              [r.get('reply', '')[:30] for r in replies])
        check('白名单外的人没有产生结果', not outbox('mallory'))

        audit_path = os.path.join(home, '.claude-agent', 'audit.log')
        audit = open(audit_path, encoding='utf-8').read() if os.path.exists(audit_path) else ''
        check('审计记录了轮询开始与结果投回', 'poll_start' in audit and 'relay_result' in audit)
        # 轮询模式只取白名单里的信箱：白名单外的人根本不会被拉下来，
        # 所以这里不该有 drop_sender（连取都不取，比"取回来再丢"更安全）。
        check('轮询只取白名单信箱（白名单外的人不被拉取）',
              'drop_sender from=mallory' not in audit,
              '出现了 drop_sender，说明拉了不该拉的信箱')
        check('★ 令牌不出现在输出里', token not in (out or '') + (err or ''))
    finally:
        model_srv.shutdown()
        if relay_srv:
            relay_srv.shutdown()

    total = len(_results)
    bad = [r for r in _results if not r[1]]
    print('\n%d/%d 通过' % (total - len(bad), total))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
