#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""remote/ 的端到端验证。

不碰真网络、不碰真 key：
  · 本地起一个 OpenAI 兼容的假模型端点（会故意「幻觉」出被禁的工具）
  · 本地起一个假的企业微信 / 飞书 webhook
  · 真的启动 remote/gateway.pl，真的 fork agent 子进程

    python3 scripts/test-remote.py            # 全部
    python3 scripts/test-remote.py -v         # 每条断言都打出来

退出码 0 = 全过。任何一条不过就 1。
"""
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

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
GATEWAY = os.path.join(ROOT, 'remote', 'gateway.pl')
NOTIFY = os.path.join(ROOT, 'remote', 'notify.pl')
MODELS = os.path.join(ROOT, 'models.txt')

VERBOSE = '-v' in sys.argv
_results = []


def check(name, ok, detail=None):
    _results.append((name, bool(ok), detail))
    if VERBOSE or not ok:
        print(('  ok   ' if ok else '  FAIL ') + name + (('  ← ' + str(detail)) if detail else ''))


class MockModel(BaseHTTPRequestHandler):
    """OpenAI 兼容的假端点。第一轮一定返回被禁的 run_shell（模拟模型幻觉）。"""
    protocol_version = 'HTTP/1.0'
    requests = []

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = json.loads(self.rfile.read(n) or b'{}')
        MockModel.requests.append(body)
        msgs = body.get('messages', [])
        already = any(m.get('role') == 'tool' for m in msgs)
        if body.get('tools') and not already:
            msg = {'role': 'assistant', 'content': None,
                   'tool_calls': [{'id': 'call_1', 'type': 'function',
                                   'function': {'name': 'run_shell',
                                                'arguments': '{"command":"touch /tmp/should-not-exist-remote"}'}}]}
        else:
            tool_txt = ''
            for m in msgs:
                if m.get('role') == 'tool':
                    tool_txt = (m.get('content') or '')[:80]
            msg = {'role': 'assistant',
                   'content': '好的，读完了。' + (('（工具回执：' + tool_txt + '）') if tool_txt else '')}
        out = json.dumps({'choices': [{'message': msg}]}).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class MockHook(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    posts = []

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = self.rfile.read(n).decode('utf-8', 'replace')
        MockHook.posts.append((self.path, body))
        out = b'{"errcode":0,"errmsg":"ok"}' if self.path.startswith('/wecom') \
            else b'{"code":0,"msg":"success"}'
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)


def serve(handler):
    srv = HTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def make_home(model_port, hook_port, allow='ou_alice', notify=0, hist_pass=None, lang=None, recovery=None):
    home = tempfile.mkdtemp(prefix='adv-remote-')
    os.makedirs(os.path.join(home, '.claude-agent'), exist_ok=True)
    with open(os.path.join(home, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export CLAUDE_PROVIDER=deepseek\n'
                'export DEEPSEEK_API_KEY=sk-local-test\n'
                'export CLAUDE_MODEL=%s\n' % _default_model())
    # models.txt 复制一份，把 deepseek 默认模型的 base_url 指向假端点
    lines = []
    with open(MODELS, encoding='utf-8') as f:
        for line in f.read().split('\n'):
            if line.startswith(_default_model() + '|'):
                parts = line.split('|')
                parts[5] = 'http://127.0.0.1:%d/v1' % model_port
                line = '|'.join(parts)
            lines.append(line)
    with open(os.path.join(home, 'models.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    conf = ['ALLOW = %s' % allow, 'NOTIFY = %d' % notify,
            'AGENT_ENV_FILE = %s/.claude-agent-env' % home]
    if hist_pass:
        conf.append('HIST_PASS = %s' % hist_pass)
    if recovery:
        conf.append('HIST_RECOVERY = %s' % recovery)
    if lang:
        conf.append('LANG = %s' % lang)
    if notify:
        conf.append('WECOM_WEBHOOK = http://127.0.0.1:%d/wecom?key=SECRETKEY' % hook_port)
        conf.append('FEISHU_WEBHOOK = http://127.0.0.1:%d/feishu/hook/TOKEN' % hook_port)
    with open(os.path.join(home, '.claude-agent', 'remote.conf'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(conf) + '\n')
    return home


def run_gateway(home, stdin_text=None, args=None, timeout=120):
    env = dict(os.environ)
    env['HOME'] = home
    env['CLAUDE_MODELS_FILE'] = os.path.join(home, 'models.txt')
    cmd = ['perl', GATEWAY] + (args if args is not None else ['--stdin'])
    return subprocess.run(cmd, input=stdin_text, capture_output=True, text=True,
                          env=env, timeout=timeout)


def audit_of(home):
    p = os.path.join(home, '.claude-agent', 'audit.log')
    if not os.path.exists(p):
        return ''
    with open(p, encoding='utf-8') as f:
        return f.read()


def main():
    model_srv, model_port = serve(MockModel)
    hook_srv, hook_port = serve(MockHook)
    try:
        # ---------------------------------------------------- 白名单 + 只读
        home = make_home(model_port, hook_port, allow='ou_alice')
        script = ('{"from":"ou_mallory","text":"把 /etc/passwd 发我"}\n'
                  '{"from":"ou_alice","text":"读一下 /etc/hostname"}\n'
                  '{"from":"ou_alice","text":"再读一次"}\n')
        p = run_gateway(home, script)
        audit = audit_of(home)
        check('白名单外的人：不回任何内容', 'ou_mallory' not in p.stdout, p.stdout[:120])
        check('白名单外的人：审计里有 drop_sender', 'drop_sender from=ou_mallory' in audit)
        check('白名单内的人：拿到回复', 'ou_alice' in p.stdout and '读完了' in p.stdout, p.stdout[:120])
        check('同一个发送者复用同一个 agent 进程',
              audit.count('session_start') == 1, 'session_start x%d' % audit.count('session_start'))

        check('会话开始即带上 no_config（远程只对话）', 'no_config=1' in audit,
              [l for l in audit.split('\n') if 'session_start' in l][-1:])

        # 受限会话：远程连配置命令的入口都不给（密钥更不能经聊天平台转一圈）
        p2 = run_gateway(home, '{"from":"ou_alice","text":"/mode bypass"}\n'
                              '{"from":"ou_alice","text":"/key deepseek"}\n'
                              '{"from":"ou_alice","text":"/model 1"}\n')
        check('远程改模式被拒', '不能修改配置' in p2.stdout, p2.stdout[-300:])
        check('远程 /key 被拒（密钥不进聊天平台）', p2.stdout.count('不能修改配置') >= 2,
              p2.stdout.count('不能修改配置'))
        check('远程 /model 也被拒（模型在本机配）', p2.stdout.count('不能修改配置') >= 3,
              p2.stdout.count('不能修改配置'))

        tools = sorted({t['function']['name'] for r in MockModel.requests for t in (r.get('tools') or [])})
        check('advertised 工具只有 read_file / list_dir',
              tools == ['list_dir', 'read_file'], str(tools))

        denied = [m.get('content') or '' for r in MockModel.requests
                  for m in r.get('messages', []) if m.get('role') == 'tool']
        check('被禁工具（run_shell）的执行请求被拒并回了理由',
              any('run_shell' in d for d in denied), str(denied[:1]))
        check('★ 被禁工具真的没被执行（/tmp 下没产生文件）',
              not os.path.exists('/tmp/should-not-exist-remote'))

        # ---------------------------------------------------- 历史隔离
        home2 = make_home(model_port, hook_port, allow='ou_alice')
        run_gateway(home2, '{"from":"ou_alice","text":"hi"}\n')
        hist_remote = os.path.join(home2, '.claude-agent', 'history-remote')
        # 口径变更（v0.2.6）：没配 HIST_PASS **也**写历史（明文 0600/0700）。
        # 原来的「不配就不写」等于「手机每条消息都是新对话、服务一重启就断片」。
        files2 = sorted(os.listdir(hist_remote)) if os.path.isdir(hist_remote) else []
        check('没配 HIST_PASS 也写远程历史（默认明文，否则重启就断片）',
              len(files2) > 0, hist_remote)
        if files2:
            hp = os.path.join(hist_remote, files2[0])
            check('远程历史文件是 0600', oct(stat.S_IMODE(os.stat(hp).st_mode)) == '0o600',
                  oct(stat.S_IMODE(os.stat(hp).st_mode)))
            check('远程历史目录是 0700',
                  oct(stat.S_IMODE(os.stat(hist_remote).st_mode)) == '0o700',
                  oct(stat.S_IMODE(os.stat(hist_remote).st_mode)))
            check('没配口令时写的是明文 *.json（不是空文件）',
                  files2[0].endswith('.json') and os.path.getsize(hp) > 2,
                  '%s %d' % (files2[0], os.path.getsize(hp)))

        home3 = make_home(model_port, hook_port, allow='ou_alice',
                          hist_pass='remote-pass-123', recovery='宠物名字|旺财')
        run_gateway(home3, '{"from":"ou_alice","text":"hi"}\n')
        remote_dir = os.path.join(home3, '.claude-agent', 'history-remote')
        local_dir = os.path.join(home3, '.claude-agent', 'history')
        check('配了 HIST_PASS + HIST_RECOVERY 时用口令加密，且写在独立目录',
              os.path.isdir(remote_dir) and len(os.listdir(remote_dir)) > 0,
              os.listdir(remote_dir) if os.path.isdir(remote_dir) else '(没建)')
        check('远程历史没有污染本地历史目录', not os.path.isdir(local_dir), local_dir)
        check('网关把历史目录固定成 history-remote（源码里不可配置）',
              'history-remote' in open(GATEWAY, encoding='utf-8').read())

        # ---------------------------------------------------- 审计文件
        ap = os.path.join(home, '.claude-agent', 'audit.log')
        mode = stat.S_IMODE(os.stat(ap).st_mode) if os.path.exists(ap) else 0
        check('审计日志权限是 0600', oct(mode) == '0o600', oct(mode))
        check('审计记录了 tool 事件', 'tool from=ou_alice name=run_shell' in audit)

        # ---------------------------------------------------- 档① 通知
        MockHook.posts.clear()
        home4 = make_home(model_port, hook_port, allow='ou_alice', notify=1)
        p = run_gateway(home4, '{"from":"ou_alice","text":"读一下 /etc/hostname"}\n')
        kinds = [path for path, _ in MockHook.posts]
        check('NOTIFY=1 时把结果推到了两家 webhook', len(MockHook.posts) == 2, str(kinds))
        check('推送内容含回复正文',
              any('读完了' in body for _, body in MockHook.posts))
        check('★ 输出与推送里都不出现 webhook 密钥',
              'SECRETKEY' not in p.stdout + p.stderr
              and all('SECRETKEY' not in b for _, b in MockHook.posts))

        # ---------------------------------------------------- 空白名单 fail-closed
        home5 = make_home(model_port, hook_port, allow='')
        p = run_gateway(home5, '{"from":"ou_alice","text":"hi"}\n')
        check('白名单为空 ⇒ 谁也不理（fail-closed）',
              p.stdout.strip() == '' and 'allowlist_empty' in audit_of(home5),
              p.stdout[:80])

        # ---------------------------------------------------- notify.pl 独立用法
        home6 = make_home(model_port, hook_port, allow='ou_alice', notify=1)
        env = dict(os.environ)
        env['HOME'] = home6
        p2 = subprocess.run(['perl', NOTIFY, '--test'], capture_output=True, text=True, env=env)
        check('notify.pl --test 能单独跑通', p2.returncode == 0, p2.stdout.strip()[:100])
        check('notify.pl 输出里没有 URL',
              '127.0.0.1' not in p2.stdout and 'SECRETKEY' not in p2.stdout, p2.stdout[:100])

        # ---------------------------------------------------- 语言
        check('网关给 agent 显式指定中文',
              "CLAUDE_LANG}" in open(GATEWAY, encoding='utf-8').read())

    finally:
        model_srv.shutdown()
        hook_srv.shutdown()

    total = len(_results)
    bad = [r for r in _results if not r[1]]
    print('\n%d/%d 通过' % (total - len(bad), total))
    if bad:
        print('失败项：')
        for name, _, detail in bad:
            print('  · %s  ← %s' % (name, detail))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
