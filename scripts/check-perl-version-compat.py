#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Perl 版本兼容卡口：目标机是 macOS High Sierra 自带的 **perl 5.26**，
而 CI 上跑的是 5.34（macos-15-intel）/ 5.38（ubuntu）—— 这个差就是盲区。

这个卡口只做一件事：**拦住 5.26 之后才有的写法**，让「CI 绿但用户双击打不开」这类
问题在提交阶段就暴露，而不是等到装机。

今天是 0 命中（加它纯属保险）：实测全仓扫一遍，5.27+ 的语法/特性一处都没有。

涉及特性与引入版本：
  use v5.28+ / use 5.028+      声明更高版本 → 5.26 上直接 "Perl v5.28.0 required"
  use feature ':5.28'+         feature bundle 版本高于 5.26 → 编译错误
  builtin::                    5.36（5.26 上等于调用不存在的包函数）
  try { } / catch ( )          5.34
  $x isa Foo                   5.32（中缀运算符）
  class Foo { } / method ...   5.38
  use experimental             不存在的 pragma 之外的用法在 5.26 上会失败

用法：
  python3 scripts/check-perl-version-compat.py            # 扫已跟踪的 .pl/.pm
  python3 scripts/check-perl-version-compat.py --self-test # 验它自己会红（CI 里两步都跑）
"""
import os
import re
import subprocess
import sys
import tempfile

TARGET = '5.26'                       # High Sierra 自带的 perl
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (说明, 引入版本, 正则) —— 命中即失败
PATTERNS = [
    (r'use\s+v?(5\.(?:0)?(?:2[7-9]|[3-9]\d)|5\.(?:[3-9]\d))\b',
     '5.27+', 'use v5.27+ 声明更高版本（目标机 5.26 直接报 "requires"）'),
    (r'use\s+feature\s+[^;]*:5\.(?:2[7-9]|[3-9]\d)', '5.28+',
     "use feature ':5.2x+' 的 bundle 版本高于 5.26"),
    (r'\bbuiltin::', '5.36', 'builtin:: （5.26 上没有这个命名空间）'),
    (r'(?<![\w:$@%>.-])\btry\s*\{', '5.34', 'try { } 关键字'),
    (r'(?<![\w:$@%>.-])\bcatch\s*\(', '5.34', 'catch ( ) 关键字'),
    (r'(?<![\w:$@%>.-])\bclass\s+[A-Za-z_]\w*\s*(?::[^{]*)?\{', '5.38', 'class 关键字'),
    (r'(?<![\w:$@%>.-])\bmethod\s+[A-Za-z_]\w*\s*[\({]', '5.38', 'method 关键字'),
    (r'(?<![\w:$@%>-])\bisa\s+[A-Za-z_:][\w:]*\s*(?:;|,|\)|\}|\|\||&&|\?)', '5.32',
     '$x isa Foo 中缀运算符（注意 ->isa( 是方法调用，不受影响）'),
]


def tracked_files():
    try:
        out = subprocess.run(['git', 'ls-files', '*.pl', '*.pm'],
                             cwd=ROOT, capture_output=True, text=True,
                             encoding='utf-8', errors='replace', timeout=60)
        files = [f for f in (out.stdout or '').splitlines() if f.strip()]
        if files:
            return files
    except Exception:
        pass
    files = []
    for base, _dirs, names in os.walk(ROOT):
        if os.sep + '.git' in base:
            continue
        for n in names:
            if n.endswith(('.pl', '.pm')):
                files.append(os.path.relpath(os.path.join(base, n), ROOT))
    return sorted(files)


def scan_text(text):
    """返回 [(行号, 版本, 说明, 该行原文)]。注释行与 POD 跳过。"""
    hits = []
    in_pod = False
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('=cut'):
            in_pod = False
            continue
        if stripped.startswith('='):
            in_pod = True
            continue
        if in_pod or stripped.startswith('#'):
            continue
        for pat, ver, why in PATTERNS:
            if re.search(pat, line):
                hits.append((i, ver, why, stripped[:120]))
                break
    return hits


def scan():
    files = tracked_files()
    bad = []
    for f in files:
        path = os.path.join(ROOT, f)
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError as e:
            print('::error::读不到 %s：%s' % (f, e))
            return 1
        for ln, ver, why, code in scan_text(text):
            bad.append((f, ln, ver, why, code))
    if bad:
        print('发现 %d 处目标机（perl %s）不支持的写法：' % (len(bad), TARGET))
        for f, ln, ver, why, code in bad:
            print('  %s:%d  [perl %s+] %s' % (f, ln, ver, why))
            print('      %s' % code)
            print('::error::%s:%d perl %s 起才有：%s' % (f, ln, ver, why))
        print('\n修法：换成 5.26 就有的写法（例如 try/catch 用 eval、isa 用 ->isa、'
              'builtin:: 用内建函数），或明确放弃老目标机。')
        return 1
    print('Perl 版本兼容通过：%d 个文件，未使用 %s 之后的语法/特性（目标机 High Sierra）'
          % (len(files), TARGET))
    return 0


def self_test():
    """正负例各跑一遍：卡口必须能红，且不能误报。"""
    positives = [
        ('use v5.36;\n', 'use v5.36'),
        ("use feature ':5.34';\n", "feature ':5.34'"),
        ('my $x = builtin::abs(-1);\n', 'builtin::'),
        ('try { x() } catch ($e) { y() }\n', 'try / catch'),
        ('class Foo { has $x; }\n', 'class'),
        ('if ($obj isa Foo) { 1 }\n', 'isa 运算符'),
    ]
    negatives = [
        ('use 5.010;\nuse strict;\nuse warnings;\n', 'use 5.010 是允许的'),
        ("if ($obj->isa('Foo')) { 1 }\n", '->isa() 是方法调用，5.26 可用'),
        ('my %h = (isa => 1);\nmy $isa = 2;\n', 'isa 当哈希键/变量名不算'),
        ('# try { 只是注释\n=pod\ntry { 文档里的示例\n=cut\n', '注释与 POD 跳过'),
        ('my $ok = eval { risky() };\n', 'eval 写法正常'),
    ]
    fails = 0
    for src, label in positives:
        if not scan_text(src):
            print('  FAIL 应当命中却放过了：%s' % label)
            fails += 1
        else:
            print('  ok   命中 %s' % label)
    for src, label in negatives:
        got = scan_text(src)
        if got:
            print('  FAIL 误报：%s → %s' % (label, got))
            fails += 1
        else:
            print('  ok   不误报 %s' % label)
    if fails:
        print('\n自检失败 %d 项（卡口本身有问题，别指望它守别人）' % fails)
        return 1
    print('\n自检通过：%d 正例 + %d 负例（共 %d 项）'
          % (len(positives), len(negatives), len(positives) + len(negatives)))
    return 0


if __name__ == '__main__':
    if '--self-test' in sys.argv:
        sys.exit(self_test())
    sys.exit(scan())
