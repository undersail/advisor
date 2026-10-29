#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GUI「远程接入」面板的测试（窗口内省，需要 Xvfb）。

验的是三件事，恰好也是用户最担心的三件事：

  1. GUI 写的是**命令行那同一个文件**（~/.claude-agent/wecom-ws.conf、remote.conf），
     而且重启后能读回来（remote_status() 立刻反映），不需要重填
  2. 只改自己负责的那几个键 —— NOTIFY / LANG / HIST_PASS 等别人的配置必须原样保留
  3. Secret 用掩码输入、保存后清空、写失败必须报错（不许静默）

跑法：xvfb-run -a python3 scripts/test-gui-remote.py
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import types

RESULTS = []
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GUI = os.path.join(ROOT, 'gui', 'advisor_gui.py')


def check(name, ok, detail=''):
    RESULTS.append((name, bool(ok)))
    print(('  ok   ' if ok else '  FAIL ') + name)
    if not ok and detail != '':
        print('       细节: %s' % str(detail)[:400])
        print('::error::%s | 细节: %s' % (name, str(detail)[:400]))


def load_gui(home):
    """HOME 必须在 import 前设好：模块顶层就用 expanduser 定死了配置路径。"""
    os.environ['HOME'] = home
    spec = importlib.util.spec_from_file_location('advisor_gui_t', GUI)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def widgets(root):
    out = []
    stack = [root]
    while stack:
        w = stack.pop()
        out.append(w)
        try:
            stack.extend(w.winfo_children())
        except Exception:
            pass
    return out


def find_dialog(root, title):
    for w in widgets(root):
        if w.winfo_class() == 'Toplevel':
            try:
                if w.title() == title:
                    return w
            except Exception:
                pass
    return None


def find_button(dlg, text):
    for w in widgets(dlg):
        if w.winfo_class() == 'Button':
            try:
                if w.cget('text') == text:
                    return w
            except Exception:
                pass
    return None


def find_entries(dlg):
    return [w for w in widgets(dlg) if w.winfo_class() == 'Entry']


def find_label_texts(dlg):
    out = []
    for w in widgets(dlg):
        if w.winfo_class() == 'Label':
            try:
                out.append(w.cget('text'))
            except Exception:
                pass
    return out


