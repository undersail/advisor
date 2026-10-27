#!/usr/bin/env python3
"""scripts/check-shell-var-glue.py —— 变量后面紧跟非 ASCII 字符必须加花括号

为什么需要（真故障，macOS 独有）：
    note "镜像上还有本地没有的分支：$mb（不会被删除）"

    在 bash 3.2（macOS 自带）+ UTF-8 locale 下，`（` 的首字节被当成标识符的一部分，
    整个 `$mb（` 被解析成「变量 mb（」→ 未定义 → 展开成空，还留下半个多字节乱码。
    实际输出变成「分支：��不会被删除」——分支名凭空消失。

    同一个脚本在 Linux 的 bash 5 上完全正常，所以在 macOS 上才红、本地永远复现不了。
    而这条恰好是给人看的提示，坏掉的正是最关键的那个名字。

规则：
    `$var` 或 `$1` 后面紧跟的字节 >= 0x80（中文、全角标点等）时，写成 `${var}`。
    `${var}中文` 无歧义，任何 bash 版本都不会误判。

检查范围：仓库里所有 shell 脚本（*.sh、scripts/hooks/*、以及生成的脚本文本）。
退出码：0 通过，1 有违规。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BARE_VAR = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*')


def shell_files():
    out = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', 'dist', 'build')]
        for name in files:
            path = os.path.join(base, name)
            if name.endswith('.sh') or name == 'setup.sh':
                out.append(path)
                continue
            if os.sep + 'hooks' + os.sep in path:
                out.append(path)
                continue
            # 没有扩展名但首行是 shebang 的（如 setup.sh 之外的脚本）
            try:
                with open(path, 'rb') as fh:
                    head = fh.readline()
            except OSError:
                continue
            if head.startswith(b'#!') and b'bash' in head:
                out.append(path)
    return sorted(set(out))


def scan(path):
    """返回 [(行号, 变量, 后面的字符, 整行)]"""
    try:
        text = open(path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        return []
    bad = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in BARE_VAR.finditer(line):
            nxt = line[m.end():m.end() + 1]
            if nxt and ord(nxt) > 127:
                bad.append((i, m.group(0), nxt, line.strip()[:100]))
    return bad


def main():
    files = shell_files()
    problems = []
    for f in files:
        for lineno, var, nxt, line in scan(f):
            problems.append((os.path.relpath(f, ROOT), lineno, var, nxt, line))

    if problems:
        for rel, lineno, var, nxt, line in problems:
            print('::error::%s:%d 变量 %s 后面紧跟 %r，要写成 ${%s}（bash 3.2 会把它当成变量名的一部分）'
                  % (rel, lineno, var, nxt, var.lstrip('$')))
            print('    %s' % line)
        print('')
        print('失败：%d 处变量粘连非 ASCII 字符。写成 ${var} 即可。' % len(problems))
        return 1

    print('通过：%d 个 shell 脚本，没有变量粘连非 ASCII 字符的问题' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())
