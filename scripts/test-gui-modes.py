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
import io
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

    # GUI 会按 ~/.claude-agent-env 里有没有密钥，分成首次引导画面与主界面。
    # 测试时在临时 HOME 里写入密钥，让它走主界面（引导画面里
    # 分页按钮还没被创建）。
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
    # 不启动后端（这个测试只想看画面部件。
    # 若连启动一起做，视密钥和模型状态会进到确认对话框，
    # 无人值守时就会卡在那里）。
    if cls is not None:
        # 把真货留存下来（[会话] 部分要确认「--continue 是否传给后端」）
        cls._real_start_backend = cls._start_backend
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

        print('[焦点] 打开窗口后输入框必须拿到键盘焦点')
        # 真机报障：GUI 打开了但打不了字 —— 代码里从来没给 write_zone 设过焦点。
        # Xvfb 没有窗口管理器，focus_get() 永远是 None —— 不能直接断言"谁持有
        # 焦点"。改成盯着「有没有真的去给写作框设焦点」这个动作。
        hit = []
        orig_focus = app.write_zone.focus_set
        app.write_zone.focus_set = lambda: (hit.append(1), orig_focus())[1]
        app._set_busy(True)
        app._set_busy(False)
        check(len(hit) >= 1, '解除忙状态后主动把焦点交回写作框（%d 次）' % len(hit))
        app._handle({'t': 'ready', 'provider': 'deepseek', 'model': _default_model(),
                     'mode': 'default', 'writable': [], 'history': 0,
                     'providers': [{'name': 'deepseek', 'has_key': True}],
                     'models': [{'id': _default_model(), 'label': 'DS', 'provider': 'deepseek'}]})
        root.update()
        check(len(hit) >= 2, 'ready 之后也会给一次焦点（%d 次）' % len(hit))
        # 启动直后连 focus_force() 也要做（macOS 上只做 focus_set 会
        # 出现「窗口出来了却敲不进去」）。这里检查
        # 「让窗口本身去取焦点」这一动作。
        forced = []
        orig_force = app.root.focus_force
        app.root.focus_force = lambda: forced.append(1)
        app._focus_write_zone(force=True)
        app.root.focus_force = orig_force
        check(len(forced) >= 1, '启动直后要让整个窗口去取焦点（focus_force）')
        app.write_zone.focus_set = orig_focus

        print('[焦点看护] 焦点抢不到时要说出来，而不是默默打不了字')
        app._focus_ok = False
        orig_get = app.root.focus_get
        app.root.focus_get = lambda: None      # 模拟「焦点根本没落到任何控件」
        app._focus_watchdog(12)                # 12 次仍拿不到 → 应该说话
        app.root.focus_get = orig_get
        root.update()
        check(getattr(app, '_focus_hint_shown', False) and
              '点一下输入框' in str(app.status_var.get()),
              '放弃时明确说「点一下输入框」，不让人干瞪眼',
              str(app.status_var.get()))
        # 看护成功时不许乱说话
        app._focus_ok = True
        app._focus_hint_shown = False
        before = str(app.status_var.get())
        app._focus_watchdog(12)
        root.update()
        check(str(app.status_var.get()) == before and not app._focus_hint_shown,
              '焦点正常时不插多余提示（不制造噪声）')

        print('[按键兜底] 焦点不在输入框时，打的字也不能丢')
        class _Ev(object):
            widget = app.note
            char = '你'
            state = 0
        app._write_show_marker()
        app._on_root_key(_Ev())
        root.update()
        check('你' in app.write_zone.get('1.0', 'end-1c'),
              '焦点在外面时按键被送进输入框（打不了字的兜底）',
              repr(app.write_zone.get('1.0', 'end-1c')))
        # 写在输入框里的时候不能再插一遍（否则每个字都重复）
        class _Ev2(object):
            widget = app.write_zone
            char = '好'
            state = 0
        app._on_root_key(_Ev2())
        check(app.write_zone.get('1.0', 'end-1c').count('好') == 0,
              '已经focus在输入框时不重复插入')

        print('[输入区/输出区] 必须看得出哪块是打的、哪块是记录')
        theme = G.THEMES[app.theme_name]
        note_bg = str(app.note.cget('bg'))
        write_bg = str(app.write_zone.cget('bg'))
        check(write_bg != note_bg,
              '输入框底色与会话底色不同（%s vs %s）' % (write_bg, note_bg))
        sep = getattr(app, 'write_sep', None)
        check(sep is not None and str(sep.cget('bg')) == str(theme['rule']),
              '输入框上方有一条分隔线', None if sep is None else str(sep.cget('bg')))

        print('[后端退出] 必须把原因说出来，不能只把输入框杀掉')
        # 真机报障：GUI 打开后输入框打不了字 —— 实际是后端进程已经退出，
        # 而 bye 分支只做了 _set_busy(True)，stderr 又被 DEVNULL 丢掉。
        app._stderr_tail = ['请设置 ANTHROPIC_API_KEY']
        app._handle({'t': 'bye'})
        root.update()
        body = app.note.get('1.0', 'end-1c')
        check('后端进程已退出' in body, '退出时明确说「后端进程已退出」', body[-160:])
        check('请设置 ANTHROPIC_API_KEY' in body,
              '把后端 stderr 的最后几行也显示出来', body[-160:])
        check(('advisor' in body) and ('重开' in body or '终端' in body),
              '给出处理办法（关掉重开 / 终端跑 advisor）', body[-160:])
        check(str(app.write_zone.cget('state')) in ('disabled', 1),
              '没有后端时输入框保持禁用（不假装能发）', app.write_zone.cget('state'))
        app._handle({'t': 'ready', 'provider': 'deepseek', 'model': _default_model(),
                     'mode': 'default', 'writable': [], 'history': 0,
                     'providers': [{'name': 'deepseek', 'has_key': True}],
                     'models': [{'id': _default_model(), 'label': 'DS', 'provider': 'deepseek'}]})
        root.update()
        check(str(app.write_zone.cget('state')) in ('normal', 0),
              '后端 ready 后输入框恢复可用', app.write_zone.cget('state'))

        print('[会话] 会话菜单：接续/起名/搜索的入口都在')
        sm = getattr(app, 'session_menu', None)
        check(sm is not None, '存在「会话」菜单')
        labels = []
        if sm is not None:
            last = sm.index('end')
            if last is not None:
                for i in range(last + 1):
                    try:
                        labels.append(sm.entrycget(i, 'label'))
                    except Exception:
                        pass
        check(len(labels) == 5, '五个入口（%s）' % labels)
        check(any('接着上次' in x for x in labels), '有「接着上次」')
        check(any('指定的对话' in x for x in labels), '有「接着指定的对话」')
        check(any('列出现有对话' in x for x in labels), '有「列出现有对话」')
        check(any('起名' in x for x in labels), '有「起名」')
        check(any('搜索' in x for x in labels), '有「搜索」')

        print('[会话] 接续＝重启后端并带上 --continue（不是假装切换）')
        recorded = {}

        class _FakePopen(object):
            def __init__(self, cmd, **kw):
                recorded['cmd'] = list(cmd)
                self.stdout = io.StringIO('')
                self.stderr = io.StringIO('')
                self.stdin = io.StringIO('')
                self.returncode = None

            def poll(self):
                return None

            def terminate(self):
                pass

            def wait(self, timeout=None):
                return 0

            def kill(self):
                pass

        real_popen = G.subprocess.Popen
        real_build = G.build_backend_command_and_env
        try:
            G.build_backend_command_and_env = lambda: (['perl', 'agent.pl'], {})
            G.subprocess.Popen = _FakePopen
            app._start_backend = lambda: G.AdvisorGUI._real_start_backend(app)
            app._session_restart(['--continue=我的实验'], G.L('session_continue_note'))
            app._start_backend = lambda: None
            root.update()
            cmd = recorded.get('cmd') or []
            check('--continue=我的实验' in cmd, '重启时把 --continue 传给了后端（%s）' % cmd)
            check(app._extra_args == ['--continue=我的实验'], '参数记在了 _extra_args 里')
        finally:
            G.subprocess.Popen = real_popen
            G.build_backend_command_and_env = real_build

        print('[会话] 起名/搜索走普通一轮输入（不给后端加协议）')
        sent = []
        app._write = lambda obj: sent.append(obj)
        app._append = lambda *a, **k: None      # 画面输出与本次断言无关
        app._set_busy = lambda *a, **k: None
        try:
            app.status_var.set('')
        except Exception:
            pass
        app.proc = recorded_cmd_ok = type('P', (), {'poll': lambda self: None})()
        app._session_cmd('/name 我的实验')
        check(bool(sent) and sent[-1].get('text') == '/name 我的实验',
              '起名命令被当作一轮输入发出（%s）' % (sent[-1] if sent else None))

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
