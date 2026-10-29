#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""企业微信长连接客户端（remote/wecom-ws.pl）的端到端测试。

不需要企业微信、不需要真凭据、不碰真网络：本机起一个**假的长连接服务端**（明文 ws，
127.0.0.1），按官方协议（文档 101463）收发帧，验客户端的行为：

  · 握手 / 订阅帧字段（cmd=aibot_subscribe、body.bot_id、body.secret）
  · 收到 aibot_msg_callback → 交给 gateway（这里是假网关）→ 发 aibot_respond_msg
  · 回复沿用回调的 req_id（这样才知道回的是哪条消息）
  · 白名单外的人：假网关回空串 → 客户端**不发**任何回复（判定权在 gateway，不在客户端）
  · 长回复按字节分片，每片不超上限，合起来内容不丢
  · 非文本消息明确回一句（不静默吞）
  · 服务端发 ping 帧 → 客户端回 pong 帧
  · 订阅被拒（errcode≠0）时 --check 非 0 退出并指出查 BotID / Secret
  · 心跳连续两次没回执 → 判死并重连（服务端能看到第二条连接）
  · 审计日志逐条落盘且 0600；Secret 不出现在任何输出里

TLS 那一层（openssl s_client 管道）没法在无凭据环境里验，这里只验协议与业务；
真 wss 的验收步骤写在 docs/manual_test_mac.md。

★ 这个测试自己踩过一次坑：读帧的循环一旦抛异常，后面「收集到的结果」就全丢了，
  于是表现成「客户端没回」而不是「测试自己挂了」。所以下面统一用 pump() 收集，
  结果边收边存进 got，循环异常只结束当前阶段，不影响已有结论。
