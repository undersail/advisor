#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""技能目录（~/.claude-agent/skills/）的端到端测试。

技能的取舍是「**只注入名字 + 一句话描述**，全文靠模型自己 read_file 读」——
这样 system prompt 不会被十几个技能撑爆（老 Mac 上 token 也是钱）。
所以这里最要紧的两条断言是：
  · 名字与描述真的进了 system prompt；
  · **正文没有**进 system prompt（否则「按需加载」就是假的）。
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_harness as H

SCRIPT = H.Script()


def sys_prompt_after(agent, text='随便说一句'):
    before = len(SCRIPT.requests)
    agent.turn(text)
    bodies = SCRIPT.requests[before:]
    return H.system_prompt_of(bodies[0]) if bodies else ''


def write(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(body)


def main():
    if not os.path.exists(H.AGENT):
        H.check(False, 'agent 存在', H.AGENT)
        return H.finish('skill')

    work = tempfile.mkdtemp(prefix='skill-')
    srv, base = H.make_server(SCRIPT)
    try:
        home = os.path.join(work, 'home')
        os.makedirs(home)
        sk = os.path.join(home, '.claude-agent', 'skills')
        env = {'CLAUDE_SKILLS_DIR': sk}

        # ---- A) 没有目录 / 空目录：不注入，/skills 告诉人放哪
        a = H.Agent(home, base, extra_env=env)
        H.check(a.hello is not None, '没有技能目录时正常握手')
        sp = sys_prompt_after(a)
        H.check('Skills available on this machine' not in sp,
                '没有技能时不注入技能段落', sp[-200:])
        ev = a.turn('/skills')
        txt = H.texts(ev)
        H.check('还没有技能' in txt, '/skills 空目录时说明还没技能', txt[:200])
        H.check(sk in txt, '/skills 告诉人放哪个目录', txt[:200])
        a.stop()

        # ---- B) 目录式 <名字>/SKILL.md：frontmatter 的 description 进 prompt
        write(os.path.join(sk, 'wecom-triage', 'SKILL.md'),
              '---\nname: wecom-triage\ndescription: 企业微信消息分流与回复草稿\n---\n\n'
              '# 企业微信分流\n\n正文第一步：先看发送者白名单。\n正文标记行-DO-NOT-INJECT\n')
        a = H.Agent(home, base, extra_env=env)
        sp = sys_prompt_after(a)
        H.check('wecom-triage' in sp, '目录式技能名进了 system prompt', sp[-400:])
        H.check('企业微信消息分流与回复草稿' in sp, 'frontmatter 的 description 进了 prompt', sp[-400:])
        H.check('正文标记行-DO-NOT-INJECT' not in sp,
                '正文没有进 prompt（按需 read_file 才读）', sp[-400:])
        H.check(os.path.join(sk, 'wecom-triage', 'SKILL.md') in sp,
                'prompt 里给出要 read_file 的路径', sp[-400:])

        # ---- C) 单文件 <名字>.md：首个标题当描述
        write(os.path.join(sk, 'backup-notes.md'),
              '# 备份笔记本\n\n第一步先 ls，然后 tar。\n')
        ev = a.turn('/skills')
        txt = H.texts(ev)
        H.check('backup-notes' in txt, '/skills 列出单文件技能', txt[:300])
        H.check('备份笔记本' in txt, '单文件技能用首个标题当描述', txt[:300])
        a.stop()

        a = H.Agent(home, base, extra_env=env)
        sp = sys_prompt_after(a)
        H.check('backup-notes: 备份笔记本' in sp, '单文件技能也进 prompt', sp[-500:])
        a.stop()

        # ---- D) 非 .md 文件忽略；中文名字可用；排序稳定
        write(os.path.join(sk, 'notes.txt'), '这不是技能，忽略。\n')
        write(os.path.join(sk, '中文技能.md'), '# 中文技能说明\n正文\n')
        a = H.Agent(home, base, extra_env=env)
        sp = sys_prompt_after(a)
        H.check('notes.txt' not in sp, '非 .md 文件不当技能', sp[-500:])
        H.check('中文技能' in sp, '中文技能名可用', sp[-500:])
        i1 = sp.find('backup-notes')
        i2 = sp.find('wecom-triage')
        i3 = sp.find('中文技能')
        H.check(0 <= i1 < i2 < i3, '技能按名字排序（输出稳定）', str((i1, i2, i3)))
        a.stop()

        # ---- E) 描述过长要截断，别把 prompt 撑大
        write(os.path.join(sk, 'long-desc', 'SKILL.md'),
              '---\ndescription: ' + ('很长的描述' * 60) + '\n---\n正文\n')
        a = H.Agent(home, base, extra_env=env)
        sp = sys_prompt_after(a)
        H.check('long-desc' in sp, '长描述技能仍然出现', sp[-500:])
        idx = sp.find('long-desc:')
        seg = sp[idx:idx + 200] if idx >= 0 else ''
        H.check('…' in seg, '描述被截断（带省略号）', seg[:160])
        # 80 字符上限：'很长的描述' 5 字符 → 最多 16 次。「整段塞进来」会是 60 次。
        desc_only = seg.split('(read:')[0].strip() if '(read:' in seg else seg
        desc_only = desc_only.replace('long-desc:', '').strip()
        H.check(len(desc_only) <= 82, '截断后描述长度收敛在 80 字符附近',
                '%d 字符: %s' % (len(desc_only), desc_only[:120]))
        a.stop()

        # ---- F) 受限会话（远程 --no-config）：/skills 被拒
        a = H.Agent(home, base, extra_env=env, no_config=True)
        ev = a.turn('/skills')
        txt = H.texts(ev)
        H.check('不能修改配置' in txt or 'config' in txt.lower(),
                '受限会话里 /skills 被拒', txt[:200])
        a.stop()

        # ---- G) 描述里没有 frontmatter 也没有标题 → 取第一行非空文本
        write(os.path.join(sk, 'plain', 'SKILL.md'), '就是一句话的说明\n第二行\n')
        a = H.Agent(home, base, extra_env=env)
        ev = a.turn('/skills')
        txt = H.texts(ev)
        H.check('就是一句话的说明' in txt, '没 frontmatter / 没标题时取首行当描述', txt[:400])
        a.stop()
    finally:
        try:
            srv.shutdown()
        except Exception:
            pass
        shutil.rmtree(work, ignore_errors=True)

    return H.finish('skill')


if __name__ == '__main__':
    sys.exit(main())
