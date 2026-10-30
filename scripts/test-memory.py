#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""长期记忆（~/.claude-agent/memory.md）的端到端测试。

验四件事：
  ① 写：/remember 与 remember 工具都能写，且 **remember 工具必须问人**
  ② 读：内容真的进了 system prompt（不是只写进文件）
  ③ 上限：注入有截断并说明；到上限后 /remember 拒绝并给修法
  ④ 边界：受限会话（远程那种 --no-config）里 /memory /remember 一律被拒

不依赖真 key：端点是自己起的假服务，请求体里能拿到 system prompt。
"""
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_harness as H

SCRIPT = H.Script()


def tool_results(script):
    """最近一次请求里，回给模型的 tool 结果（界面事件里看不到这些）。"""
    if not script.requests:
        return ''
    try:
        req = json.loads(script.requests[-1])
    except ValueError:
        return ''
    out = []
    for m in req.get('messages') or []:
        if m.get('role') == 'tool':
            out.append(str(m.get('content')))
            continue
        c = m.get('content')
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get('type') == 'tool_result':
                    out.append(str(b.get('content')))
    return '\n'.join(out)


def sys_prompt_after(agent, text='随便说一句'):
    """跑一轮，返回这次请求里模型看到的 system prompt。"""
    before = len(SCRIPT.requests)
    agent.turn(text)
    bodies = SCRIPT.requests[before:]
    if not bodies:
        return ''
    return H.system_prompt_of(bodies[0])


def main():
    if not os.path.exists(H.AGENT):
        H.check(False, 'agent 存在', H.AGENT)
        return H.finish('memory')

    work = tempfile.mkdtemp(prefix='memory-')
    srv, base = H.make_server(SCRIPT)
    try:
        home = os.path.join(work, 'home')
        os.makedirs(home)
        memfile = os.path.join(home, '.claude-agent', 'memory.md')
        env = {'CLAUDE_MEMORY_FILE': memfile}

        # ---- A) 没有文件时：不注入、也不崩
        a = H.Agent(home, base, extra_env=env)
        H.check(a.hello is not None, '没有记忆文件时 agent 正常握手')
        sp = sys_prompt_after(a)
        H.check('Long-term memory about this user' not in sp,
                '没有记忆文件时不注入记忆段落', sp[:200])
        a.stop()

        # ---- B) /remember 写入文件（0600），并出现在 system prompt 里
        a = H.Agent(home, base, extra_env=env)
        ev = a.turn('/remember 用户偏好中文回答，讨厌啰嗦')
        txt = H.texts(ev)
        H.check('已记住' in txt, '/remember 回一句「已记住」', txt[:160])
        H.check(os.path.exists(memfile), '/remember 真的建了文件', memfile)
        body = open(memfile, encoding='utf-8').read() if os.path.exists(memfile) else ''
        H.check('用户偏好中文回答' in body, '文件里有那条事实', body[:160])
        mode = oct(os.stat(memfile).st_mode & 0o777) if os.path.exists(memfile) else ''
        H.check(mode == '0o600', '记忆文件权限是 0600', mode)
        a.stop()

        # ---- C) 新会话启动后，记忆进了 system prompt
        a = H.Agent(home, base, extra_env=env)
        sp = sys_prompt_after(a)
        H.check('用户偏好中文回答' in sp, '记忆内容进了 system prompt（真注入，不只是写文件）',
                sp[-300:])
        H.check('当前对话优先' in sp or 'CURRENT conversation always wins' in sp,
                '注入里说明了「当前会话优先于记忆」', sp[-400:])
        a.stop()

        # ---- D) /memory 能看；/memory rm 能删；越界报错
        a = H.Agent(home, base, extra_env=env)
        ev = a.turn('/memory')
        txt = H.texts(ev)
        H.check('长期记忆' in txt and memfile in txt, '/memory 显示路径与标题', txt[:200])
        H.check('1.' in txt, '/memory 带行号', txt[:200])

        ev = a.turn('/remember 第二条事实：机器是 2011 年的 MacBook')
        H.check('已记住' in H.texts(ev), '再记一条')
        ev = a.turn('/memory rm 1')
        H.check('已删除第 1 行' in H.texts(ev), '/memory rm 1 删掉第一行', H.texts(ev)[:200])
        body = open(memfile, encoding='utf-8').read()
        H.check('用户偏好中文回答' not in body, '第一行的内容真的没了', body[:160])
        H.check('2011' in body, '第二行还在', body[:160])
        ev = a.turn('/memory rm 99')
        H.check('没有第 99 行' in H.texts(ev), '越界删除报错而不是静默', H.texts(ev)[:200])

        # ---- E) /memory clear 要人确认：回 n 不清，回 y 清
        before = open(memfile, encoding='utf-8').read()
        ev = a.turn('/memory clear', answer='n')
        H.check(len(H.confirms(ev)) >= 1, '/memory clear 先问一遍', str(ev)[:300])
        H.check(open(memfile, encoding='utf-8').read() == before, '回 n 时记忆不变')
        ev = a.turn('/memory clear', answer='y')
        H.check(open(memfile, encoding='utf-8').read().strip() == '', '回 y 时清空', 
                open(memfile, encoding='utf-8').read()[:120])
        H.check('已清空' in H.texts(ev), '清空后有一句确认', H.texts(ev)[:200])
        a.stop()

        # ---- F) 注入上限：超长文件只送前面一段，并说明截断
        os.makedirs(os.path.dirname(memfile), exist_ok=True)
        head = '开头标记\n'
        filler = ('这是一段用来占位的中文内容，不要超过两千字符。' * 200)   # 明显超过 2000 字符上限
        open(memfile, 'w', encoding='utf-8').write(head + filler + '\n结尾标记\n')
        a = H.Agent(home, base, extra_env=env)
        sp = sys_prompt_after(a)
        H.check('开头标记' in sp, '超长记忆：开头仍然注入', sp[-300:])
        H.check('结尾标记' not in sp, '超长记忆：结尾被截掉（没有整篇塞进 prompt）')
        H.check('only the first' in sp or '只送' in sp,
                '超长记忆：注入里说明了被截断', sp[-400:])
        a.stop()

        # ---- G) 到上限后 /remember 拒绝，并给出去改哪
        a = H.Agent(home, base, extra_env=env)
        ev = a.turn('/remember 这条应该写不进去')
        txt = H.texts(ev)
        H.check('上限' in txt, '到上限后 /remember 拒绝并说明原因', txt[:240])
        H.check(memfile in txt, '拒绝时给出去改哪个文件', txt[:240])
        a.stop()

        # ---- H) remember 工具：必须问人；回 n 不写，回 y 才写
        open(memfile, 'w', encoding='utf-8').write('')
        a = H.Agent(home, base, extra_env=env)
        SCRIPT.push_tool('remember', {'fact': '模型想记住：用户叫小明'})
        ev = a.turn('记住一下我的名字', answer='n')
        conf = H.confirms(ev)
        H.check(len(conf) >= 1, 'remember 工具先问人（RPC 里有 confirm 事件）', str(ev)[:400])
        H.check(any('小明' in (c.get('prompt') or '') for c in conf),
                '确认里带着要记住的内容（用户知道自己在批什么）', str(conf)[:300])
        H.check(open(memfile, encoding='utf-8').read().strip() == '', '回 n 时不写盘',
                open(memfile, encoding='utf-8').read()[:120])
        H.check('没有写进' in tool_results(SCRIPT), '回 n 时告诉模型没写（tool_result 里）',
                tool_results(SCRIPT)[:200])
        a.stop()

        a = H.Agent(home, base, extra_env=env)
        SCRIPT.push_tool('remember', {'fact': '模型想记住：用户叫小明'})
        ev = a.turn('记住一下我的名字', answer='y')
        body = open(memfile, encoding='utf-8').read()
        H.check('小明' in body, '回 y 时写进记忆', body[:160])
        a.stop()

        # ---- I) bypass 模式下 remember 仍然要确认（记忆写错会一直影响后续）
        open(memfile, 'w', encoding='utf-8').write('')
        a = H.Agent(home, base, mode='bypass', extra_env=env)
        SCRIPT.push_tool('remember', {'fact': 'bypass 里也要问'})
        ev = a.turn('记一下', answer='n')
        H.check(len(H.confirms(ev)) >= 1, 'bypass 模式下 remember 仍然确认', str(ev)[:300])
        H.check(open(memfile, encoding='utf-8').read().strip() == '',
                'bypass + 回 n：没写盘', open(memfile, encoding='utf-8').read()[:120])
        a.stop()

        # ---- J) 受限会话（远程用 --no-config）：记忆类命令一律被拒
        a = H.Agent(home, base, extra_env=env, no_config=True)
        ev = a.turn('/memory')
        txt = H.texts(ev)
        H.check('不能修改配置' in txt or 'config' in txt.lower(),
                '受限会话里 /memory 被拒（记忆是私事，不该经聊天平台）', txt[:200])
        ev = a.turn('/remember 偷偷记一条')
        H.check('偷偷记一条' not in open(memfile, encoding='utf-8').read(),
                '受限会话里 /remember 写不进去', open(memfile, encoding='utf-8').read()[:120])
        a.stop()

        # ---- K) --tools 收窄后 remember 不在工具表里
        a = H.Agent(home, base, extra_env=env, tools=['read_file', 'list_dir'])
        before = len(SCRIPT.requests)
        a.turn('只读会话')
        body = SCRIPT.requests[before] if len(SCRIPT.requests) > before else '{}'
        names = []
        try:
            req = json.loads(body)
            names = [t.get('function', {}).get('name') for t in (req.get('tools') or [])]
        except ValueError:
            pass
        H.check('remember' not in names, '--tools 收窄后 remember 不给模型', str(names))
        a.stop()
    finally:
        try:
            srv.shutdown()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)

    return H.finish('memory')


if __name__ == '__main__':
    sys.exit(main())