"""
import base64
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WS_PL = os.path.join(ROOT, 'remote', 'wecom-ws.pl')
RESULTS = []


def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok)))
    if ok:
        print('  ok   %s' % name)
    else:
        print('  FAIL %s' % name)
        if detail != '':
            print('       细节: %s' % str(detail)[:400])
        print('::error::%s | 细节: %s' % (name, str(detail)[:400]))


# ---------------------------------------------------------------- WS 帧编解码
def ws_frame(opcode, payload=b'', mask=False):
    if isinstance(payload, str):
        payload = payload.encode('utf-8')
    n = len(payload)
    hdr = struct.pack('!BB', 0x80 | opcode,
                      (0x80 if mask else 0) | (n if n < 126 else (126 if n < 65536 else 127)))
    if n >= 65536:
        hdr += struct.pack('!Q', n)
    elif n >= 126:
        hdr += struct.pack('!H', n)
    if not mask:
        return hdr + payload
    m = os.urandom(4)
    return hdr + m + bytes(b ^ m[i % 4] for i, b in enumerate(payload))


class WSServer(threading.Thread):
    """极简 WebSocket 服务端：只做测试需要的那点事。"""

    def __init__(self, on_client):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(5)
        self.port = self.sock.getsockname()[1]
        self.on_client = on_client
        self.conn_count = 0
        self.stop_flag = False
        self.one_shot = False
        self.rest = b''

    def run(self):
        while not self.stop_flag:
            try:
                self.sock.settimeout(1.0)
                conn, _ = self.sock.accept()
            except (socket.timeout, OSError):
                continue
            self.conn_count += 1
            try:
                self.handle(conn, self.conn_count)
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass
            if self.one_shot:
                return

    def handle(self, conn, idx):
        conn.settimeout(20)
        buf = b''
        while b'\r\n\r\n' not in buf:
            d = conn.recv(4096)
            if not d:
                return
            buf += d
        head, rest = buf.split(b'\r\n\r\n', 1)
        key = ''
        for line in head.decode('latin-1').split('\r\n'):
            if line.lower().startswith('sec-websocket-key:'):
                key = line.split(':', 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1(
            (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        conn.sendall(('HTTP/1.1 101 Switching Protocols\r\n'
                      'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                      'Sec-WebSocket-Accept: %s\r\n\r\n' % accept).encode())
        self.rest = rest
        self.on_client(self, conn, idx)

    def read_frame(self, conn, buf_holder):
        def need(n):
            while len(buf_holder[0]) < n:
                d = conn.recv(65536)
                if not d:
                    raise ConnectionError('closed')
                buf_holder[0] += d
        need(2)
        b1, b2 = buf_holder[0][0], buf_holder[0][1]
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        ln = b2 & 0x7F
        off = 2
        if ln == 126:
            need(4)
            ln = struct.unpack('!H', buf_holder[0][2:4])[0]
            off = 4
        elif ln == 127:
            need(10)
            ln = struct.unpack('!Q', buf_holder[0][2:10])[0]
            off = 10
        mask = b'\x00\x00\x00\x00'
        if masked:
            need(off + 4)
            mask = buf_holder[0][off:off + 4]
            off += 4
        need(off + ln)
        payload = buf_holder[0][off:off + ln]
        buf_holder[0] = buf_holder[0][off + ln:]
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload.decode('utf-8', 'replace')

    def send_json(self, conn, obj):
        self.send(conn, 0x1, json.dumps(obj, ensure_ascii=False))

    def send(self, conn, opcode, payload):
        conn.sendall(ws_frame(opcode, payload))

    def pump(self, conn, buf_holder, got, seconds):
        """在一段时间窗里收帧：文本帧塞进 got['replies']（能解析的才算），pong 计数。

        ★ 这里必须用**短超时循环**，不能靠阻塞 recv + 外层 deadline：
          阻塞 recv 会一直等到 socket timeout（20s），把「阶段时长」整个拖长，
          后面的消息还没发出去，测试就已经判失败了 —— 会表现成「客户端不回」。
        """
        end = time.time() + seconds
        old_timeout = conn.gettimeout()
        conn.settimeout(0.5)
        try:
            while time.time() < end:
                try:
                    op, payload = self.read_frame(conn, buf_holder)
                except socket.timeout:
                    continue
                except Exception:
                    return
                if op == 0xA:
                    got['pong'] += 1
                    continue
                if op == 0x9:
                    self.send(conn, 0xA, payload)
                    continue
                if op != 0x1:
                    continue
                try:
                    obj = json.loads(payload)
                except ValueError:
                    continue
                got['replies'].append(obj)
                # 长回复是多片的：收到「最后一片」才算收全，别在第一片上就收工
                if (obj.get('headers') or {}).get('req_id') == 'msg4':
                    parts = [((r.get('body') or {}).get('text') or {}).get('content', '')
                             for r in replies_for(got, 'msg4')]
                    m = re.match(r'^（(\d+)/(\d+)）', parts[-1] or '')
                    if (m and m.group(1) == m.group(2)) or '收尾' in (parts[-1] or ''):
                        return
        finally:
            conn.settimeout(old_timeout)


def replies_for(got, req_id):
    return [r for r in got['replies']
            if (r.get('headers') or {}).get('req_id') == req_id]


def wait_for(fn, seconds=25, step=0.1):
    end = time.time() + seconds
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return None


# ---------------------------------------------------------------- 假网关
# 判定权在 gateway.pl（真身），这里只模拟它的**行为契约**：
#   stdin 一行 {"from","text"} → stdout 一行 {"from","reply"}；非白名单回空串。
FAKE_GW = r'''
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    frm, text = req.get('from', ''), req.get('text', '')
    if frm != 'allowed':
        reply = ''
    elif text.startswith('ASK'):
        # 需要确认：先吐一行 ask，等调用方回一行 answer，再给最终结果
        sys.stdout.write(json.dumps({'from': frm, 'ask': 'allow write /tmp/a.txt ?',
                                     'danger': True}) + '\n')
        sys.stdout.flush()
        ans = 'none'
        for l2 in sys.stdin:
            if not l2.strip():
                continue
            try:
                j2 = json.loads(l2)
            except Exception:
                continue
            if 'answer' in j2:
                ans = j2['answer']
                break
        reply = 'REPLY:answer=' + ans
    elif text.startswith('LONG'):
        reply = 'L' * 3000 + '收尾'
    elif text.startswith('SLOW'):
        import time
        time.sleep(3.5)                  # 慢回复：客户端应该先回一句「正在处理」
        reply = 'REPLY:' + text
    else:
        reply = 'REPLY:' + text
    sys.stdout.write(json.dumps({'from': frm, 'reply': reply}, ensure_ascii=False) + '\n')
    sys.stdout.flush()
'''


def write_conf(home, **kw):
    d = os.path.join(home, '.claude-agent')
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, 'wecom-ws.conf')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('# 测试用\n')
        for k, v in kw.items():
            f.write('%s=%s\n' % (k, v))
    os.chmod(path, 0o600)
    return path


def msg_frame(req_id, userid, msgtype, text=''):
    body = {'msgid': 'm-' + req_id, 'aibotid': 'bot', 'chatid': 'c1', 'chattype': 'single',
            'from': {'userid': userid}, 'msgtype': msgtype}
    if msgtype == 'text':
        body['text'] = {'content': text}
    return {'cmd': 'aibot_msg_callback', 'headers': {'req_id': req_id}, 'body': body}


def main():
    check('客户端脚本存在', os.path.exists(WS_PL), WS_PL)
    if not os.path.exists(WS_PL):
        return finish()

    tmp = tempfile.mkdtemp(prefix='wecomws-')
    home = os.path.join(tmp, 'home')
    os.makedirs(home, exist_ok=True)
    gw = os.path.join(tmp, 'fake_gw.py')
    with open(gw, 'w', encoding='utf-8') as f:
        f.write(FAKE_GW)
    gw_cmd = '%s %s' % (sys.executable, gw)

    # ---------------- 场景 1：订阅 → 收消息 → 回复 → 分片 ----------------
    got = {'subscribe': None, 'replies': [], 'pong': 0}

    def on_client(srv, conn, idx):
        buf = [srv.rest]
        op, payload = srv.read_frame(conn, buf)
        got['subscribe'] = json.loads(payload)
        rid = (got['subscribe'].get('headers') or {}).get('req_id', '')
        srv.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': {'req_id': rid},
                             'errcode': 0, 'errmsg': 'ok'})
        srv.send(conn, 0x9, b'hi')                      # 服务端 ping 帧
        srv.send_json(conn, msg_frame('msg1', 'allowed', 'text', '你好'))
        srv.pump(conn, buf, got, 4)
        srv.send_json(conn, msg_frame('msg2', 'stranger', 'text', '我是外人'))
        srv.send_json(conn, msg_frame('msg3', 'allowed', 'image'))
        srv.pump(conn, buf, got, 5)
        srv.send_json(conn, msg_frame('msg4', 'allowed', 'text', 'LONG please'))
        srv.pump(conn, buf, got, 12)
        srv.send_json(conn, msg_frame('msg5', 'allowed', 'text', 'SLOW please'))
        srv.pump(conn, buf, got, 12)
        # 需要确认的操作：网关吐 ask → 客户端把问题发到手机 → 用户回 y → 网关继续
        srv.send_json(conn, msg_frame('msg6', 'allowed', 'text', 'ASK please'))
        srv.pump(conn, buf, got, 10)
        srv.send_json(conn, msg_frame('msg7', 'allowed', 'text', 'y'))
        srv.pump(conn, buf, got, 10)

    srv = WSServer(on_client)
    srv.one_shot = True
    srv.start()
    write_conf(home, BOT_ID='bot-123', BOT_SECRET='sec-xyz',
               WS_URL='ws://127.0.0.1:%d' % srv.port,
               HEARTBEAT=30, TEXT_LIMIT=1900, ACK_AFTER=2)
    env = dict(os.environ, HOME=home, GATEWAY_CMD=gw_cmd)
    proc = subprocess.Popen(['perl', WS_PL, '--serve'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, env=env)
    # 等到「最后一条」的结果回来再收工：早停会把后面的阶段掐掉，表现成「客户端没回」
    wait_for(lambda: any('REPLY:answer=' in (((r.get('body') or {}).get('text') or {})
                                          .get('content', '')) for r in got['replies']), seconds=60)
    proc.terminate()
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()
    err = (proc.stderr.read() or b'').decode('utf-8', 'replace')

    sub = got['subscribe'] or {}
    check('建连后第一帧就是订阅帧', bool(sub), sub)
    check('订阅 cmd = aibot_subscribe', sub.get('cmd') == 'aibot_subscribe', sub.get('cmd'))
    check('订阅 body 带 bot_id', (sub.get('body') or {}).get('bot_id') == 'bot-123',
          sub.get('body'))
    check('订阅 body 带 secret', (sub.get('body') or {}).get('secret') == 'sec-xyz',
          sub.get('body'))
    check('订阅 req_id 以 aibot_subscribe 开头',
          (sub.get('headers') or {}).get('req_id', '').startswith('aibot_subscribe'),
          sub.get('headers'))

    r1 = replies_for(got, 'msg1')
    check('白名单内的一条文本消息得到了回复', bool(r1),
          [x.get('headers') for x in got['replies']])
    if r1:
        check('回复 cmd = aibot_respond_msg', r1[0].get('cmd') == 'aibot_respond_msg',
              r1[0].get('cmd'))
        check('回复沿用回调的 req_id', (r1[0].get('headers') or {}).get('req_id') == 'msg1',
              r1[0].get('headers'))
        check('回复内容来自网关',
              'REPLY:你好' in ((r1[0].get('body') or {}).get('text') or {}).get('content', ''),
              r1[0].get('body'))
        check('回复体是 text 类型', (r1[0].get('body') or {}).get('msgtype') == 'text',
              r1[0].get('body'))

    r3 = replies_for(got, 'msg3')
    check('非文本消息：明确回一句而不是静默吞', bool(r3),
          [x.get('headers') for x in got['replies']])
    if r3:
        check('非文本消息的提示文案正确',
              '暂只支持文本' in ((r3[0].get('body') or {}).get('text') or {}).get('content', ''),
              r3[0].get('body'))

    check('白名单外的人：不发任何回复', not replies_for(got, 'msg2'),
          [x.get('headers') for x in got['replies']])
    check('服务端 ping 帧 → 客户端回了 pong 帧', got['pong'] >= 1, got['pong'])

    r4 = replies_for(got, 'msg4')
    check('长回复被拆成多条', len(r4) >= 2, len(r4))
    if r4:
        parts = [((r.get('body') or {}).get('text') or {}).get('content', '') for r in r4]
        check('长回复每片都不超过上限（含「（n/m）」前缀）',
              all(len(p.encode()) <= 1900 for p in parts), [len(p.encode()) for p in parts])
        check('长回复带分片编号', all(p.startswith('（') for p in parts), parts[0][:8])
        check('长回复分片后内容没丢（含结尾）', '收尾' in ''.join(parts), parts[-1][-20:])

    r5 = replies_for(got, 'msg5')
    texts5 = [((r.get('body') or {}).get('text') or {}).get('content', '') for r in r5]
    check('慢回复：先回一句「正在处理」（人不会干等）',
          any('正在处理' in t for t in texts5), texts5[:2])
    check('慢回复：处理完仍然把真正的结果发出来',
          any('REPLY:SLOW' in t for t in texts5), texts5)

    r6 = replies_for(got, 'msg6')
    texts6 = [((r.get('body') or {}).get('text') or {}).get('content', '') for r in r6]
    check('需要确认时：把问题发到手机', any('需要你' in t and '确认' in t for t in texts6), texts6[:2])
    check('需要确认时：告诉用户怎么回（y / n）',
          any('y' in t and 'n' in t for t in texts6), texts6[:2])
    check('危险操作会标出来（⚠）', any('⚠' in t for t in texts6), texts6[:2])
    r7 = replies_for(got, 'msg7')
    texts7 = [((r.get('body') or {}).get('text') or {}).get('content', '') for r in r7]
    check('手机回 y 之后：网关收到 y 并继续跑完', any('REPLY:answer=y' in t for t in texts7), texts7[:3])

    cf = os.path.join(home, '.claude-agent', 'wecom-ws.conf')
    check('配置文件权限 0600', oct(os.stat(cf).st_mode & 0o777) == '0o600', '')

    audit_path = os.path.join(home, '.claude-agent', 'audit.log')
    txt = open(audit_path, encoding='utf-8').read() if os.path.exists(audit_path) else ''
    check('审计日志有 ws_inbound / ws_sent / gateway_done',
          all(k in txt for k in ('ws_inbound', 'ws_sent', 'gateway_done')), txt[-300:])
    check('审计日志权限 0600',
          os.path.exists(audit_path)
          and oct(os.stat(audit_path).st_mode & 0o777) == '0o600', '')
    check('Secret 不出现在输出里', 'sec-xyz' not in err, err[-300:])
    check('输出里没有 Wide character 警告', 'Wide character' not in err, err[-300:])

    # ---------------- 场景 2：订阅被拒 → --check 必须失败 ----------------
    def on_reject(srv2, conn, idx):
        buf = [srv2.rest]
        op, payload = srv2.read_frame(conn, buf)
        j = json.loads(payload)
        srv2.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'],
                              'errcode': 40001, 'errmsg': 'invalid credential'})

    srv2 = WSServer(on_reject)
    srv2.one_shot = True
    srv2.start()
    home2 = os.path.join(tmp, 'home2')
    write_conf(home2, BOT_ID='bad', BOT_SECRET='bad',
               WS_URL='ws://127.0.0.1:%d' % srv2.port)
    p2 = subprocess.run(['perl', WS_PL, '--check'], env=dict(os.environ, HOME=home2),
                        stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    o2 = (p2.stdout + p2.stderr).decode('utf-8', 'replace')
    check('凭据错误：--check 非 0 退出', p2.returncode != 0, p2.returncode)
    check('凭据错误：说明 errcode', '40001' in o2, o2[-300:])
    check('凭据错误：指出去查 BotID / Secret', ('BotID' in o2 or 'Secret' in o2), o2[-300:])

    # ---------------- 场景 3：--check 成功路径 ----------------
    def on_ok(srv3, conn, idx):
        buf = [srv3.rest]
        op, payload = srv3.read_frame(conn, buf)
        j = json.loads(payload)
        srv3.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'], 'errcode': 0})

    srv3 = WSServer(on_ok)
    srv3.one_shot = True
    srv3.start()
    home3 = os.path.join(tmp, 'home3')
    write_conf(home3, BOT_ID='ok', BOT_SECRET='ok', WS_URL='ws://127.0.0.1:%d' % srv3.port)
    p3 = subprocess.run(['perl', WS_PL, '--check'], env=dict(os.environ, HOME=home3),
                        stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
    o3 = (p3.stdout + p3.stderr).decode('utf-8', 'replace')
    check('凭据正常：--check 退出 0', p3.returncode == 0, o3[-300:])
    check('凭据正常：明确说订阅通过', '成功' in o3, o3[-200:])

    # ---------------- 场景 4：心跳缺失 → 判死重连 ----------------
    conns = {'n': 0}

    def on_hb(srv4, conn, idx):
        conns['n'] = idx
        buf = [srv4.rest]
        op, payload = srv4.read_frame(conn, buf)
        j = json.loads(payload)
        srv4.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'], 'errcode': 0})
        # 故意不回心跳：客户端两次 ping 都没回执后应判死重连
        end = time.time() + 25
        while time.time() < end and conns['n'] < 2:
            try:
                srv4.read_frame(conn, buf)
            except Exception:
                return

    srv4 = WSServer(on_hb)
    srv4.start()
    home4 = os.path.join(tmp, 'home4')
    write_conf(home4, BOT_ID='hb', BOT_SECRET='hb',
               WS_URL='ws://127.0.0.1:%d' % srv4.port, HEARTBEAT=1)
    p4 = subprocess.Popen(['perl', WS_PL, '--serve'],
                          env=dict(os.environ, HOME=home4, GATEWAY_CMD=gw_cmd),
                          stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    reconnected = wait_for(lambda: conns['n'] >= 2, seconds=80)
    p4.kill()
    try:
        p4.wait(5)
    except subprocess.TimeoutExpired:
        pass
    srv4.stop_flag = True
    check('心跳连续缺失 → 判死并重连（服务端看到第二条连接）', bool(reconnected),
          'connections=%s' % conns['n'])
    audit4 = os.path.join(home4, '.claude-agent', 'audit.log')
    a4 = open(audit4, encoding='utf-8').read() if os.path.exists(audit4) else ''
    check('审计里记了 ws_dead 与 ws_reconnect', 'ws_dead' in a4 and 'ws_reconnect' in a4,
          a4[-300:])

    # ---------------- 场景 5：对端突然断开 → 必须判死重连（不许空转） ----------------
    conns5 = {'n': 0}

    def on_close(srv5, conn, idx):
        conns5['n'] = idx
        buf = [srv5.rest]
        op, payload = srv5.read_frame(conn, buf)
        j = json.loads(payload)
        srv5.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'], 'errcode': 0})
        conn.close()                     # 订阅成功后立刻掐断

    srv5 = WSServer(on_close)
    srv5.start()
    home5 = os.path.join(tmp, 'home5')
    write_conf(home5, BOT_ID='c', BOT_SECRET='c',
               WS_URL='ws://127.0.0.1:%d' % srv5.port)
    p5 = subprocess.Popen(['perl', WS_PL, '--serve'],
                          env=dict(os.environ, HOME=home5, GATEWAY_CMD=gw_cmd),
                          stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    again5 = wait_for(lambda: conns5['n'] >= 2, seconds=25)
    p5.kill()
    try:
        p5.wait(5)
    except subprocess.TimeoutExpired:
        pass
    srv5.stop_flag = True
    check('对端突然断开 → 立刻重连（不是空转到心跳才发现）', bool(again5),
          'connections=%s' % conns5['n'])
    a5p = os.path.join(home5, '.claude-agent', 'audit.log')
    a5 = open(a5p, encoding='utf-8').read() if os.path.exists(a5p) else ''
    check('断开原因写进了审计（ws_session_end）', 'ws_session_end' in a5, a5[-200:])

    # ---------------- 场景 6：单实例保护 + 优雅退出 ----------------
    # 两个 --serve 同时跑会把同一条消息各回一遍（钱和文件都可能被操作两次），必须挡住
    home6 = os.path.join(tmp, 'home6')
    os.makedirs(os.path.join(home6, '.claude-agent'), exist_ok=True)
    write_conf(home6, BOT_ID='bot-1', BOT_SECRET='sec-1', WS_URL='ws://127.0.0.1:9',
               REMOTE_MODE='accept-edits')
    env6 = dict(os.environ, HOME=home6)
    pid_path = os.path.join(home6, '.claude-agent', 'wecom-ws.pid')
    first = subprocess.Popen(['perl', WS_PL, '--serve', '--mode=accept-edits'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL, env=env6)
    wait_for(lambda: os.path.exists(pid_path), seconds=20)
    check('启动后写出 pid 文件（GUI/脚本据此显示状态）', os.path.exists(pid_path),
          pid_path)
    pid_txt = open(pid_path, encoding='utf-8').read() if os.path.exists(pid_path) else ''
    check('pid 文件里写的是真 pid', ('pid=%d' % first.pid) in pid_txt, pid_txt[:120])
    check('pid 文件里写了档位（状态同步，不用猜）',
          'mode=accept-edits' in pid_txt, pid_txt[:120])
    check('pid 文件权限 0600',
          os.path.exists(pid_path) and oct(os.stat(pid_path).st_mode & 0o777) == '0o600', '')

    second = subprocess.run(['perl', WS_PL, '--serve'], env=env6,
                            capture_output=True, text=True, timeout=30)
    check('第二个实例被拒绝（退出码 3）', second.returncode == 3, second.returncode)
    check('拒绝时说明已有实例并给出 pid',
          '已经有一个远程服务在跑' in (second.stderr or ''), (second.stderr or '')[-120:])

    first.terminate()
    try:
        first.wait(10)
    except subprocess.TimeoutExpired:
        first.kill()
    wait_for(lambda: not os.path.exists(pid_path), seconds=10)
    check('SIGTERM 后 pid 文件被清理（不留残留）', not os.path.exists(pid_path), '')
    a6p = os.path.join(home6, '.claude-agent', 'audit.log')
    a6 = open(a6p, encoding='utf-8').read() if os.path.exists(a6p) else ''
    check('优雅退出写进审计（ws_stop）', 'ws_stop' in a6, a6[-200:])

    # ---------------- 场景 7：被服务端踢下线 → 不重连 ----------------
    # 官方 SDK 的 disconnected_event 语义：同一机器人在别处建了新连接，
    # 服务端即将断开本连接。此时重连只会再被踢 —— 必须停下并说清原因。
    home7 = os.path.join(tmp, 'home7')
    os.makedirs(os.path.join(home7, '.claude-agent'), exist_ok=True)
    conns7 = {'n': 0}

    def on_client7(srv, conn, idx):
        conns7['n'] += 1
        buf = [srv.rest]
        op, payload = srv.read_frame(conn, buf)
        j = json.loads(payload)
        srv.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'],
                             'errcode': 0})
        # 紧接着推一条「被新连接踢下线」事件
        srv.send_json(conn, {'cmd': 'aibot_event_callback',
                             'headers': {'req_id': 'ev-1'},
                             'body': {'event': {'eventtype': 'disconnected_event'}}})
        srv.pump(conn, buf, {'replies': []}, 3)

    srv7 = WSServer(on_client7)
    srv7.one_shot = False      # 如果客户端错误地重连，会看到 conn_count 增加
    srv7.start()
    write_conf(home7, BOT_ID='bot-7', BOT_SECRET='sec-7',
               WS_URL='ws://127.0.0.1:%d' % srv7.port, HEARTBEAT=30)
    env7 = dict(os.environ, HOME=home7, GATEWAY_CMD=gw_cmd,
                WECOM_WS_BACKOFF_BASE='0.05', WECOM_WS_BACKOFF_MAX='0.1')
    p7 = subprocess.Popen(['perl', WS_PL, '--serve'], env=env7,
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                          stdin=subprocess.DEVNULL)
    try:
        p7.wait(20)
        rc7 = p7.returncode
    except subprocess.TimeoutExpired:
        p7.kill()
        rc7 = None
    err7 = (p7.stderr.read() or b'').decode('utf-8', 'replace')
    time.sleep(1.0)
    srv7.stop_flag = True
    a7p = os.path.join(home7, '.claude-agent', 'audit.log')
    a7 = open(a7p, encoding='utf-8').read() if os.path.exists(a7p) else ''
    check('被新连接踢下线：进程主动退出（退出码 4）', rc7 == 4, rc7)
    check('被踢时写进审计（ws_kicked）', 'ws_kicked' in a7, a7[-200:])
    check('被踢后不再重连（只连了一次）', conns7['n'] == 1, conns7['n'])
    check('被踢原因写给用户看（另一处建立了连接）',
          '别处' in err7 or '新连接' in err7, err7[-160:])
    check('被踢后 pid 文件被清理（不会假装还在跑）',
          not os.path.exists(os.path.join(home7, '.claude-agent', 'wecom-ws.pid')), '')

    # ---------------- 场景 8：连通过一次再断线 → 退避从头算（不是永远 30 秒） ----------------
    home8 = os.path.join(tmp, 'home8')
    os.makedirs(os.path.join(home8, '.claude-agent'), exist_ok=True)
    conns8 = {'n': 0}

    def on_client8(srv, conn, idx):
        conns8['n'] += 1
        buf = [srv.rest]
        op, payload = srv.read_frame(conn, buf)
        j = json.loads(payload)
        srv.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'],
                             'errcode': 0})
        # 第一次：订阅成功后正常挂一会儿再断（模拟网络抖动）
        if conns8['n'] == 1:
            srv.pump(conn, buf, {'replies': []}, 1)
        else:
            srv.pump(conn, buf, {'replies': []}, 1)

    srv8 = WSServer(on_client8)
    srv8.start()
    write_conf(home8, BOT_ID='bot-8', BOT_SECRET='sec-8',
               WS_URL='ws://127.0.0.1:%d' % srv8.port, HEARTBEAT=30)
    env8 = dict(os.environ, HOME=home8, GATEWAY_CMD=gw_cmd,
                WECOM_WS_BACKOFF_BASE='1', WECOM_WS_BACKOFF_MAX='30')
    p8 = subprocess.Popen(['perl', WS_PL, '--serve'], env=env8,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          stdin=subprocess.DEVNULL)
    wait_for(lambda: conns8['n'] >= 2, seconds=30)
    p8.terminate()
    try:
        p8.wait(10)
    except subprocess.TimeoutExpired:
        p8.kill()
    srv8.stop_flag = True
    a8p = os.path.join(home8, '.claude-agent', 'audit.log')
    a8 = open(a8p, encoding='utf-8').read() if os.path.exists(a8p) else ''
    check('连通过再断线：退避回到 1 秒（不是卡在 30 秒）',
          'delay=1s' in a8, [l for l in a8.splitlines() if 'ws_reconnect' in l][-2:])

    # ---------------- 场景 9：凭据错 → 重试 5 次后停（对齐官方 SDK 默认） ----------------
    home9 = os.path.join(tmp, 'home9')
    os.makedirs(os.path.join(home9, '.claude-agent'), exist_ok=True)
    conns9 = {'n': 0}

    def on_client9(srv, conn, idx):
        conns9['n'] += 1
        buf = [srv.rest]
        op, payload = srv.read_frame(conn, buf)
        j = json.loads(payload)
        srv.send_json(conn, {'cmd': 'aibot_subscribe', 'headers': j['headers'],
                             'errcode': 40001, 'errmsg': 'invalid credential'})
        srv.pump(conn, buf, {'replies': []}, 0.3)

    srv9 = WSServer(on_client9)
    srv9.start()
    write_conf(home9, BOT_ID='bad', BOT_SECRET='bad',
               WS_URL='ws://127.0.0.1:%d' % srv9.port, HEARTBEAT=30)
    env9 = dict(os.environ, HOME=home9, GATEWAY_CMD=gw_cmd,
                WECOM_WS_BACKOFF_BASE='0.05', WECOM_WS_BACKOFF_MAX='0.1')
    p9b = subprocess.Popen(['perl', WS_PL, '--serve'], env=env9,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                           stdin=subprocess.DEVNULL)
    try:
        p9b.wait(90)
        rc9 = p9b.returncode
    except subprocess.TimeoutExpired:
        p9b.kill()
        rc9 = None
    err9 = (p9b.stderr.read() or b'').decode('utf-8', 'replace')
    srv9.stop_flag = True
    check('凭据错：连续 5 次订阅被拒才停（与官方 SDK 默认一致）', conns9['n'] == 5, conns9['n'])
    check('凭据错：停下来时退出码非 0', rc9 not in (0, None), rc9)
    check('凭据错：说清原因（订阅被拒 / BotID / Secret）',
          ('订阅被拒' in err9) and ('BotID' in err9 or 'Secret' in err9), err9[-200:])

    shutil.rmtree(tmp, ignore_errors=True)
    return finish()


def finish():
    bad = [r for r in RESULTS if not r[1]]
    print('\n%d/%d 通过' % (len(RESULTS) - len(bad), len(RESULTS)))
    if bad:
        print('失败项：')
        for n, _ in bad:
            print('  · %s' % n)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
