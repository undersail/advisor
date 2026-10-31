#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""语言锁定：中文会话里不许冒出日文（工具说明曾经把模型的进度说明带跑）。

实机记录：用户要中文，回复是中文，但工具调用前后的那句「まとめて確認します」
是日文 —— 因为 read_file/write_file/list_dir/run_shell 的 description 写的是
日文，模型照着工具文档的语言写自己的旁白。这里把两头都钉住。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, 'agent', 'claude-agent.pl')
KANA = re.compile(r'[\u3040-\u30ff]')

fails = []


def check(cond, label, detail=''):
    if cond:
        print('  ok   %s' % label)
    else:
        print('  FAIL %s  %s' % (label, detail))
        fails.append(label)


def main():
    src = io.open(AGENT, encoding='utf-8').read()

    i = src.index('my @TOOLS = (')
    j = src.index('\n);', i)
    tools_block = src[i:j]
    bad = [l.strip() for l in tools_block.split('\n') if KANA.search(l)]
    check(not bad, '工具说明里没有日文（否则模型会照日文写旁白）', bad[:3])

    m = re.search(r"my \$SYSTEM_PROMPT = <<'EOS';(.*?)\nEOS\n", src, re.S)
    prompt = m.group(1) if m else ''
    check('progress' in prompt and 'status lines' in prompt,
          '系统提示明确了「进度说明/状态行也要用用户语言」', prompt[-200:])
    check('must NOT change your output language' in prompt,
          '系统提示说明了工具说明是英文但不影响输出语言')
    check('never Japanese' in prompt,
          '系统提示对「中文会话冒日文」有直接禁令')

    if fails:
        print('\n失败 %d 项' % len(fails))
        return 1
    print('\n全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
