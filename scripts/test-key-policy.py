#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""密钥策略测试：密钥只在安装时输入，会话中永不索要、也不接收。

维护者定下的规则（真实事故后确认）：
  1. 对话过程中绝不提示重新输入密钥；
  2. 缺密钥/密钥失效只做提示，并指出去哪里配；
  3. 失效后必须退出会话再单独配置，而不是在对话里打断要 key。

用 PTY 真喂输入（管道会把多行读成一整块），本地假端点造 200 / 401。
"""
import json
import os
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, 'agent', 'claude-agent.pl')
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
            print('::error::test-key-policy 失败：%s %s' % (name, detail or ''))


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Mock(BaseHTTPRequestHandler):
    mode = 'ok'

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        self.rfile.read(n)
        if Mock.mode == '401':
            raw = json.dumps({'type': 'error',
                              'error': {'type': 'authentication_error',
                                        'message': 'invalid x-api-key'}}).encode()
            self.send_response(401)
        else:
            raw = json.dumps({'id': 'x', 'type': 'message', 'role': 'assistant',
                              'content': [{'type': 'text', 'text': 'pong'}],
                              'stop_reason': 'end_turn',
                              'choices': [{'index': 0,
                                           'message': {'role': 'assistant', 'content': 'pong'},
                                           'finish_reason': 'stop'}],
                              'usage': {'input_tokens': 1, 'output_tokens': 1}}).encode()
            self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def run(feed, mode='ok', port=None):
    """在 PTY 里跑一轮，feed 是 [(输入, 等待秒数), ...]，返回整段回显。"""
    Mock.mode = mode
    home = tempfile.mkdtemp(prefix='keypolicy-')
    env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE_')}
    env.update({
        'HOME': home,
        'CLAUDE_PROVIDER': 'deepseek',
        'CLAUDE_MODEL': 'deepseek-chat',
        'DEEPSEEK_API_KEY': 'dummy-key-for-test',
        'CLAUDE_BASE_URL': 'http://127.0.0.1:%d/v1' % port,
        'CLAUDE_NO_HISTORY': '1',
        'CLAUDE_LANG': 'zh',
        'TERM': 'dumb',
        'CLAUDE_MODELS_FILE': os.path.join(ROOT, 'models.txt'),
    })
    master, slave = pty.openpty()
    proc = subprocess.Popen(['perl', AGENT], cwd=ROOT, env=env,
                            stdin=slave, stdout=slave, stderr=slave,
                            close_fds=True, start_new_session=True)
    os.close(slave)
    buf = b''

    def pump(sec):
        nonlocal buf
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([master], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk

    pump(3)
    for line, wait in feed:
        os.write(master, (line + '\n').encode())
        pump(wait)
    try:
        os.killpg(proc.pid, 9)
    except OSError:
        pass
    try:
        os.waitpid(proc.pid, 0)
    except ChildProcessError:
        pass
    shutil.rmtree(home, ignore_errors=True)
    return re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', buf.decode('utf-8', 'replace'))


def main():
    port = free_port()
    srv = HTTPServer(('127.0.0.1', port), Mock)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    print('::notice::会话中切到没有密钥的厂商')
    out = run([('/model', 1.5), ('1', 2.0), ('1', 2.5), ('再问一句', 3.5)], port=port)
    # 「粘贴 / 输入密钥」这类索要动作一律不该出现
    ask_words = ['粘贴', '请输入密钥', 'paste', 'Paste']
    check('不再索要密钥（没有"粘贴/请输入密钥"这类措辞）',
          not any(w in out for w in ask_words),
          [w for w in ask_words if w in out])
    check('提示先退出会话（exit）', 'exit' in out)
    check('指出配置途径（setup.sh 或 ~/.claude-agent-env）',
          'setup.sh' in out and '.claude-agent-env' in out)
    check('取消后仍停在原来的模型', '仍使用 [deepseek' in out)
    check('取消后继续对话正常（没有被"要密钥"打断）', 'pong' in out)

    print('::notice::密钥失效（API 返回 401）')
    out2 = run([('你好', 4.0)], mode='401', port=port)
    check('提示密钥被拒绝', '密钥被拒绝' in out2 and '401' in out2)
    check('指出要检查哪个变量', 'DEEPSEEK_API_KEY' in out2)
    check('要求退出后重新配置', 'exit' in out2)
    check('不再把原始 JSON 甩给用户', 'authentication_error' not in out2)
    check('401 时也不弹输入', not any(w in out2 for w in ['粘贴', '请输入密钥']))

    srv.shutdown()
    print()
    total = PASS + FAIL
    if FAIL:
        print('%d/%d 通过，%d 失败：%s' % (PASS, total, FAIL, ', '.join(FAILS)))
        return 1
    print('%d/%d 通过' % (PASS, total))
    return 0


if __name__ == '__main__':
    sys.exit(main())