def main():
    # 宿主环境不该让测试红：没 tkinter（干净的 CI venv 常见）就跳过，且**明确说出原因**，
    # 不许静默通过 —— 与 test-gui-modes.py 的处理保持一致。
    try:
        import tkinter as tk
    except Exception as e:
        print('跳过：没有 tkinter（%s）。这个测试验的是窗口内省，没有 Tk 就无从验起。' % e)
        print('::notice::test-gui-remote 跳过：缺少 tkinter')
        return 0

    tmp = tempfile.mkdtemp(prefix='guiremote-')
    home = os.path.join(tmp, 'home')
    agent_dir = os.path.join(home, '.claude-agent')
    os.makedirs(agent_dir, exist_ok=True)
    gui = load_gui(home)

    conf_path = gui.WECOM_WS_CONF_PATH
    remote_path = gui.REMOTE_CONF_PATH
    check('配置文件就是命令行那一个（wecom-ws.conf）',
          conf_path == os.path.join(agent_dir, 'wecom-ws.conf'), conf_path)
    check('白名单文件就是网关那一个（remote.conf）',
          remote_path == os.path.join(agent_dir, 'remote.conf'), remote_path)
    check('能找到 remote/wecom-ws.pl', bool(gui.find_wecom_ws_script()),
          gui.find_wecom_ws_script())

    # 预置「用户自己的」其它配置：GUI 不许把它们弄丢
    with open(remote_path, 'w', encoding='utf-8') as f:
        f.write('# 用户自己写的\nNOTIFY=1\nLANG=zh\nALLOW=olduser\nHIST_PASS=keepme\n')
    with open(conf_path, 'w', encoding='utf-8') as f:
        f.write('# 已有配置\nWS_URL=wss://example.invalid\nHEARTBEAT=20\n')
    os.chmod(conf_path, 0o600)

    check('只有 WS_URL、没有凭据时，状态是「未配置」',
          gui.remote_status()['configured'] is False, gui.remote_status())

    # ---------------- 打开面板（真窗口） ----------------
    root = tk.Tk()
    root.withdraw()
    dummy = types.SimpleNamespace(root=root)
    gui.AdvisorGUI._open_remote_dialog(dummy)
    root.update()
    dlg = find_dialog(root, gui.L('remote_title'))
    check('菜单能打开远程接入面板', dlg is not None, [w.winfo_class() for w in widgets(root)][:10])
    if dlg is None:
        root.destroy()
        shutil.rmtree(tmp, ignore_errors=True)
        return finish()

    entries = find_entries(dlg)
    check('面板有三个输入框（BotID / Secret / 白名单）', len(entries) >= 3, len(entries))
    # 按 grid 行号定位，别依赖遍历顺序（遍历顺序跟网格布局无关）
    by_row = {}
    for e in entries:
        try:
            gi = e.grid_info()
        except Exception:
            gi = {}
        if gi:
            by_row[int(gi.get('row', -1))] = e
    bot_ent, sec_ent, allow_e = by_row.get(0), by_row.get(1), by_row.get(2)
    check('三个输入框都在（按行定位）', all(x is not None for x in (bot_ent, sec_ent, allow_e)),
          sorted(by_row))
    if bot_ent is None or sec_ent is None:
        root.destroy(); shutil.rmtree(tmp, ignore_errors=True); return finish()
    masked = [sec_ent]
    check('Secret 是掩码输入（不回显）', str(sec_ent.cget('show')) not in ('', 'None'),
          str(sec_ent.cget('show')))
    check('白名单从 remote.conf 读出来（不是空白）',
          allow_e is not None and allow_e.get() == 'olduser',
          allow_e.get() if allow_e is not None else None)

    combos = [w for w in widgets(dlg) if w.winfo_class() == 'TCombobox']
    mode_box = combos[0] if combos else None
    check('面板有「远程权限」下拉（手机端改不了，本机才有入口）',
          mode_box is not None, [w.winfo_class() for w in widgets(dlg)][:12])
    check('没有配过时默认显示「只读」',
          mode_box is not None and mode_box.get() == gui.L('remote_readonly_label'),
          mode_box.get() if mode_box else None)
    roots_ent = by_row.get(4)
    check('面板有「可写目录」输入框', roots_ent is not None, sorted(by_row))

    save_btn = find_button(dlg, gui.L('remote_save'))
    check('面板有「保存」按钮', save_btn is not None)

    # 1) BotID 空 → 提示且不写文件
    before = open(conf_path, encoding='utf-8').read()
    if save_btn:
        save_btn.invoke()
        root.update()
    check('BotID 为空时不保存，并给出提示',
          open(conf_path, encoding='utf-8').read() == before
          and any('BotID' in t for t in find_label_texts(dlg)),
          find_label_texts(dlg)[-3:])

    # 2) 有 BotID 没 Secret（首次）→ 提示要 Secret
    bot_ent.delete(0, 'end')
    bot_ent.insert(0, 'bot-abc')
    if save_btn:
        save_btn.invoke()
        root.update()
    check('首次保存缺 Secret 时不写文件并提示',
          open(conf_path, encoding='utf-8').read() == before,
          open(conf_path, encoding='utf-8').read()[:120])

    # 3) 正常保存
    masked[0].delete(0, 'end')
    masked[0].insert(0, 'sec-xxx')
    if save_btn:
        save_btn.invoke()
        root.update()
    conf = gui.read_kv_conf(conf_path)
    check('保存后 BotID 落盘', conf.get('BOT_ID') == 'bot-abc', conf)
    check('保存后 Secret 落盘', conf.get('BOT_SECRET') == 'sec-xxx', conf)
    check('保存后文件权限 0600', oct(os.stat(conf_path).st_mode & 0o777) == '0o600',
          oct(os.stat(conf_path).st_mode & 0o777))
    check('保存后 Secret 输入框被清空（旧值不回填）', masked[0].get() == '',
          masked[0].get())
    check('保存后状态立刻变成「已配置」（等价于重启后能读回）',
          gui.remote_status()['configured'] is True, gui.remote_status())

    # 4) 不覆盖别人的键
    check('write 没弄丢已有的 WS_URL / HEARTBEAT（只改自己那几个键）',
          conf.get('WS_URL') == 'wss://example.invalid' and conf.get('HEARTBEAT') == '20',
          conf)
    rconf = gui.read_kv_conf(remote_path)
    check('remote.conf 的 NOTIFY / LANG / HIST_PASS 原样保留',
          rconf.get('NOTIFY') == '1' and rconf.get('LANG') == 'zh'
          and rconf.get('HIST_PASS') == 'keepme', rconf)

    # 5) 白名单写入（并保留其它键）
    if allow_e is not None:
        allow_e.delete(0, 'end')
        allow_e.insert(0, 'zhangsan,lisi')
    if save_btn:
        save_btn.invoke()
        root.update()
    rconf = gui.read_kv_conf(remote_path)
    check('白名单写进 remote.conf 的 ALLOW',
          rconf.get('ALLOW') == 'zhangsan,lisi', rconf)
    check('写白名单时仍然没弄丢 NOTIFY / HIST_PASS',
          rconf.get('NOTIFY') == '1' and rconf.get('HIST_PASS') == 'keepme', rconf)

    # 6) 状态里的「最近活动」来自 audit.log，不是自己造的
    with open(gui.AUDIT_LOG_PATH, 'a', encoding='utf-8') as f:
        f.write('2026-10-29 08:15:00 ws ws_subscribe_ok url=wss://x\n')
    st = gui.remote_status()
    check('最近活动时间读自 audit.log', '2026-10-29 08:15:00' in st['last_activity'],
          st)

    # 7) 测试连接：真实调用 --check，失败要把真话显示出来
    test_btn = find_button(dlg, gui.L('remote_test'))
    check('面板有「测试连接」按钮', test_btn is not None)
    if test_btn:
        os.environ['WS_URL'] = ''
        gui.write_kv_conf_atomic(conf_path, {'WS_URL': 'ws://127.0.0.1:9'})
        test_btn.invoke()
        import time
        deadline = time.time() + 40
        texts = ''
        while time.time() < deadline:
            root.update()
            texts = '\n'.join(find_label_texts(dlg))
            if 'NG' in texts or 'OK' in texts:
                break
            time.sleep(0.2)
        check('测试连接失败时显示 NG + 真实原因（不是假成功）',
              'NG' in texts, texts[-200:])

    # ---------------- 远程权限档位与可写目录 ----------------
    if mode_box is not None and roots_ent is not None:
        before_mode = open(conf_path, encoding='utf-8').read()
        mode_box.set(gui.L('remote_readonly_label'))
        roots_ent.delete(0, tk.END)
        roots_ent.insert(0, '/tmp/should-not-save')
        if save_btn:
            save_btn.invoke()
            root.update()
        texts = '\n'.join(find_label_texts(dlg))
        check('只读档配可写目录：拒绝保存并说明原因',
              open(conf_path, encoding='utf-8').read() == before_mode
              and gui.L('remote_need_mode') in texts,
              texts[-160:])

        mode_box.set(gui.L('remote_accept_label'))
        roots_ent.delete(0, tk.END)
        roots_ent.insert(0, '/tmp/a, /tmp/b')
        if save_btn:
            save_btn.invoke()
            root.update()
        written = open(conf_path, encoding='utf-8').read()
        check('选「可编辑」后把档位写进同一份配置（REMOTE_MODE）',
              'REMOTE_MODE=accept-edits' in written, written[-200:])
        check('可写目录写进去时去了空格（REMOTE_ALLOW_WRITE）',
              'REMOTE_ALLOW_WRITE=/tmp/a,/tmp/b' in written, written[-200:])
        check('写档位时没弄丢原来的 WS_URL / HEARTBEAT',
              'WS_URL=' in written and 'HEARTBEAT=20' in written, written[-200:])

        # 重新打开面板 = 模拟重启程序：必须读回刚才选的档位，不用重填
        for w in list(root.winfo_children()):
            try:
                w.destroy()
            except Exception:
                pass
        root.update()
        gui.AdvisorGUI._open_remote_dialog(dummy)
        root.update()
        dlg2 = find_dialog(root, gui.L('remote_title'))
        boxes2 = [w for w in widgets(dlg2) if w.winfo_class() == 'TCombobox'] if dlg2 else []
        rows2 = {}
        for e in (find_entries(dlg2) if dlg2 else []):
            try:
                rows2[int(e.grid_info().get('row', -1))] = e
            except Exception:
                pass
        check('重启后面板读回档位「可编辑」（不用重填）',
              bool(boxes2) and boxes2[0].get() == gui.L('remote_accept_label'),
              boxes2[0].get() if boxes2 else None)
        check('重启后读回可写目录',
              rows2.get(4) is not None and rows2[4].get() == '/tmp/a,/tmp/b',
              rows2.get(4).get() if rows2.get(4) is not None else None)
        check('重启后 Secret 仍是留空（旧值绝不回填）',
              rows2.get(1) is not None and rows2[1].get() == '',
              rows2[1].get() if rows2.get(1) is not None else None)
        if dlg2 is not None:
            dlg2.destroy()
            root.update()

    # ---------------- 后台服务：状态显示 + 启动/停止 ----------------
    import time as _t
    # 上面那轮已经把面板关掉重开过一次，这里再开一个干净的来验服务启停
    for w in list(root.winfo_children()):
        try:
            w.destroy()
        except Exception:
            pass
    root.update()
    gui.AdvisorGUI._open_remote_dialog(dummy)
    root.update()
    dlg = find_dialog(root, gui.L('remote_title'))
    if dlg is None:
        root.destroy(); shutil.rmtree(tmp, ignore_errors=True); return finish()
    check('面板有「启动服务」按钮', find_button(dlg, gui.L('remote_start')) is not None)
    check('面板有「停止服务」按钮', find_button(dlg, gui.L('remote_stop')) is not None)
    st0 = gui.remote_service_status()
    check('没启动时状态是「没在跑」', st0['running'] is False, st0)

    start_btn = find_button(dlg, gui.L('remote_start'))
    stop_btn2 = find_button(dlg, gui.L('remote_stop'))
    if start_btn is not None:
        start_btn.invoke()
        for _ in range(40):
            root.update()
            if gui.remote_service_status()['running']:
                break
            _t.sleep(0.2)
        st1 = gui.remote_service_status()
        check('点「启动服务」后真的起来了（pid 文件 + 进程活着）', st1['running'] is True, st1)
        check('状态里读得到档位（跟配置一致，不靠猜）',
              st1['mode'] in ('accept-edits', 'default'), st1)
        texts = '\n'.join(find_label_texts(dlg))
        check('面板上写明了运行中', 'pid' in texts.lower() or str(st1['pid']) in texts,
              texts[-160:])
        check('启动的就是命令行那个服务（同一个 pid 文件路径）',
              gui.WECOM_WS_PID_PATH == os.path.join(agent_dir, 'wecom-ws.pid'),
              gui.WECOM_WS_PID_PATH)

        if stop_btn2 is not None:
            stop_btn2.invoke()
            for _ in range(40):
                root.update()
                if not gui.remote_service_status()['running']:
                    break
                _t.sleep(0.2)
            check('点「停止服务」后真的停了', gui.remote_service_status()['running'] is False,
                  gui.remote_service_status())
            check('停止后 pid 文件被清理（不留残留）',
                  not os.path.exists(gui.WECOM_WS_PID_PATH))
            a = os.path.join(agent_dir, 'audit.log')
            at = open(a, encoding='utf-8').read() if os.path.exists(a) else ''
            check('停止走了优雅退出（审计里有 ws_stop）', 'ws_stop' in at, at[-160:])

    try:
        dlg.destroy()
    except Exception:
        pass
    root.destroy()
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
