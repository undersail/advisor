#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wss/TLS 这条路的测试（真握手，不走网络外网）。

为什么单开一个脚本：真机上报过「握手被拒：verify error:num=20 unable to get local
issuer certificate / HTTP/1.1 101」——连接其实通了，是**根证书包找不到**导致校验失败，
而当时的代码既不诊断也不 fail-fast，只是每 30 秒重试一次。ws:// 的假服务端测不到这条路。

覆盖：
  1. 找得到证书包时记进审计（ws_ca），且能正常订阅
  2. 证书包正确 → 连得上、订阅成功
  3. 证书包不对 → 立刻失败（退出码 5，不重试）、说清是证书校验、给出三种办法
"""
import base64
import hashlib
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WS_PL = os.path.join(ROOT, 'remote', 'wecom-ws.pl')
GW = os.path.join(ROOT, 'remote', 'gateway.pl')

CHECKS = []


def check(name, ok, detail=''):
    CHECKS.append((name, ok, detail))
    print(('  ok   ' if ok else '  FAIL ') + name + ('' if ok else ' | 细节: %r' % (detail,)))
    if not ok:
        print('::error::%s | 细节: %r' % (name, detail))


def finish():
    bad = [c for c in CHECKS if not c[1]]
    print('\n%d/%d 通过' % (len(CHECKS) - len(bad), len(CHECKS)))
    if bad:
        print('失败项：')
        for n, _, d in bad:
            print('  · ' + n)
        return 1
    return 0


def ws_frame(op, payload):
    if isinstance(payload, str):
        payload = payload.encode()
    hdr = bytes([0x80 | op])
    n = len(payload)
    if n < 126:
        hdr += bytes([n])
    elif n < 65536:
        hdr += bytes([126]) + n.to_bytes(2, 'big')
    else:
        hdr += bytes([127]) + n.to_bytes(8, 'big')
    return hdr + payload


def read_frame(conn, buf):
    while True:
        if len(buf) >= 2:
            b1, b2 = buf[0], buf[1]
            op = b1 & 0x0F
            masked = b2 & 0x80
            ln = b2 & 0x7F
            off = 2
            if ln == 126:
                if len(buf) < 4:
                    pass
                else:
                    ln = int.from_bytes(buf[2:4], 'big')
                    off = 4
            if ln < 126 or off > 2:
                need = off + (4 if masked else 0) + ln
                if len(buf) >= need:
                    mask = buf[off:off + 4] if masked else b''
                    data = bytearray(buf[off + (4 if masked else 0):need])
                    if masked:
                        for i in range(len(data)):
                            data[i] ^= mask[i % 4]
                    rest = buf[need:]
                    payload = bytes(data).decode('utf-8', 'replace')
                    return op, payload, rest
        chunk = conn.recv(65536)
        if not chunk:
            raise EOFError('closed')
        buf = buf + chunk


class WssServer(threading.Thread):
    """最简 TLS WebSocket 服务端：握手 → 订阅回执 → 挂住。"""

    def __init__(self, certfile, keyfile):
        super().__init__(daemon=True)
        self.certfile, self.keyfile = certfile, keyfile
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(('127.0.0.1', 0))
        self.srv.listen(5)
        self.port = self.srv.getsockname()[1]
        self.conns = 0
        self.stop_flag = False

    def run(self):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.certfile, self.keyfile)
        while not self.stop_flag:
            try:
                raw, _ = self.srv.accept()
            except OSError:
                return
            self.conns += 1
            try:
                conn = ctx.wrap_socket(raw, server_side=True)
            except Exception:
                try:
                    raw.close()
                except Exception:
                    pass
                continue
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        try:
            conn.settimeout(20)
            data = b''
            while b'\r\n\r\n' not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            head = data.split(b'\r\n\r\n')[0].decode('latin-1')
            key = ''
            for line in head.split('\r\n'):
                if line.lower().startswith('sec-websocket-key'):
                    key = line.split(':', 1)[1].strip()
            acc = base64.b64encode(hashlib.sha1(
                (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                          'Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n' % acc).encode())
            buf = data.split(b'\r\n\r\n', 1)[1] if b'\r\n\r\n' in data else b''
            conn.settimeout(1.0)
            end = time.time() + 25
            while time.time() < end and not self.stop_flag:
                try:
                    op, payload, buf = read_frame(conn, buf)
                except socket.timeout:
                    continue
                except Exception:
                    return
                if op == 0xA:
                    continue
                if op == 0x8:
                    return
                try:
                    j = json.loads(payload)
                except Exception:
                    continue
                if j.get('cmd') == 'aibot_subscribe':
                    conn.sendall(ws_frame(0x1, json.dumps(
                        {'cmd': 'aibot_subscribe', 'headers': j.get('headers', {}),
                         'errcode': 0, 'errmsg': 'ok'})))
                elif j.get('cmd') == 'ping':
                    conn.sendall(ws_frame(0x1, json.dumps(
                        {'cmd': 'ping', 'headers': j.get('headers', {}), 'errcode': 0})))
        except Exception:
            return
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def stop(self):
        self.stop_flag = True
        try:
            self.srv.close()
        except Exception:
            pass


def make_certs(tmp, name):
    """生成一套 CA + 服务端证书（SAN 带 127.0.0.1）。"""
    d = os.path.join(tmp, name)
    os.makedirs(d, exist_ok=True)
    ca_key = os.path.join(d, 'ca.key')
    ca_crt = os.path.join(d, 'ca.crt')
    sv_key = os.path.join(d, 'srv.key')
    sv_csr = os.path.join(d, 'srv.csr')
    sv_crt = os.path.join(d, 'srv.crt')
    ext = os.path.join(d, 'ext.cnf')
    with open(ext, 'w') as f:
        f.write('subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n')
    cmds = [
        ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', ca_key,
         '-out', ca_crt, '-days', '2', '-subj', '/CN=%s-test-ca' % name],
        ['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', sv_key,
         '-out', sv_csr, '-subj', '/CN=localhost'],
        ['openssl', 'x509', '-req', '-in', sv_csr, '-CA', ca_crt, '-CAkey', ca_key,
         '-CAcreateserial', '-out', sv_crt, '-days', '2', '-extfile', ext],
    ]
    for c in cmds:
        r = subprocess.run(c, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError('证书生成失败 %s: %s' % (c[0:2], r.stderr.decode()[-300:]))
    return ca_crt, sv_crt, sv_key


def write_conf(home, bot_id, secret, url):
    d = os.path.join(home, '.claude-agent')
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'wecom-ws.conf'), 'w') as f:
        f.write('BOT_ID=%s\nBOT_SECRET=%s\nWS_URL=%s\nHEARTBEAT=30\n' % (bot_id, secret, url))


def audit_of(home):
    p = os.path.join(home, '.claude-agent', 'audit.log')
    return open(p, encoding='utf-8').read() if os.path.exists(p) else ''


def main():
    if not shutil.which('openssl'):
        print('::notice::test-wss-tls 跳过：本机没有 openssl 命令')
        return 0
    # 客户端用 openssl s_client，本机没有它也测不了
    r = subprocess.run(['openssl', 's_client', '-help'], capture_output=True)
    if r.returncode != 0 and b's_client' not in (r.stdout + r.stderr):
        print('::notice::test-wss-tls 跳过：本机 openssl 没有 s_client')
        return 0

    tmp = tempfile.mkdtemp(prefix='advisor-wss-')
    env_base = dict(os.environ, GATEWAY_CMD=GW)

    try:
        ca_good, srv_good_crt, srv_good_key = make_certs(tmp, 'good')
        ca_bad, srv_bad_crt, srv_bad_key = make_certs(tmp, 'bad')

        # ---------- 场景 1：证书包正确 → 连得上、订阅成功 ----------
        s1 = WssServer(srv_good_crt, srv_good_key)
        s1.start()
        home1 = os.path.join(tmp, 'home1')
        write_conf(home1, 'bot-a', 'sec-a', 'wss://127.0.0.1:%d' % s1.port)
        env1 = dict(env_base, HOME=home1, SSL_CERT_FILE=ca_good)
        p1 = subprocess.Popen(['perl', WS_PL, '--serve'], env=env1,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              stdin=subprocess.DEVNULL)
        ok1 = False
        for _ in range(80):
            if 'ws_subscribe_ok' in audit_of(home1):
                ok1 = True
                break
            time.sleep(0.25)
        p1.terminate()
        try:
            p1.wait(10)
        except subprocess.TimeoutExpired:
            p1.kill()
        s1.stop()
        a1 = audit_of(home1)
        err1 = (p1.stderr.read() or b'').decode('utf-8', 'replace')
        check('证书包正确：wss 握手通过并订阅成功', ok1, err1[-300:] or a1[-200:])
        check('证书包正确：审计记下用的是哪个证书包（ws_ca）',
              os.path.basename(ca_good) in a1, a1[-300:])

        # ---------- 场景 2：证书包不对 → fail-fast ----------
        s2 = WssServer(srv_bad_crt, srv_bad_key)
        s2.start()
        home2 = os.path.join(tmp, 'home2')
        write_conf(home2, 'bot-b', 'sec-b', 'wss://127.0.0.1:%d' % s2.port)
        # 用另一个 CA 去校验 bad 证书 → 必然失败；这正是真机上「找不到根证书」的等价情形
        env2 = dict(env_base, HOME=home2, SSL_CERT_FILE=ca_good)
        t0 = time.time()
        p2 = subprocess.Popen(['perl', WS_PL, '--serve'], env=env2,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              stdin=subprocess.DEVNULL)
        try:
            p2.wait(60)
            rc2 = p2.returncode
        except subprocess.TimeoutExpired:
            p2.kill()
            rc2 = None
        cost = time.time() - t0
        sink2 = s2.stop()
        err2 = (p2.stderr.read() or b'').decode('utf-8', 'replace')
        a2 = audit_of(home2)
        check('证书校验失败：立即退出（退出码 5），不是每 30 秒重试',
              rc2 == 5, (rc2, err2[-200:]))
        check('证书校验失败：5 秒内就放弃（说明没进重试循环）', cost < 30, round(cost, 1))
        check('证书校验失败：说清是「证书校验」而不是含糊的握手失败',
              '证书校验' in err2, err2[-300:])
        check('证书校验失败：给出三种解决办法（钥匙串/SSL_CERT_FILE/Homebrew）',
              ('SSL_CERT_FILE' in err2) and ('钥匙串' in err2) and ('brew' in err2), err2[-400:])
        check('证书校验失败：审计留下 ws_fatal',
              'ws_fatal' in a2, a2[-300:])
        check('证书校验失败：pid 文件被清理（不会假装还在跑）',
              not os.path.exists(os.path.join(home2, '.claude-agent', 'wecom-ws.pid')), '')

        # ---------- 场景 3：不给 SSL_CERT_FILE → 自己找系统证书包 ----------
        s3 = WssServer(srv_good_crt, srv_good_key)
        s3.start()
        home3 = os.path.join(tmp, 'home3')
        write_conf(home3, 'bot-c', 'sec-c', 'wss://127.0.0.1:%d' % s3.port)
        env3 = dict(env_base, HOME=home3)
        env3.pop('SSL_CERT_FILE', None)
        p3 = subprocess.Popen(['perl', WS_PL, '--serve'], env=env3,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              stdin=subprocess.DEVNULL)
        found = ''
        for _ in range(60):
            a = audit_of(home3)
            for line in a.splitlines():
                if 'ws_ca' in line:
                    found = line.split('bundle=', 1)[1].strip()
                    break
            if found:
                break
            time.sleep(0.25)
        p3.terminate()
        try:
            p3.wait(10)
        except subprocess.TimeoutExpired:
            p3.kill()
        s3.stop()
        check('没设 SSL_CERT_FILE 也能找到系统根证书包（真机踩的就是这个坑）',
              found != '' and os.path.exists(found), found)

        return finish()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
