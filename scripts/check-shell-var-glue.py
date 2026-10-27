#!/usr/bin/env python3
"""scripts/check-shell-var-glue.py —— shell 兼容性静态卡口（macOS 的 bash 3.2）

为什么需要（真故障，macOS 独有）：
    note "镜像上还有本地没有的分支：$mb（不会被删除）"

    在 bash 3.2（macOS 自带）+ UTF-8 locale 下，`（` 的首字节被当成标识符的一部分，
    整个 `$mb（` 被解析成「变量 mb（」→ 未定义 → 展开成空，还留下半个多字节乱码。
    实际输出变成「分支：��不会被删除」——分支名凭空消失。

    同一个脚本在 Linux 的 bash 5 上完全正常，所以在 macOS 上才红、本地永远复现不了。
    而这条恰好是给人看的提示，坏掉的正是最关键的那个名字。

规则：
    1. `$var` 或 `$1` 后面紧跟的字节 >= 0x80（中文、全角标点等）时，写成 `${var}`。
       `${var}中文` 无歧义，任何 bash 版本都不会误判。
    2. `case` 分支里不要直接写 `continue` / `break`：
           case "$f" in *.png) continue ;; esac
       在 bash 3.2 上会报 syntax error near unexpected token `;;`
       （Linux 的 bash 5 一切正常，所以只在 macOS 上炸）。用 if/else 改写。

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


CASE_CONTINUE = re.compile(r'(?:^|[;\s])(continue|break)\s*;;')


def scan_case_continue(path):
    """case 分支里直接 continue/break —— bash 3.2 会语法报错。"""
    try:
        text = open(path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        return []
    bad = []
    depth = 0
    for i, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith('#'):
            continue
        # 先看 esac 之前的部分：单行写法 `case … in x) continue ;; esac` 也要抓到
        pre = line.split('esac')[0]
        opened = len(re.findall(r'\bcase\b', pre))
        if (depth > 0 or opened > 0) and CASE_CONTINUE.search(pre):
            bad.append((i, line.strip()[:100]))
        depth += opened - (line.count('esac') - pre.count('esac'))
        if depth < 0:
            depth = 0
    return bad


def main():
    files = shell_files()
    problems = []
    for f in files:
        for lineno, var, nxt, line in scan(f):
            problems.append((os.path.relpath(f, ROOT), lineno, var, nxt, line))

    case_problems = []
    for f in files:
        for lineno, line in scan_case_continue(f):
            case_problems.append((os.path.relpath(f, ROOT), lineno, line))

    if case_problems:
        for rel, lineno, line in case_problems:
            print('::error::%s:%d case 分支里直接用 continue/break，bash 3.2 会语法报错，改用 if/else'
                  % (rel, lineno))
            print('    %s' % line)
        print('')
        print('失败：%d 处。' % len(case_problems))
        return 1

    if problems:
        for rel, lineno, var, nxt, line in problems:
            print('::error::%s:%d 变量 %s 后面紧跟 %r，要写成 ${%s}（bash 3.2 会把它当成变量名的一部分）'
                  % (rel, lineno, var, nxt, var.lstrip('$')))
            print('    %s' % line)
        print('')
        print('失败：%d 处变量粘连非 ASCII 字符。写成 ${var} 即可。' % len(problems))
        return 1

    print('通过：%d 个 shell 脚本（无变量粘连中文、无 case 里的 continue/break）' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())
