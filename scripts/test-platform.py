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
import subprocess
import sys
import tempfile
import threading
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
    if not ok and detail:
        print('       细节: %s' % str(detail)[:500].replace('\n', ' / '))


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


def fake_gateway(home):
    p = os.path.join(home, 'fakegw.sh')
    with open(p, 'w', encoding='utf-8') as f:
        f.write('#!/bin/bash\n'
                'read -r line\n'
                'echo "$line" > "$HOME/gw_in.txt"\n'
                'echo "网关收到：$line"\n')
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
    p = subprocess.Popen(['/usr/bin/perl', PLATFORM, '--serve'], cwd=ROOT, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding='utf-8')
    return p


def stop(p):
    p.terminate()
    try:
        out = p.communicate(timeout=8)[0]
    except subprocess.TimeoutExpired:
        p.kill()
        out = p.communicate()[0]
    return out or ''


# ----------------------------------------------------------------- 主流程
def main():
    if not os.path.exists(PLATFORM):
        print('找不到 %s' % PLATFORM)
        return 1
    if subprocess.run(['openssl', 'version'], capture_output=True).returncode != 0:
        print('本机没有 openssl，跳过（platform.pl 依赖系统 openssl 做 AES）')
        return 0

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
    ts, nonce = '1700000000', 'abc123'
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
           '<MsgId>123456</MsgId></xml>')
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

    # --- 签名错：丢弃且不回复 ---
    PUSHES.clear()
    st, body = http_post('%s?msg_signature=bad&timestamp=%s&nonce=%s' % (base, ts, nonce), outer)
    time.sleep(1.5)
    check('企微消息：签名错 → 403 且不推任何东西', st == 403 and not PUSHES,
          'status=%s pushes=%s' % (st, PUSHES[:1]))

    # --- 密文被改：不崩、不回复 ---
    bad_enc = enc[:-6] + ('AAAA' + enc[-2:])
    sig2 = wecom_sig(token, ts, nonce, bad_enc)
    outer2 = '<xml><Encrypt><![CDATA[%s]]></Encrypt></xml>' % bad_enc
    st, body = http_post('%s?msg_signature=%s&timestamp=%s&nonce=%s' % (base, sig2, ts, nonce), outer2)
    check('企微消息：密文损坏 → 4xx（不是 200，也不崩）', 400 <= st < 500, 'status=%s' % st)

    out = stop(proc)
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
    fd_ts, fd_nc = '1700000000', 'n0nce'
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
                       capture_output=True, text=True, encoding='utf-8')
    check('--check 在配置齐全时报 OK', p.returncode == 0 and '配置齐全' in p.stdout, p.stdout + p.stderr)

    p = subprocess.run(['/usr/bin/perl', PLATFORM, '--check'], cwd=ROOT,
                       env={**os.environ, 'HOME': tempfile.mkdtemp(), 'PLATFORM_CONF': '/nonexistent/x.conf'},
                       capture_output=True, text=True, encoding='utf-8')
    check('--check 在缺配置时报失败并指出缺什么', p.returncode != 0 and '缺少' in p.stdout,
          p.stdout + p.stderr)

    mode = stat.S_IMODE(os.stat(os.path.join(home, '.claude-agent', 'platform.conf')).st_mode)
    check('凭据文件权限是 0600', mode == 0o600, oct(mode))

    mock.shutdown()
    for d in (home, home2, home3):
        shutil.rmtree(d, ignore_errors=True)

    bad = [n for n, ok in results if not ok]
    print('\n%d/%d 通过' % (len(results) - len(bad), len(results)))
    if bad:
        print('失败项：')
        for n in bad:
            print('  · ' + n)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
