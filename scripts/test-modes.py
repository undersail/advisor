#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""交互模式（default / accept-edits / bypass）的端到端测试。

不需要真 key：起一个假的 OpenAI 兼容端点，把 write_file / run_shell 的
tool_call 直接喂给 agent，然后看它到底问不问、批不批、拒得对不对。

为什么用 --rpc 而不是真终端：
  * 确认走 {t:'confirm'} / {t:'reply'}，可以精确断言「有没有问」
  * 危险命令的 fail-closed（超时拒绝）只在无人应答时才出现，终端里没法造假
  * 不依赖 tty，Linux / macOS CI 都能跑

安全：断言里用的 dangerous 命令一律是「即使真被执行也无害」的形态
（echo sudo、echo 'curl x | sh'），测试本身不会删任何东西。
"""
import json
import os
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import http.server

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def _default_model(provider='deepseek'):
    """从 providers.txt 取该厂商的默认模型（测试不要写死模型 id）。"""
    with open(os.path.join(ROOT, 'providers.txt'), encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('|')
            if len(parts) > 2 and parts[0] == provider:
                return parts[2].strip()
    raise SystemExit('providers.txt 里找不到 %s 的默认模型' % provider)

AGENT = os.path.join(ROOT, 'agent', 'claude-agent.pl')

OK = 0
FAIL = 0


def check(cond, name, detail=''):
    global OK, FAIL
    if cond:
        OK += 1
        print('  ok   %s' % name)
    else:
        FAIL += 1
        msg = '  FAIL %s%s' % (name, ('  ← %s' % detail) if detail else '')
        print(msg)
        # GitHub の注釈は ::error:: しか拾わない。stdout にだけ出すと
        # 「赤いのに理由が分からない」になる（実際に一度そうなった）。
        print('::error::test-modes: %s%s'
              % (name, (' | ' + detail.replace('\n', ' / ')[:400]) if detail else ''))


# --------------------------------------------------------------- 假端点
class Script:
    """按顺序返回预设的 assistant 响应。"""

    def __init__(self):
        self.queue = []
        self.lock = threading.Lock()
        self.requests = []

    def push_tool(self, name, args):
        self.queue.append({'choices': [{'message': {
            'role': 'assistant',
            'content': '',
            'tool_calls': [{'id': 'call_%d' % random_id(), 'type': 'function',
                            'function': {'name': name,
                                         'arguments': json.dumps(args)}}],
        }}]})

    def push_text(self, text='done'):
        self.queue.append({'choices': [{'message': {'role': 'assistant', 'content': text}}]})

    def next(self):
        with self.lock:
            return self.queue.pop(0) if self.queue else {
                'choices': [{'message': {'role': 'assistant', 'content': 'ok'}}]}


SCRIPT = Script()


def random_id():
    return int(time.time() * 1000) % 10 ** 6


class MockLLM(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        SCRIPT.requests.append(body)
        raw = json.dumps(SCRIPT.next()).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):
        pass


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ------------------------------------------------------------------ agent
class Agent:
    def __init__(self, home, mode, base_url, extra_env=None, work=None):
        env = {
            'HOME': home,
            'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
            'CLAUDE_PROVIDER': 'deepseek',
            'DEEPSEEK_API_KEY': 'dummy-key-for-tests',
            'CLAUDE_MODEL': _default_model(),
            'CLAUDE_BASE_URL': base_url,
            'CLAUDE_NO_HISTORY': '1',
            'CLAUDE_LANG': 'zh',
            'CLAUDE_MODE': mode,
            'TERM': 'dumb',
            # 一時ディレクトリの根を明示する（/tmp はもう既定の可写根ではない）。
            # ここを固定しないと「範囲外」の意味が実行環境で変わってしまう。
            'TMPDIR': os.path.join(home, 'tmpdir'),
        }
        if extra_env:
            env.update(extra_env)
        os.makedirs(os.path.join(home, 'tmpdir'), exist_ok=True)
        args = ['perl', AGENT, '--rpc']
        if mode is None:
            env.pop('CLAUDE_MODE', None)
        self.p = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, cwd=(work or home), text=True, bufsize=1, start_new_session=True)
        self.home = home
        self.events = []
        self.hello = None
        self.q = queue.Queue()
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()
        self._read_hello()

    def _pump(self):
        # 1 本の読み取りスレッドで全部受ける（readline を都度スレッドにすると
        # 終了時に closed file で溢れるし、行の取りこぼしも起きる）。
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
                print('::notice::agent 握手 OK（mode=%s model=%s）'
                      % (obj.get('mode'), obj.get('model')))
                return
        # 握手が来ない = agent が起動していない。理由を出さないと CI では
        # ただ「赤い」だけになる。
        rc = self.p.poll()
        err = ''
        try:
            err = (self.p.stderr.read() or '')[-1200:]
        except Exception:
            pass
        print('::error::agent 没有完成握手（pid 状态 %r）stderr=%s'
              % (rc, err.replace('\n', ' / ')[:900]))

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + '\n')
        self.p.stdin.flush()

    def collect(self, timeout=45, stop_on=None, answer=None):
        """读到 turn_done（或 stop_on 条件满足）为止；answer 用来应答 confirm。"""
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
            if stop_on and stop_on(obj):
                break
            if obj.get('t') in ('turn_done', 'bye'):
                break
        return events

    def turn(self, text, answer=None, timeout=45):
        self.send({'t': 'user', 'text': text})
        return self.collect(timeout=timeout, answer=answer)

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
        try:
            self.p.stdout.close()
            self.p.stdin.close()
            self.p.stderr.close()
        except Exception:
            pass


def texts(events):
    out = []
    for e in events:
        if e.get('t') in ('text', 'note', 'error', 'status'):
            out.append(e.get('text') or '')
    return '\n'.join(out)


def last_tool_results():
    """把最近一次发给模型的请求里，tool_result 的内容拼起来。

    工具的返回值只回给模型（用户看到的是 note），所以要验「模型到底收到
    了什么」必须看请求体，不能只看界面事件。
    """
    if not SCRIPT.requests:
        return ''
    try:
        req = json.loads(SCRIPT.requests[-1])
    except ValueError:
        return ''
    out = []
    for m in req.get('messages') or []:
        # OpenAI 形式では tool 役のメッセージに結果が入る
        if m.get('role') == 'tool':
            out.append(str(m.get('content')))
            continue
        c = m.get('content')
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get('type') == 'tool_result':
                    out.append(str(b.get('content')))
    return '\n'.join(out)


def confirms(events):
    return [e for e in events if e.get('t') == 'confirm']


# ------------------------------------------------------------------ 用例
def case_default_asks(tmp, base):
    print('[default] 写文件与命令都要确认')
    print('::notice::[default] 写文件与命令都要确认')
    work = os.path.join(tmp, 'work')
    os.makedirs(work, exist_ok=True)

    a = Agent(tmp, 'default', base, work=work)
    try:
        SCRIPT.push_tool('write_file', {'path': os.path.join(work, 'd.txt'), 'content': 'x'})
        SCRIPT.push_text()
        ev = a.turn('写个文件', answer='y')
        check(len(confirms(ev)) == 1, 'default 下 write_file 弹了确认', texts(ev))
        check(os.path.exists(os.path.join(work, 'd.txt')), 'reply=y 后文件真的写了')

        SCRIPT.push_tool('run_shell', {'command': 'echo hello-default'})
        SCRIPT.push_text()
        ev = a.turn('跑个命令', answer='y')
        check(len(confirms(ev)) == 1, 'default 下 run_shell 弹了确认')
        check('hello-default' in json.dumps(ev, ensure_ascii=False), '命令输出回来了')
    finally:
        a.stop()


def case_default_declines(tmp, base):
    print('[default] 拒绝就不执行')
    print('::notice::[default] 拒绝就不执行')
    a = Agent(tmp, 'default', base)
    try:
        target = os.path.join(tmp, 'no.txt')
        SCRIPT.push_tool('write_file', {'path': target, 'content': 'x'})
        SCRIPT.push_text()
        a.turn('写个文件', answer='n')
        check(not os.path.exists(target), 'reply=n 时不写文件')
    finally:
        a.stop()


def case_accept_edits(tmp, base):
    print('[accept-edits] 范围内自动、范围外仍问、命令仍问')
    print('::notice::[accept-edits] 范围内自动、范围外仍问、命令仍问')
    work = os.path.join(tmp, 'work')
    outside = os.path.join(tmp, 'outside')
    os.makedirs(work, exist_ok=True)
    os.makedirs(outside, exist_ok=True)

    a = Agent(tmp, 'accept-edits', base, work=work)
    try:
        inside = os.path.join(work, 'auto.txt')
        SCRIPT.push_tool('write_file', {'path': inside, 'content': 'auto'})
        SCRIPT.push_text()
        ev = a.turn('写文件')
        check(len(confirms(ev)) == 0, '范围内写入没有弹确认', texts(ev))
        check(os.path.exists(inside), '文件写了')
        check('已自动批准' in texts(ev), '消息流里出现「已自动批准」', texts(ev))

        outside = os.path.join(outside, 'auto.txt')
        SCRIPT.push_tool('write_file', {'path': outside, 'content': 'x'})
        SCRIPT.push_text()
        ev = a.turn('写范围外的文件', answer='n')
        check(len(confirms(ev)) == 1, '范围外写入仍然弹确认')
        check(not os.path.exists(outside), '按 n 后没写')

        SCRIPT.push_tool('run_shell', {'command': 'echo accept-edits-cmd'})
        SCRIPT.push_text()
        ev = a.turn('跑命令', answer='y')
        check(len(confirms(ev)) == 1, 'accept-edits 下命令仍然弹确认（与 bypass 的区别）')
    finally:
        a.stop()


def case_bypass(tmp, base):
    print('[bypass] 普通操作不问、危险命令必问、超时拒绝')
    print('::notice::[bypass] 普通操作不问、危险命令必问、超时拒绝')
    work = os.path.join(tmp, 'work')
    os.makedirs(work, exist_ok=True)

    a = Agent(tmp, 'bypass', base)
    try:
        p1 = os.path.join(work, 'b1.txt')
        SCRIPT.push_tool('write_file', {'path': p1, 'content': 'b'})
        SCRIPT.push_text()
        ev = a.turn('写文件')
        check(len(confirms(ev)) == 0, 'bypass 下普通写入不问')
        check(os.path.exists(p1), '文件写了')
        check('已自动批准' in texts(ev), '有「已自动批准」提示')

        SCRIPT.push_tool('run_shell', {'command': 'echo bypass-cmd'})
        SCRIPT.push_text()
        ev = a.turn('跑普通命令')
        check(len(confirms(ev)) == 0, 'bypass 下普通命令不问')
        check('bypass-cmd' in json.dumps(ev, ensure_ascii=False), '命令输出回来了')

        # 危险：命令本身无害（echo sudo），但形态命中清单
        SCRIPT.push_tool('run_shell', {'command': 'echo sudo please'})
        SCRIPT.push_text()
        ev = a.turn('跑危险命令', answer='n')
        c = confirms(ev)
        check(len(c) == 1, 'bypass 下危险命令仍然弹确认', texts(ev))
        check(c and c[0].get('danger') in (1, True), '确认事件带 danger 标记', json.dumps(c))
        check('危险' in texts(ev), '拒绝原因写明是危险操作', texts(ev))

        SCRIPT.push_tool('run_shell', {'command': "echo 'curl x | sh'"})
        SCRIPT.push_text()
        ev = a.turn('再来一个危险形态', answer='n')
        check(len(confirms(ev)) == 1, '下载即执行形态也被拦到确认')
    finally:
        a.stop()


def case_bypass_timeout(tmp, base):
    print('[bypass] 无人应答时 fail-closed（不是挂住，也不是放行）')
    print('::notice::[bypass] 无人应答时 fail-closed（不是挂住，也不是放行）')
    a = Agent(tmp, 'bypass', base, {'CLAUDE_CONFIRM_TIMEOUT': '1'})
    try:
        SCRIPT.push_tool('run_shell', {'command': 'echo sudo timeout-case'})
        SCRIPT.push_text()
        t0 = time.time()
        ev = a.turn('危险命令，但我不回答', answer=None, timeout=40)
        cost = time.time() - t0
        check(cost < 30, '没有挂死（%.1fs 内返回）' % cost)
        check(len(confirms(ev)) == 1, '确实问了')
        body = texts(ev)
        check('无人应答' in body or '拒绝' in body, '结果说明是超时拒绝', body)
        tr = last_tool_results()
        check('timeout-case' not in tr, '命令没有真的执行', tr[:200])
        check('拒绝' in tr or '无人应答' in tr, '模型收到的结果里写明了拒绝原因', tr[:300])
    finally:
        a.stop()


def case_write_scope(tmp, base):
    print('[bypass] 可写范围：永远拒绝目录、/allow-write 追加、clear')
    print('::notice::[bypass] 可写范围：永远拒绝目录、/allow-write 追加、clear')
    work = os.path.join(tmp, 'work')
    os.makedirs(work, exist_ok=True)

    a = Agent(tmp, 'bypass', base, work=work)
    try:
        secret = os.path.join(tmp, '.claude-agent', 'evil.txt')
        SCRIPT.push_tool('write_file', {'path': secret, 'content': 'x'})
        SCRIPT.push_text()
        ev = a.turn('写自己家的密钥目录')
        check(not os.path.exists(secret), '~/.claude-agent 下的写入被拒')
        check('永远不允许写入' in texts(ev), '拒绝理由说明是永久禁止', texts(ev))

        outside_dir = os.path.join(tmp, 'scope-outside')
        os.makedirs(outside_dir, exist_ok=True)
        try:
            target = os.path.join(outside_dir, 'ok.txt')
            SCRIPT.push_tool('write_file', {'path': target, 'content': 'x'})
            SCRIPT.push_text()
            a.turn('还没加白名单')
            check(not os.path.exists(target), '加白名单前：范围外被拒')

            ev = a.turn('/allow-write ' + outside_dir)
            check('已允许写入' in texts(ev), '/allow-write 报告已加入', texts(ev))

            SCRIPT.push_tool('write_file', {'path': target, 'content': 'x'})
            SCRIPT.push_text()
            a.turn('加白名单后')
            check(os.path.exists(target), '加白名单后能写')

            ev = a.turn('/allow-write clear')
            check('已清空' in texts(ev), '/allow-write clear 生效', texts(ev))
            os.remove(target)
            SCRIPT.push_tool('write_file', {'path': target, 'content': 'x'})
            SCRIPT.push_text()
            a.turn('clear 之后')
            check(not os.path.exists(target), 'clear 之后又写不了了')
        finally:
            shutil.rmtree(outside_dir, ignore_errors=True)
    finally:
        a.stop()


def case_shell_limits(tmp, base):
    print('[bypass] 命令超时与输出上限')
    print('::notice::[bypass] 命令超时与输出上限')
    a = Agent(tmp, 'bypass', base, {'CLAUDE_SHELL_TIMEOUT': '2'})
    try:
        SCRIPT.push_tool('run_shell', {'command': 'sleep 30; echo late'})
        SCRIPT.push_text()
        t0 = time.time()
        ev = a.turn('长命令', timeout=40)
        cost = time.time() - t0
        body = texts(ev)
        check(cost < 20, '超时命令没有拖住会话（%.1fs）' % cost)
        tr = last_tool_results()
        check('超时' in tr, '模型收到的结果里说明是超时', tr[:300])
        check('late' not in tr, '超时之后的部分没有执行', tr[:300])

        SCRIPT.push_tool('run_shell', {'command': "python3 -c \"print('x'*200000)\""})
        SCRIPT.push_text()
        a.turn('大输出', timeout=40)
        tr = last_tool_results()
        check('只返回前 64 KB' in tr, '输出被截断并注明', tr[-300:])
        check(len(tr) < 70 * 1024, '返回内容确实被限制在 64KB 附近（实际 %d 字节）' % len(tr))
    finally:
        a.stop()


def case_mode_switch(tmp, base):
    print('[任意] /mode 切换：切到 bypass 需要再输一次 yes')
    print('::notice::[任意] /mode 切换：切到 bypass 需要再输一次 yes')
    a = Agent(tmp, 'default', base)
    try:
        ev = a.turn('/mode')
        check('default' in texts(ev), '/mode 显示当前模式', texts(ev))

        ev = a.turn('/mode bypass')
        check('yes' in texts(ev), '切 bypass 先给出警告并要求输入 yes', texts(ev))

        ev = a.turn('不切换')
        check('已取消' in texts(ev), '没输 yes 时取消切换', texts(ev))

        ev = a.turn('/mode bypass')
        ev = a.turn('yes')
        check('模式已切换为 bypass' in texts(ev), '输入 yes 后真的切过去了', texts(ev))

        env_file = os.path.join(tmp, '.claude-agent-env')
        content = open(env_file, encoding='utf-8').read() if os.path.exists(env_file) else ''
        check('CLAUDE_MODE=bypass' in content, '模式写进了 ~/.claude-agent-env（下次沿用）', content)

        ev = a.turn('/mode accept-edits')
        check('accept-edits' in texts(ev), '可以切回 accept-edits')
    finally:
        a.stop()


def case_bad_mode(tmp, base):
    print('[启动] 非法模式值直接报错，不静默回落')
    print('::notice::[启动] 非法模式值直接报错，不静默回落')
    env = dict(os.environ)
    env.update({'HOME': tmp, 'CLAUDE_PROVIDER': 'deepseek', 'DEEPSEEK_API_KEY': 'dummy',
                'CLAUDE_MODEL': _default_model(), 'CLAUDE_BASE_URL': base,
                'CLAUDE_NO_HISTORY': '1', 'CLAUDE_LANG': 'zh', 'TERM': 'dumb'})
    env.pop('CLAUDE_MODE', None)
    p = subprocess.run(['perl', AGENT, '--mode=nonsense'], env=env, cwd=tmp,
                       capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    check(p.returncode == 2, '非法模式退出码 2（实际 %d）' % p.returncode, p.stderr)
    check('nonsense' in (p.stderr or ''), '错误里带上了非法值', p.stderr)


def case_cmd_write_scope(tmp, base):
    print('[bypass] 命令里的写入目标也受可写范围约束')
    print('::notice::[bypass] 命令里的写入目标也受可写范围约束')
    work = os.path.join(tmp, 'work')
    os.makedirs(work, exist_ok=True)

    a = Agent(tmp, 'bypass', base, work=work)
    outside = os.path.join(tmp, 'cmd-outside')
    os.makedirs(outside, exist_ok=True)
    try:
        target = os.path.join(outside, 'via-cmd.txt')

        SCRIPT.push_tool('run_shell', {'command': 'echo hi > "%s"' % target})
        SCRIPT.push_text()
        ev = a.turn('重定向到范围外', answer='n')
        check(len(confirms(ev)) == 1, '重定向到范围外会弹确认', texts(ev))
        check(not os.path.exists(target), '按 n 后没有写出去')

        SCRIPT.push_tool('run_shell', {'command': 'echo hi > "%s"' % target})
        SCRIPT.push_text()
        a.turn('同样的重定向，这次同意', answer='y')
        check(os.path.exists(target), '同意后写成功了')

        SCRIPT.push_tool('run_shell', {'command': 'cp "%s" "%s"' % (target, os.path.join(outside, 'cp.txt'))})
        SCRIPT.push_text()
        ev = a.turn('cp 到范围外', answer='n')
        check(len(confirms(ev)) == 1, 'cp 的目标在范围外也会问')

        a.turn('/allow-write ' + outside)
        SCRIPT.push_tool('run_shell', {'command': 'echo hi > "%s"' % os.path.join(outside, 'after-allow.txt')})
        SCRIPT.push_text()
        ev = a.turn('加了白名单后同样的命令')
        check(len(confirms(ev)) == 0, '加了白名单后不再问', texts(ev))

        # 永久禁止：连确认都不给，直接拒
        SCRIPT.push_tool('run_shell', {'command': 'echo hi > /etc/advisor-probe-should-not-exist'})
        SCRIPT.push_text()
        ev = a.turn('写到 /etc')
        check(len(confirms(ev)) == 0, '写到 /etc 不弹确认（直接拒）')
        check('永久禁止' in texts(ev), '说明是永久禁止的位置', texts(ev))
        check(not os.path.exists('/etc/advisor-probe-should-not-exist'), '/etc 下确实没写出去')

        # 范围外的普通命令仍然照跑（不要因为识别写目标就误伤所有命令）
        SCRIPT.push_tool('run_shell', {'command': 'echo plain-no-write'})
        SCRIPT.push_text()
        ev = a.turn('没有写目标的命令')
        check(len(confirms(ev)) == 0, '不涉及写入的命令照旧不问')
        tr = last_tool_results()
        check('plain-no-write' in tr, '并且真的执行了', tr[:200])
    finally:
        a.stop()
        shutil.rmtree(outside, ignore_errors=True)


def case_approvals_log(tmp, base):
    print('[审计] 自动批准写进 approvals.log（0600，不含密钥）')
    print('::notice::[审计] 自动批准写进 approvals.log（0600，不含密钥）')
    log = os.path.join(tmp, '.claude-agent', 'approvals.log')
    check(os.path.exists(log), 'approvals.log 存在')
    if os.path.exists(log):
        mode = oct(os.stat(log).st_mode & 0o777)
        check(mode == '0o600', '权限 0600（实际 %s）' % mode)
        body = open(log, encoding='utf-8').read()
        check('auto' in body, '记录里有 auto 结果')
        check('dummy-key-for-tests' not in body, '日志里没有 API key')
    a = Agent(tmp, 'bypass', base)
    try:
        ev = a.turn('/approvals')
        check('自动批准' in texts(ev) or '还没有' in texts(ev), '/approvals 能看记录', texts(ev))
    finally:
        a.stop()


def main():
    if not os.path.exists(AGENT):
        print('找不到 %s' % AGENT)
        return 1
    port = free_port()
    srv = http.server.HTTPServer(('127.0.0.1', port), MockLLM)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d/v1' % port

    tmp = tempfile.mkdtemp(prefix='advisor-modes-home-')
    os.makedirs(os.path.join(tmp, '.claude-agent'), exist_ok=True)
    try:
        case_default_asks(tmp, base)
        case_default_declines(tmp, base)
        case_accept_edits(tmp, base)
        case_bypass(tmp, base)
        case_bypass_timeout(tmp, base)
        case_write_scope(tmp, base)
        case_cmd_write_scope(tmp, base)
        case_shell_limits(tmp, base)
        case_mode_switch(tmp, base)
        case_bad_mode(tmp, base)
        case_approvals_log(tmp, base)
    finally:
        srv.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)

    print('\n%d/%d 通过' % (OK, OK + FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
