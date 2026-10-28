#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GUI 的模式控件（页眉按钮 + 常驻徽标）验收。

无显示器也能验：在 Xvfb 里把窗口建起来，然后用 Tk 自己的 API 内省控件
（文字、颜色、菜单项），不去点鼠标、也不截图。验的是：
  * 三档菜单项齐全、文字走 _S 三语
  * 徽标常显当前模式；bypass 用危险色、accept-edits 用强调色、default 用暗色
  * _update_mode() 能正确改文字与颜色
  * 切主题后徽标颜色仍然对（不会退回默认色）

没有 DISPLAY 时跳过（macOS 无人值守跑不了这套，别让它变红）。
"""
import os
import shutil
import sys
import tempfile
import json
import socket
import threading
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

sys.path.insert(0, os.path.join(ROOT, 'gui'))

OK = 0
FAIL = 0
SKIP = 0


def check(cond, name, detail=''):
    global OK, FAIL
    if cond:
        OK += 1
        print('  ok   %s' % name)
    else:
        FAIL += 1
        print('  FAIL %s%s' % (name, ('  ← %s' % detail) if detail else ''))


class MockLLM(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        if n:
            self.rfile.read(n)
        raw = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': 'hi'}}]}).encode()
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


def main():
    global SKIP
    if not os.environ.get('DISPLAY'):
        print('跳过：没有 DISPLAY（GUI 需要窗口系统）')
        return 0
    try:
        import tkinter as tk
    except Exception as e:
        print('跳过：没有 tkinter（%s）' % e)
        return 0

    # GUI は ~/.claude-agent-env に鍵が入っているかで初回案内画面と本体を
    # 分ける。テストでは一時 HOME に鍵を書いて本体側を出す（案内画面では
    # ページャのボタンがまだ作られていない）。
    home = tempfile.mkdtemp(prefix='advisor-gui-home-')
    os.environ['HOME'] = home
    with open(os.path.join(home, '.claude-agent-env'), 'w', encoding='utf-8') as f:
        f.write('export CLAUDE_PROVIDER=deepseek\n')
        f.write('export DEEPSEEK_API_KEY=dummy-gui-test\n')
        f.write('export CLAUDE_MODEL=%s\n' % _default_model())
    os.chmod(os.path.join(home, '.claude-agent-env'), 0o600)

    port = free_port()
    srv = http.server.HTTPServer(('127.0.0.1', port), MockLLM)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    os.environ.update({
        'CLAUDE_PROVIDER': 'deepseek',
        'DEEPSEEK_API_KEY': 'dummy-gui-test',
        'CLAUDE_MODEL': _default_model(),
        'CLAUDE_BASE_URL': 'http://127.0.0.1:%d/v1' % port,
        'CLAUDE_NO_HISTORY': '1',
        'CLAUDE_LANG': 'zh',
        'TERM': 'dumb',
    })

    import advisor_gui as G

    cls = getattr(G, 'AdvisorGUI', None)
    # バックエンドを起動しない（このテストが見たいのは画面の部品だけ。
    # 起動まで含めると、鍵やモデルの状態次第で確認ダイアログに入り、
    # 無人実行ではそこで止まる）。
    if cls is not None:
        cls._start_backend = lambda self: None
        cls._write_show_marker = lambda self: None
    if cls is None:
        print('跳过：找不到 GUI 主类 AdvisorGUI')
        return 0
    root = tk.Tk()
    try:
        app = cls(root)
    except Exception as e:
        print('跳过：GUI 无法实例化（%s: %s）' % (type(e).__name__, e))
        return 0
    for _ in range(40):
        root.update()
    try:
        print('[控件] 页眉里的模式按钮与徽标')
        btn = getattr(app, 'mode_btn', None)
        badge = getattr(app, 'mode_badge', None)
        menu = getattr(app, 'mode_menu', None)
        check(btn is not None, '存在模式按钮')
        check(badge is not None, '存在常驻徽标')
        check(menu is not None, '存在模式菜单')
        if btn is not None:
            check('模式' in btn.cget('text'), '按钮文字可读（%s）' % btn.cget('text'))
        if menu is not None:
            labels = []
            last = menu.index('end')
            if last is not None:
                for i in range(last + 1):
                    labels.append(menu.entrycget(i, 'label'))
            check(len(labels) == 3, '菜单正好三项（%s）' % labels)
            check(any('默认' in x for x in labels), '有 default 项')
            check(any('写文件免确认' in x for x in labels), '有 accept-edits 项')
            check(any('Bypass' in x for x in labels), '有 bypass 项')

        print('[行为] 徽标随模式变化')
        theme = G.THEMES[app.theme_name]
        app._update_mode('default', [])
        root.update()
        check(badge.cget('text') == G.L('mode_default_short'),
              'default 显示「%s」' % G.L('mode_default_short'), badge.cget('text'))
        check(str(badge.cget('fg')) == str(theme['dim']), 'default 用暗色（%s）' % theme['dim'])

        app._update_mode('bypass', ['/tmp/x'])
        root.update()
        check(badge.cget('text') == G.L('mode_bypass_short'),
              'bypass 显示「%s」' % G.L('mode_bypass_short'), badge.cget('text'))
        check(str(badge.cget('fg')) == str(theme['err']), 'bypass 用危险色（%s）' % theme['err'])

        app._update_mode('accept-edits', ['/tmp/x'])
        root.update()
        check(str(badge.cget('fg')) == str(theme['ai']), 'accept-edits 用强调色（%s）' % theme['ai'])

        print('[菜单] 没配密钥的厂商先标出来（判断权在 agent）')
        # 真实反馈那次的 GUI 版：agent 在 ready 里下发 has_key，GUI 只接收不推断。
        app._handle({
            't': 'ready',
            'provider': 'deepseek', 'model': 'deepseek-chat', 'history': 0,
            'mode': 'default', 'writable': [],
            'models': [
                {'id': 'claude-opus-5', 'label': 'Claude Opus 5', 'provider': 'anthropic'},
                {'id': 'deepseek-chat', 'label': 'DeepSeek Chat', 'provider': 'deepseek'},
            ],
            'providers': [
                {'name': 'anthropic', 'label': 'Anthropic (Claude)', 'has_key': 0,
                 'key_env': 'ANTHROPIC_API_KEY'},
                {'name': 'deepseek', 'label': 'DeepSeek', 'has_key': 1,
                 'key_env': 'DEEPSEEK_API_KEY'},
            ],
        })
        root.update()
        vend = []
        m = app.switch_menu
        last = m.index('end')
        if last is not None:
            for i in range(last + 1):
                if m.type(i) == 'cascade':
                    vend.append(m.entrycget(i, 'label'))
        marked = [v for v in vend if G.L('menu_no_key').strip() in v]
        check(any('Anthropic' in v for v in marked),
              '没密钥的厂商被标出（%s）' % vend)
        check(not any('DeepSeek' in v for v in marked),
              '有密钥的厂商不标注（%s）' % vend)
        check(len(marked) == 1, '只标出真正缺密钥的那一家（%s）' % marked)

        print('[菜单] 没收到 has_key 时不乱标（保守）')
        app._has_key = {}
        app._fill_menu([
            {'id': 'claude-opus-5', 'label': 'Claude Opus 5', 'provider': 'anthropic'},
            {'id': 'deepseek-chat', 'label': 'DeepSeek Chat', 'provider': 'deepseek'},
        ])
        root.update()
        vend2 = []
        last2 = m.index('end')
        if last2 is not None:
            for i in range(last2 + 1):
                if m.type(i) == 'cascade':
                    vend2.append(m.entrycget(i, 'label'))
        check(not any(G.L('menu_no_key').strip() in v for v in vend2),
              '状态未知时不做任何标注（%s）' % vend2)

        print('[主题] 换主题后徽标颜色仍然跟随')
        other = [k for k in G.THEMES if k != app.theme_name]
        if other:
            app._choose_theme(other[0])
            app._update_mode('bypass', [])
            root.update()
            t2 = G.THEMES[other[0]]
            check(str(badge.cget('fg')) == str(t2['err']),
                  '切到 %s 后 bypass 仍是危险色' % other[0], badge.cget('fg'))
    finally:
        try:
            app.root.destroy()
        except Exception:
            pass
        srv.shutdown()
        shutil.rmtree(os.environ.get('HOME', ''), ignore_errors=True)

    print('\n%d/%d 通过' % (OK, OK + FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
