#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""平台端收发的端到端测试（自造凭据，不需要任何真实 token）。

验的是「真的能收发」这件事本身：验签、AES 解密、白名单转交、结果回推。
凭据全部由本脚本现场生成 —— 企微的 EncodingAESKey、回调 Token，飞书的
Encrypt Key 都是自造的，因为验签与加解密是确定性算法，不需要真凭据。

    python3 scripts/test-platform.py [-v]

被测对象：remote/platform.pl（回调服务）+ 假平台 API + 假网关/真网关
"""
import base64
import hashlib
import json
import os
import random
import shutil
import socket
import stat
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLATFORM = os.path.join(ROOT, 'remote', 'platform.pl')
GATEWAY = os.path.join(ROOT, 'remote', 'gateway.pl')
VERBOSE = '-v' in sys.argv

results = []


def check(name, ok, detail=None):
    results.append((name, ok))
    print('  %s %s' % ('ok  ' if ok else 'FAIL', name))
    if not ok:
        if detail:
            print('       细节: %s' % str(detail)[:500].replace('\n', ' / '))
        print('::error::%s | 细节: %s' % (name, str(detail or '')[:300].replace('\n', ' / ')))


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ----------------------------------------------------------------- AES（走 openssl，与 platform.pl 同一实现路径）
def openssl_encrypt(key, iv, plain):
    p = subprocess.run(['openssl', 'enc', '-e', '-aes-256-cbc',
                        '-K', key.hex(), '-iv', iv.hex(), '-nopad'],
                       input=plain, capture_output=True)
    assert p.returncode == 0, p.stderr
    return p.stdout


def pkcs7(data, block):
    pad = block - (len(data) % block)
    if pad == 0:
        pad = block
    return data + bytes([pad]) * pad


def wecom_encrypt(aes_key_43, msg, receiveid='mockcorp'):
    """企微：random(16) + len(4,BE) + msg + ReceiveId + 32 字节块填充；IV = key[:16]"""
    key = base64.b64decode(aes_key_43 + '=')
    body = (os.urandom(16) + len(msg.encode()).to_bytes(4, 'big') + msg.encode()
            + receiveid.encode())
    return base64.b64encode(openssl_encrypt(key, key[:16], pkcs7(body, 32))).decode()


def feishu_encrypt(encrypt_key, plain):
    """飞书：key = sha256(EncryptKey)，base64(IV(16) + cipher)，16 字节块"""
    key = hashlib.sha256(encrypt_key.encode()).digest()
    iv = os.urandom(16)
    return base64.b64encode(iv + openssl_encrypt(key, iv, pkcs7(plain.encode(), 16))).decode()


def wecom_sig(token, ts, nonce, enc):
    return hashlib.sha1(''.join(sorted([token, ts, nonce, enc])).encode()).hexdigest()


# ----------------------------------------------------------------- 假平台 API
PUSHES = []      # 假平台 API 收到的发送请求 (kind, path, body)
TOKENS = []      # 取 token 的请求


class MockAPI(BaseHTTPRequestHandler):

    def _body(self):
        n = int(self.headers.get('content-length') or 0)
        return self.rfile.read(n).decode() if n else ''

    def do_POST(self):
        body = self._body()
        path = self.path
        if 'gettoken' in path:
            TOKENS.append(path)
            out = {'errcode': 0, 'access_token': 'mock-wecom-token', 'expires_in': 7200}
        elif 'message/send' in path:
            PUSHES.append(('wecom', path, body))
            out = {'errcode': 0, 'errmsg': 'ok'}
        elif 'tenant_access_token' in path:
            TOKENS.append(path)
            out = {'code': 0, 'tenant_access_token': 'mock-feishu-token', 'expire': 7200}
        elif '/im/v1/messages' in path:
            PUSHES.append(('feishu', path, body))
            out = {'code': 0, 'data': {}}
        else:
            out = {'code': 404}
        raw = json.dumps(out).encode()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *a):
        pass


def start_mock_api():
    port = free_port()
    srv = HTTPServer(('127.0.0.1', port), MockAPI)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, port


# ----------------------------------------------------------------- 环境准备
def make_wecom_conf(home, port, api_base):
    aes = base64.b64encode(os.urandom(32)).decode()[:43]     # 43 位 EncodingAESKey
    token = 'mock-callback-token-' + str(random.randint(10**6, 10**7))
    conf = '\n'.join([
        'PLATFORM = wecom',
        'WECOM_CORP_ID = mockcorp',
        'WECOM_AGENT_ID = 1000002',
        'WECOM_CORP_SECRET = mock-corp-secret-xyz',
        'WECOM_CALLBACK_TOKEN = %s' % token,
        'WECOM_AES_KEY = %s' % aes,
        'PORT = %d' % port,
    ]) + '\n'
    return conf, aes, token


def write_conf(home, conf, name='platform.conf'):
    d = os.path.join(home, '.claude-agent')
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, name)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(conf)
    os.chmod(p, 0o600)
    return p


class FakeRelay:
    """最小中继：POST /push 收消息，GET /outbox?to= 吐结果。"""
    def __init__(self):
        self.pushed = []
        self.replies_for = {}
        outer = self
        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('content-length') or 0)
                body = json.loads(self.rfile.read(n) or b'{}')
                if not (self.headers.get('authorization') or '').startswith('Bearer '):
                    self.send_response(401); self.end_headers(); return
                outer.pushed.append(body)
                self._json({'ok': True, 'id': '%08d' % len(outer.pushed)})
            def do_GET(self):
                if not (self.headers.get('authorization') or '').startswith('Bearer '):
                    self.send_response(401); self.end_headers(); return
                to = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get('to', [''])[0]
                items = outer.replies_for.pop(to, [])
                self._json({'ok': True, 'replies': [{'id': '%08d' % (i + 1), 'from': to, 'reply': r}
                                                    for i, r in enumerate(items)]})
            def _json(self, obj):
                b = json.dumps(obj, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header('content-type', 'application/json')
                self.send_header('content-length', str(len(b)))
                self.end_headers()
                self.wfile.write(b)
            def log_message(self, *a):
                pass
        self.srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
        self.port = self.srv.server_address[1]
        self.url = 'http://127.0.0.1:%d' % self.port
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()


def fake_gateway(home):
    """模拟真网关 --stdin 的行为：一行请求进，一行 JSON（含 reply）出，
    进程常驻（同一个发送者应当复用同一个进程）。"""
    p = os.path.join(home, 'fakegw.sh')
    with open(p, 'w', encoding='utf-8') as f:
        f.write('#!/bin/bash\n'
                'while IFS= read -r line; do\n'
                '  printf \'%s pid=%s\\n\' "$line" "$$" >> "$HOME/gw_in.txt"\n'
                '  body="${line//\\"/}\"\n'
                '  case "$line" in\n'
                '    *SLOW*) sleep 2 ;;\n'
                '  esac\n'
                '  printf \'{"from":"mock","reply":"网关收到：%s (pid %s)"}\\n\' "$body" "$$"\n'
                'done\n')
    os.chmod(p, 0o755)
    return '/bin/bash ' + p


def http_get(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception:
        return 0, ''        # 服务还没起来：不要抛异常打断等待循环


def http_post(url, body, headers=None):
    data = body.encode() if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method='POST')
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception:
        return 0, ''        # 同上：连接被拒也当「还没就绪」


def wait_for(fn, seconds=12, step=0.2):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return None


def start_platform(home, api_base, gateway_cmd):
    env = dict(os.environ)
    env.update({
        'HOME': home,
        'PLATFORM_API_BASE': api_base,
        'GATEWAY_CMD': gateway_cmd,
        'AUDIT_PATH': os.path.join(home, 'audit.log'),
        'PLATFORM_VERBOSE': '1' if VERBOSE else '',
    })
    # 输出写文件而不是 PIPE：请求一多，没人读的管道写满 64KB 就会把服务端卡死
    # （这件事真的发生过：后面几条断言全变成连接失败，看起来像代码 bug）。
    logf = os.path.join(home, 'platform-serve.log')
    # start_new_session=True：platform.pl 会 fork 出常驻网关子进程。
    # 只 terminate 父进程会留下孤儿 gateway.pl --stdin（实测残留过好几个，
    # 它们还占着队列与端口），所以整组一起收。
    p = subprocess.Popen(['/usr/bin/perl', PLATFORM, '--serve'], cwd=ROOT, env=env,
                         stdout=open(logf, 'w', encoding='utf-8'),
                         stderr=subprocess.STDOUT,
                         start_new_session=True)
    p._logf = logf
    return p


def stop(p):
    """停掉服务**及其 fork 出来的网关子进程**（整组收）。"""
    def killpg(sig):
        try:
            os.killpg(os.getpgid(p.pid), sig)
        except (ProcessLookupError, PermissionError):
            pass

    killpg(signal.SIGTERM)
    try:
        p.wait(timeout=8)
    except subprocess.TimeoutExpired:
        killpg(signal.SIGKILL)
        p.wait(timeout=5)
    killpg(signal.SIGKILL)   # 父进程退了子进程可能还在
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    logf = getattr(p, '_logf', '')
    text = ''
    if logf and os.path.exists(logf):
        text = open(logf, encoding='utf-8').read()
    # 整组收干净了吗？平台端会 fork 常驻网关，只 terminate 父进程会留孤儿
    # —— 本机实测累积过 37 对（最长跑了 12 小时），它们还占着端口。
    try:
        os.killpg(os.getpgid(p.pid), 0)
        leaked = True
    except (ProcessLookupError, PermissionError):
        leaked = False
    p._leaked = leaked
    return text


# ----------------------------------------------------------------- 主流程
def main():
    if not os.path.exists(PLATFORM):
        print('找不到 %s' % PLATFORM)
        return 1
    if subprocess.run(['openssl', 'version'], capture_output=True).returncode != 0:
        print('本机没有 openssl，跳过（platform.pl 依赖系统 openssl 做 AES）')
        return 0

    print('环境: %s %s | openssl: %s | perl: %s' % (
        sys.platform, sys.version.split()[0],
        subprocess.run(['openssl', 'version'], capture_output=True, stdin=subprocess.DEVNULL, timeout=180, text=True).stdout.strip(),
        subprocess.run(['/usr/bin/perl', '-e', 'print $]'], capture_output=True, stdin=subprocess.DEVNULL, timeout=180, text=True).stdout.strip()))
    mock, api_port = start_mock_api()
    api_base = 'http://127.0.0.1:%d' % api_port

    # =============================== 企业微信 ===============================
    home = tempfile.mkdtemp(prefix='plat-wecom-')
    port = free_port()
    conf, aes, token = make_wecom_conf(home, port, api_base)
    write_conf(home, conf)
    gw = fake_gateway(home)
    proc = start_platform(home, api_base, gw)
    base = 'http://127.0.0.1:%d/wecom' % port

    ok = wait_for(lambda: http_get(base + '?msg_signature=x&timestamp=1&nonce=2&echostr=y')[0] == 403)
    check('服务起来了（未签名请求被拒 403）', bool(ok))

    # --- 回调 URL 验证 ---
    echo = wecom_encrypt(aes, 'echo-12345')
    ts, nonce = str(int(time.time())), 'abc123'
    sig = wecom_sig(token, ts, nonce, echo)
    st, body = http_get(base + '?msg_signature=%s&timestamp=%s&nonce=%s&echostr=%s'
                        % (sig, ts, nonce, urllib.parse.quote(echo)))
    check('企微 URL 验证：200 且返回解密后的 echostr', st == 200 and body.strip() == 'echo-12345',
          'status=%s body=%s' % (st, body[:120]))

    st, body = http_get(base + '?msg_signature=deadbeef&timestamp=%s&nonce=%s&echostr=%s'
                        % (ts, nonce, urllib.parse.quote(echo)))
    check('企微 URL 验证：签名错 → 403', st == 403, 'status=%s' % st)

    # --- 正常消息 ---
    xml = ('<xml><ToUserName><![CDATA[corp]]></ToUserName>'
           '<FromUserName><![CDATA[zhangsan]]></FromUserName>'
           '<CreateTime>1700000001</CreateTime>'
           '<MsgType><![CDATA[text]]></MsgType>'
           '<Content><![CDATA[帮我看下磁盘占用]]></Content>'
           '<MsgId>%s</MsgId></xml>' % str(random.randint(10**9, 10**10)))
    enc = wecom_encrypt(aes, xml)
    outer = '<xml><ToUserName><![CDATA[corp]]></ToUserName><Encrypt><![CDATA[%s]]></Encrypt></xml>' % enc
    sig = wecom_sig(token, ts, nonce, enc)
    PUSHES.clear()
    st, body = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig, ts, nonce), outer)
    check('企微消息：应答 success（平台要求 5 秒内回）', st == 200 and 'success' in body,
          'status=%s body=%s' % (st, body[:80]))

    gin = wait_for(lambda: os.path.exists(os.path.join(home, 'gw_in.txt')))
    got = ''
    if gin:
        with open(os.path.join(home, 'gw_in.txt'), encoding='utf-8') as f:
            got = f.read()
    check('企微消息：解密后真的交给了网关（发送者与正文都对）',
          'zhangsan' in got and '帮我看下磁盘占用' in got, got[:200])

    pushed = wait_for(lambda: [x for x in PUSHES if x[0] == 'wecom'])
    sent_body = pushed[0][2] if pushed else ''
    check('企微消息：回复被推回平台（message/send 收到请求）', bool(pushed),
          'pushes=%s' % (PUSHES[:2],))
    check('企微消息：推送目标是提问的人（touser=zhangsan）', 'zhangsan' in sent_body, sent_body[:200])
    check('企微消息：推送里带上了网关的回复正文', '网关收到' in sent_body, sent_body[:200])
    check('企微消息：推送带上了 agentid', '1000002' in sent_body, sent_body[:200])

    # --- 多轮对话连续性：同一发送者的第二条消息应复用同一个网关进程 ---
    xml2 = ('<xml><FromUserName><![CDATA[zhangsan]]></FromUserName>'
            '<MsgType><![CDATA[text]]></MsgType>'
            '<Content><![CDATA[那它的端口呢]]></Content>'
            '<MsgId>123457</MsgId></xml>')
    enc2 = wecom_encrypt(aes, xml2)
    outer_b = '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % enc2
    sig_b = wecom_sig(token, ts, nonce, enc2)
    http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig_b, ts, nonce), outer_b)
    time.sleep(2.5)
    calls = open(os.path.join(home, 'gw_in.txt'), encoding='utf-8').read().strip().split('\n')
    pids = [ln.split('pid=')[-1] for ln in calls if 'pid=' in ln]
    check('多轮对话：两条消息由同一个网关进程处理（会话上下文能接上）',
          len(pids) >= 2 and pids[0] == pids[-1], 'pids=%s' % pids)

    # --- 长回复：必须按平台上限分片，不能一次发（企微上限 2048 字节）---
    long_text = '请总结这个目录的所有文件内容。' + '细节' * 1200      # 远超 2000 字节
    xml3 = ('<xml><FromUserName><![CDATA[zhangsan]]></FromUserName>'
            '<MsgType><![CDATA[text]]></MsgType>'
            '<Content><![CDATA[%s]]></Content><MsgId>123458</MsgId></xml>' % long_text)
    enc3 = wecom_encrypt(aes, xml3)
    outer_c = '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % enc3
    sig_c = wecom_sig(token, ts, nonce, enc3)
    PUSHES.clear()
    http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig_c, ts, nonce), outer_c)
    wait_for(lambda: [x for x in PUSHES if '网关收到' in x[2]], seconds=25)
    parts = [x for x in PUSHES if x[0] == 'wecom']
    check('长回复：被拆成多条发送（否则平台会直接拒发）', len(parts) >= 2, '条数=%d' % len(parts))
    if parts:
        too_long = [p for p in parts if len(json.loads(p[2])['text']['content'].encode()) > 2048]
        check('长回复：每条都不超过企微 2048 字节上限', not too_long,
              '超限 %d 条' % len(too_long))
        joined = ''.join(json.loads(p[2])['text']['content'] for p in parts)
        check('长回复：分片后内容没丢（末段含结尾、总长不短于原文）',
              long_text[-10:] in joined and len(joined) >= len(long_text),
              'joined_len=%d orig=%d' % (len(joined), len(long_text)))

    # --- 签名错：丢弃且不回复 ---
    PUSHES.clear()
    st, body = http_post('%s?msg_signature=bad&timestamp=%s&nonce=%s' % (base, ts, nonce), outer)
    time.sleep(1.5)
    check('企微消息：签名错 → 403 且不推任何东西', st == 403 and not PUSHES,
          'status=%s pushes=%s' % (st, PUSHES[:1]))

    # --- 安全：重放同一份请求 ---
    pushes_before = len(PUSHES)
    calls_file = os.path.join(home, 'gw_in.txt')
    gw_calls = 0
    if os.path.exists(calls_file):
        gw_calls = len(open(calls_file, encoding='utf-8').read().strip().split('\n'))
    st1, _ = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig, ts, nonce), outer)
    time.sleep(1.5)
    gw_after = 0
    if os.path.exists(calls_file):
        gw_after = len(open(calls_file, encoding='utf-8').read().strip().split('\n'))
    check('安全：同一条消息重投不会让 agent 再跑一遍（按 MsgId 去重）',
          gw_after == gw_calls, '调用次数 %d → %d' % (gw_calls, gw_after))
    audit_now = open(os.path.join(home, 'audit.log'), encoding='utf-8').read()
    check('安全：去重时留下 duplicate_drop 审计', 'duplicate_drop' in audit_now)

    # --- 安全：过期时间戳（重放旧请求）---
    old_ts = str(int(time.time()) - 3600)
    old_sig = wecom_sig(token, old_ts, nonce, enc)
    st, _ = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, old_sig, old_ts, nonce), outer)
    check('安全：时间戳超出容忍窗口 → 403（挡住旧请求重放）', st == 403, 'status=%s' % st)

    # --- 安全：超大请求体 ---
    big = '<xml><Encrypt>' + 'A' * (2 * 1024 * 1024) + '</Encrypt></xml>'
    t0 = time.time()
    st, _ = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig, ts, nonce), big)
    check('安全：2MB 请求体被直接拒绝（400，且不读进内存）',
          st == 400 and time.time() - t0 < 3, 'status=%s 耗时 %.1fs' % (st, time.time() - t0))

    # --- 密文被改：不崩、不回复 ---
    bad_enc = enc[:-6] + ('AAAA' + enc[-2:])
    sig2 = wecom_sig(token, ts, nonce, bad_enc)
    outer2 = '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % bad_enc
    st, body = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig2, ts, nonce), outer2)
    check('企微消息：密文损坏 → 4xx（不是 200，也不崩）', 400 <= st < 500, 'status=%s' % st)

    out = stop(proc)
    check('停服务后整组进程都收干净了（不留孤儿网关）', not getattr(proc, '_leaked', False),
          '进程组仍然存在，会累积占端口')
    check('企业微信：全程没有把 Secret/AESKey 打到日志里',
          'mock-corp-secret-xyz' not in out and aes not in out and token not in out,
          out[-300:])

    # =============================== 白名单真的生效 ===============================
    home2 = tempfile.mkdtemp(prefix='plat-allow-')
    port2 = free_port()
    conf2, aes2, token2 = make_wecom_conf(home2, port2, api_base)
    write_conf(home2, conf2)
    write_conf(home2, 'ALLOW = someone_else\n', 'remote.conf')   # 故意不含 zhangsan
    proc2 = start_platform(home2, api_base, 'perl ' + GATEWAY)   # 用**真网关**
    base2 = 'http://127.0.0.1:%d/wecom' % port2
    wait_for(lambda: http_get(base2 + '?msg_signature=x&timestamp=1&nonce=2&echostr=y')[0] in (400, 403))
    PUSHES.clear()
    enc2 = wecom_encrypt(aes2, xml)
    sig3 = wecom_sig(token2, ts, nonce, enc2)
    outer3 = '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % enc2
    st, body = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base2, sig3, ts, nonce), outer3)
    time.sleep(2.5)
    check('白名单外的人：平台仍然 200（不暴露判定），但不推送任何回复',
          st == 200 and not PUSHES, 'status=%s pushes=%s' % (st, PUSHES[:1]))
    audit_txt = ''
    ap = os.path.join(home2, '.claude-agent', 'audit.log')
    if os.path.exists(ap):
        audit_txt = open(ap, encoding='utf-8').read()
    check('白名单外的人：网关审计里留下 drop_sender', 'drop_sender' in audit_txt,
          audit_txt[-300:])
    stop(proc2)

    # =============================== 中继模式（Mac 在 NAT 后面） ===============================
    # 拓扑：手机 → 平台 → platform.pl（公网）→ 中继队列 → Mac 上的 gateway --poll
    #       → /result → platform.pl 取回结果 → 推给手机
    # 这里把「中继」和「Mac」都用假的顶替，验的是 platform.pl 这一段接得对不对。
    relay = FakeRelay()
    home_rl = tempfile.mkdtemp(prefix='plat-relay-')
    port_rl = free_port()
    conf_rl, aes_rl, token_rl = make_wecom_conf(home_rl, port_rl, api_base)
    write_conf(home_rl, conf_rl + 'RELAY_URL = %s\nRELAY_TOKEN = tk\nRELAY_POLL = 1\n' % relay.url)
    proc_rl = start_platform(home_rl, api_base, fake_gateway(home_rl))
    base_rl = 'http://127.0.0.1:%d/wecom' % port_rl
    wait_for(lambda: http_get(base_rl + '?msg_signature=x&timestamp=1&nonce=2&echostr=y')[0] == 403)

    PUSHES.clear()
    xml_rl = ('<xml><FromUserName><![CDATA[zhangsan]]></FromUserName>'
              '<MsgType><![CDATA[text]]></MsgType>'
              '<Content><![CDATA[帮我看看这个报错]]></Content><MsgId>555001</MsgId></xml>')
    enc_rl = wecom_encrypt(aes_rl, xml_rl)
    ts_rl = str(int(time.time()))
    sig_rl = wecom_sig(token_rl, ts_rl, 'nr', enc_rl)
    http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base_rl, sig_rl, ts_rl, 'nr'),
              '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % enc_rl)
    queued = wait_for(lambda: relay.pushed or None, seconds=12)
    check('中继模式：消息被投进了队列（不是本地起网关）',
          bool(queued) and '帮我看看这个报错' in queued[0]['text'],
          'pushed=%s' % (relay.pushed[:1],))
    check('中继模式：投递时没在本地起网关', not os.path.exists(os.path.join(home_rl, 'gw_in.txt')))

    # 模拟 NAT 后面的 Mac：从队列取走，处理，把结果写回
    relay.replies_for['zhangsan'] = ['这是 agent 处理后的结果']
    got = wait_for(lambda: [x for x in PUSHES if 'agent 处理后的结果' in x[2]], seconds=15)
    check('中继模式：从队列取回结果并推给手机', bool(got), 'pushes=%d' % len(PUSHES))
    stop(proc_rl)
    relay.close()
    shutil.rmtree(home_rl, ignore_errors=True)

    # =============================== 处理中提示 ===============================
    home_ack = tempfile.mkdtemp(prefix='plat-ack-')
    port_ack = free_port()
    conf_ack, aes_ack, token_ack = make_wecom_conf(home_ack, port_ack, api_base)
    write_conf(home_ack, conf_ack + 'ACK_AFTER = 1\n')
    gw_ack = fake_gateway(home_ack)
    proc_ack = start_platform(home_ack, api_base, gw_ack)
    base_ack = 'http://127.0.0.1:%d/wecom' % port_ack
    wait_for(lambda: http_get(base_ack + '?msg_signature=x&timestamp=1&nonce=2&echostr=y')[0] == 403)
    PUSHES.clear()
    xml_slow = ('<xml><FromUserName><![CDATA[zhangsan]]></FromUserName>'
                '<MsgType><![CDATA[text]]></MsgType>'
                '<Content><![CDATA[SLOW 帮我把日志全看一遍]]></Content>'
                '<MsgId>999001</MsgId></xml>')
    enc_s = wecom_encrypt(aes_ack, xml_slow)
    sig_s = wecom_sig(token_ack, str(int(time.time())), 'nz', enc_s)
    ts_s = str(int(time.time()))
    sig_s = wecom_sig(token_ack, ts_s, 'nz', enc_s)
    http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base_ack, sig_s, ts_s, 'nz'),
              '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % enc_s)
    got_ack = wait_for(lambda: [x for x in PUSHES if '正在处理' in x[2]], seconds=10)
    check('处理中提示：慢回复会先回一句「正在处理」', bool(got_ack),
          'pushes=%d' % len(PUSHES))
    got_final = wait_for(lambda: [x for x in PUSHES if '网关收到' in x[2]], seconds=20)
    check('处理中提示：随后仍会发真正的结果', bool(got_final))
    if got_ack and got_final:
        order = [i for i, x in enumerate(PUSHES) if '正在处理' in x[2] or '网关收到' in x[2]]
        check('处理中提示：顺序是先提示后结果', PUSHES[order[0]][2].find('正在处理') >= 0,
              'order=%s' % order)
    stop(proc_ack)
    shutil.rmtree(home_ack, ignore_errors=True)

    # =============================== 飞书 ===============================
    home3 = tempfile.mkdtemp(prefix='plat-feishu-')
    port3 = free_port()
    ek = 'mock-encrypt-key-' + str(random.randint(10**6, 10**7))
    write_conf(home3, '\n'.join([
        'PLATFORM = feishu',
        'FEISHU_APP_ID = cli_mockapp',
        'FEISHU_APP_SECRET = mock-app-secret-abc',
        'FEISHU_ENCRYPT_KEY = %s' % ek,
        'PORT = %d' % port3,
    ]) + '\n')
    gw3 = fake_gateway(home3)
    proc3 = start_platform(home3, api_base, gw3)
    base3 = 'http://127.0.0.1:%d/feishu' % port3
    wait_for(lambda: http_post(base3, '{}')[0] in (200, 403))
    PUSHES.clear()

    # --- URL 验证（challenge）---
    ch_plain = json.dumps({'challenge': 'chal-777', 'token': 'vt', 'type': 'url_verification'})
    enc_body = json.dumps({'encrypt': feishu_encrypt(ek, ch_plain)})
    fd_ts, fd_nc = str(int(time.time())), 'n0nce'
    fd_sig = hashlib.sha256((fd_ts + fd_nc + ek + enc_body).encode()).hexdigest()
    st, body = http_post(base3, enc_body, {
        'X-Lark-Request-Timestamp': fd_ts,
        'X-Lark-Request-Nonce': fd_nc,
        'X-Lark-Signature': fd_sig,
    })
    check('飞书 URL 验证：解密后原样回 challenge',
          st == 200 and 'chal-777' in body, 'status=%s body=%s' % (st, body[:120]))

    # --- 签名错 ---
    st, body = http_post(base3, enc_body, {
        'X-Lark-Request-Timestamp': fd_ts,
        'X-Lark-Request-Nonce': fd_nc,
        'X-Lark-Signature': 'bad-signature',
    })
    check('飞书：签名错 → 403', st == 403, 'status=%s' % st)

    # --- 加密的事件消息 ---
    ev = {
        'schema': '2.0',
        'header': {'event_type': 'im.message.receive_v1'},
        'event': {
            'sender': {'sender_id': {'open_id': 'ou_abc123'}},
            'message': {'content': json.dumps({'text': '看看日志有没有报错'})},
        },
    }
    ev_body = json.dumps({'encrypt': feishu_encrypt(ek, json.dumps(ev))})
    fd_sig2 = hashlib.sha256((fd_ts + fd_nc + ek + ev_body).encode()).hexdigest()
    st, body = http_post(base3, ev_body, {
        'X-Lark-Request-Timestamp': fd_ts,
        'X-Lark-Request-Nonce': fd_nc,
        'X-Lark-Signature': fd_sig2,
    })
    check('飞书事件：立即回 200（平台要求快速应答）', st == 200, 'status=%s' % st)

    gin3 = wait_for(lambda: os.path.exists(os.path.join(home3, 'gw_in.txt')))
    got3 = ''
    if gin3:
        with open(os.path.join(home3, 'gw_in.txt'), encoding='utf-8') as f:
            got3 = f.read()
    check('飞书事件：解密后真的交给了网关（open_id 与正文都对）',
          'ou_abc123' in got3 and '看看日志有没有报错' in got3, got3[:200])

    pushed3 = wait_for(lambda: [x for x in PUSHES if x[0] == 'feishu'])
    sent3 = pushed3[0][2] if pushed3 else ''
    check('飞书事件：回复被推回平台（im/v1/messages）', bool(pushed3), PUSHES[:2])
    check('飞书事件：推送目标是 open_id', 'ou_abc123' in sent3, sent3[:200])
    check('飞书事件：content 是 JSON 字符串形式（飞书要求）',
          '"content":"{\\"text\\"' in sent3.replace(' ', ''), sent3[:200])

    out3 = stop(proc3)
    check('飞书：全程没有把 App Secret / EncryptKey 打到日志里',
          'mock-app-secret-abc' not in out3 and ek not in out3, out3[-300:])

    # =============================== 配置与权限 ===============================
    p = subprocess.run(['/usr/bin/perl', PLATFORM, '--check'], cwd=ROOT,
                       env={**os.environ, 'HOME': home, 'PLATFORM_CONF': os.path.join(home, '.claude-agent', 'platform.conf')},
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=180, text=True, encoding='utf-8')
    check('--check 在配置齐全时报 OK', p.returncode == 0 and '配置齐全' in p.stdout, p.stdout + p.stderr)

    p = subprocess.run(['/usr/bin/perl', PLATFORM, '--check'], cwd=ROOT,
                       env={**os.environ, 'HOME': tempfile.mkdtemp(), 'PLATFORM_CONF': '/nonexistent/x.conf'},
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=180, text=True, encoding='utf-8')
    check('--check 在缺配置时报失败并指出缺什么', p.returncode != 0 and '缺少' in p.stdout,
          p.stdout + p.stderr)

    mode = stat.S_IMODE(os.stat(os.path.join(home, '.claude-agent', 'platform.conf')).st_mode)
    check('凭据文件权限是 0600', mode == 0o600, oct(mode))

    # 在 umask 022 下新建也要是 0600（open 后再 chmod 有一瞬间是 0644 的窗口）
    home4 = tempfile.mkdtemp(prefix='plat-umask-')
    old_umask = os.umask(0o022)
    try:
        p4 = write_conf(home4, 'PLATFORM = wecom\nWECOM_CORP_ID = x\nWECOM_AGENT_ID = 1\n'
                               'WECOM_CORP_SECRET = s\nWECOM_AES_KEY = ' + 'A' * 43 + '\nPORT = 1\n')
        m4 = stat.S_IMODE(os.stat(p4).st_mode)
    finally:
        os.umask(old_umask)
    check('umask 022 下写出的凭据仍是 0600（无 0644 窗口）', m4 == 0o600, oct(m4))

    check('默认只监听 127.0.0.1（回调正文是明文消息，不该撒到局域网）',
          ('监听 127.0.0.1:%d' % port3) in out3, out3[:200])
    shutil.rmtree(home4, ignore_errors=True)

    mock.shutdown()
    for d in (home, home2, home3):
        shutil.rmtree(d, ignore_errors=True)

    bad = [n for n, ok in results if not ok]
    print('\n%d/%d 通过' % (len(results) - len(bad), len(results)))
    if bad:
        print('失败项：')
        for n in bad:
            print('  · ' + n)
            # GitHub Actions 会把这些变成 annotation：没有 token 也能读到的失败细节
            print('::error::平台测试失败: %s' % n)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
