# -*- coding: utf-8 -*-
"""记忆 / 技能测试共用的最小套件：假 OpenAI 端点 + `--rpc` 驱动 agent。

为什么抽出来共用：这两个测试都要断言「模型到底收到了什么」，也就是要读发给
模型的请求体（system prompt）。这套驱动逻辑复制两遍必然漂移 —— 已经吃过
「两份假服务端，一份校验一份不校验」的亏。

不依赖真 key：端点是自己起的 HTTP 服务，按脚本返回 tool_call / 文本。
"""
import http.server
import json
import os
import queue
import signal
import socket
import subprocess
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, 'agent', 'claude-agent.pl')


def default_model(provider='deepseek'):
    """从 providers.txt 取默认模型（测试不写死模型 id）。"""
    with open(os.path.join(ROOT, 'providers.txt'), encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('|')
            if len(parts) > 2 and parts[0] == provider:
                return parts[2].strip()
    raise SystemExit('providers.txt 里找不到 %s 的默认模型' % provider)


class Script:
    """按顺序返回预设的 assistant 响应，并记下收到的请求体。"""

    def __init__(self):
        self.queue = []
        self.lock = threading.Lock()
        self.requests = []

    def push_tool(self, name, args):
        with self.lock:
            self.queue.append({'choices': [{'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [{'id': 'call_%d' % (int(time.time() * 1000) % 10 ** 6),
                                'type': 'function',
                                'function': {'name': name,
                                             'arguments': json.dumps(args)}}],
            }}]})

    def push_text(self, text='done'):
        with self.lock:
            self.queue.append({'choices': [{'message': {'role': 'assistant',
                                                        'content': text}}]})

    def reset(self):
        with self.lock:
            self.queue = []
            self.requests = []

    def next(self):
        with self.lock:
            if self.queue:
                return self.queue.pop(0)
        return {'choices': [{'message': {'role': 'assistant', 'content': 'ok'}}]}


def make_server(script):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get('content-length') or 0)
            body = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
            script.requests.append(body)
            raw = json.dumps(script.next()).encode()
            self.send_response(200)
            self.send_header('content-type', 'application/json')
            self.send_header('content-length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, 'http://127.0.0.1:%d/v1' % srv.server_address[1]


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Agent:
    """起一个 `--rpc` agent，把 HOME 指到临时目录（不碰真实配置）。"""

    def __init__(self, home, base_url, mode=None, extra_env=None, work=None,
                 tools=None, no_config=False, lang='zh'):
        env = {
            'HOME': home,
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'CLAUDE_PROVIDER': 'deepseek',
            'DEEPSEEK_API_KEY': 'dummy-key-for-tests',
            'CLAUDE_MODEL': default_model(),
            'CLAUDE_BASE_URL': base_url,
            'CLAUDE_NO_HISTORY': '1',
            'CLAUDE_LANG': lang,
            'TERM': 'dumb',
            'TMPDIR': os.path.join(home, 'tmpdir'),
        }
        if mode:
            env['CLAUDE_MODE'] = mode
        if extra_env:
            env.update(extra_env)
        os.makedirs(os.path.join(home, 'tmpdir'), exist_ok=True)
        args = ['perl', AGENT, '--rpc']
        if tools:
            args.append('--tools=' + ','.join(tools))
        if no_config:
            args.append('--no-config')
        self.p = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=(work or home), text=True, bufsize=1, start_new_session=True)
        self.home = home
        self.events = []
        self.hello = None
        self.q = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self._read_hello()

    def _pump(self):
        try:
            for line in self.p.stdout:
                self.q.put(line)
        except Exception:
            pass

    def _readline(self, timeout):
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            return None

    def _read_hello(self):
        deadline = time.time() + 45
        while time.time() < deadline:
            line = self._readline(5)
            if line is None:
                continue
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            self.events.append(obj)
            if obj.get('t') == 'init' or ('provider' in obj and 'model' in obj):
                self.hello = obj
                return
        print('::error::agent 没有完成握手 stderr=%s'
              % ((self.stderr_text() or '').replace('\n', ' / ')[:600]))

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + '\n')
        self.p.stdin.flush()

    def collect(self, timeout=45, answer=None):
        deadline = time.time() + timeout
        events = []
        while time.time() < deadline:
            line = self._readline(1)
            if line == '':
                break
            if line is None:
                continue
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            events.append(obj)
            self.events.append(obj)
            if obj.get('t') == 'confirm' and answer is not None:
                self.send({'t': 'reply', 'value': answer})
            if obj.get('t') in ('turn_done', 'bye'):
                break
        return events

    def turn(self, text, answer=None, timeout=45):
        self.send({'t': 'user', 'text': text})
        return self.collect(timeout=timeout, answer=answer)

    def tool_turn(self, name, args, answer=None, timeout=45):
        """让模型直接返回一个 tool_call，看 agent 怎么处理它。"""
        return self.turn('__push_tool__', answer=answer, timeout=timeout)

    def stderr_text(self):
        try:
            if self.p.poll() is not None:
                return (self.p.stderr.read() or '')[-1500:]
        except Exception:
            pass
        return ''

    def stop(self):
        try:
            self.send({'t': 'quit'})
        except Exception:
            pass
        try:
            self.p.wait(timeout=5)
        except Exception:
            pass
        try:
            os.killpg(os.getpgid(self.p.pid), signal.SIGKILL)
        except Exception:
            pass
        for h in (self.p.stdout, self.p.stdin, self.p.stderr):
            try:
                h.close()
            except Exception:
                pass


def texts(events):
    return '\n'.join(e.get('text') or '' for e in events
                     if e.get('t') in ('text', 'note', 'error', 'status'))


def confirms(events):
    return [e for e in events if e.get('t') == 'confirm']


def system_prompt_of(request_body):
    """从一次请求体里取出 system prompt（OpenAI 兼容形式：messages[0].role=system）。"""
    try:
        req = json.loads(request_body)
    except ValueError:
        return ''
    out = []
    for m in req.get('messages') or []:
        if m.get('role') == 'system':
            c = m.get('content')
            out.append(c if isinstance(c, str) else json.dumps(c, ensure_ascii=False))
    # Gemini 形式（systemInstruction）
    si = req.get('systemInstruction') or req.get('system_instruction')
    if isinstance(si, dict):
        for p in (si.get('parts') or []):
            if isinstance(p, dict) and 'text' in p:
                out.append(p['text'])
    return '\n'.join(out)


def check(cond, name, detail=''):
    global OK, FAIL
    if cond:
        OK += 1
        print('  ok   %s' % name)
    else:
        FAIL += 1
        print('  FAIL %s%s' % (name, ('  ← %s' % detail) if detail else ''))
        print('::error::%s' % (name + (' | ' + str(detail).replace('\n', ' / ')[:400]
                                       if detail else '')))


OK = 0
FAIL = 0


def finish(tag):
    bad = FAIL
    print('\n%d/%d 通过' % (OK, OK + bad))
    return 1 if bad else 0
