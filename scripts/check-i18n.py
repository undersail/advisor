#!/usr/bin/env python3
"""三语文案卡口（CI 与本地共用）。

背景：中文是逐条往 %S / _S 里补的，补的过程中同一 key 的多语言版本很容易
出现占位符个数不一致，运行时 sprintf / str.format 就会崩、或者把参数塞错
位置（中文文案里少一个 %s，用户看到的是一串没填的模板）。

拦的硬错误只有一类：
  · 同一 key 内各语言版本的占位符个数不一致
  · 文案表本身解析不到
未翻译的条目只报告数量，不判失败（否则逐条补的过程中每次提交都红）。

解析方式：
  · GUI 侧用 ast 求值，天然正确处理 "..." "..." 相邻拼接与嵌套；
  · Perl 侧不能用 eval，按嵌套层级切顶层逗号，再逐段取引号字面量
    （Perl 不会自动拼接相邻字面量，所以逐段取即可）。

用法：
    python3 scripts/check-i18n.py            # 检查 + 报告进度
    python3 scripts/check-i18n.py --strict   # 未翻译也判失败（收尾阶段用）
"""
import ast
import os
import re
import sys

PERL_PATH = 'agent/claude-agent.pl'
GUI_PATH = 'gui/advisor_gui.py'
LANGS = ('ja', 'en', 'zh')


# ---------------------------------------------------------------- 占位符

def perl_placeholders(text):
    """数 %s / %d 之类（%% 是转义，不计）。"""
    n, i = 0, 0
    while i < len(text) - 1:
        if text[i] == '%':
            if text[i + 1] == '%':
                i += 2
                continue
            m = re.match(r'%[-+ 0-9.]*[sd]', text[i:])
            if m:
                n += 1
                i += m.end()
                continue
        i += 1
    return n


def py_placeholders(text):
    return len(re.findall(r'\{[A-Za-z_][A-Za-z0-9_]*\}', text))


# ---------------------------------------------------------------- 工具
def split_top_level(body, seps=(',',)):
    """按嵌套层级为 0 的分隔符切分（跳过引号内的分隔符）。"""
    parts, depth, cur = [], 0, []
    quote = None
    esc = False
    for ch in body:
        if quote:
            cur.append(ch)
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == quote:
                quote = None
            continue
        if ch in '"\'':
            quote = ch
            cur.append(ch)
            continue
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if depth == 0 and ch in seps:
            parts.append(''.join(cur))
            cur = []
            continue
        cur.append(ch)
    if ''.join(cur).strip():
        parts.append(''.join(cur))
    return [p.strip() for p in parts if p.strip()]


def strip_comments(text):
    return re.sub(r'#[^\n]*', '', text)


def strip_line_comments(text):
    """只删整行注释，避免误伤字符串里的 # （Perl 文案里出现过 #）。"""
    return re.sub(r'(?m)^[ \t]*#[^\n]*\n', '', text)


# ---------------------------------------------------------------- Perl
def perl_entries():
    src = open(PERL_PATH, encoding='utf-8').read()
    m = re.search(r'^my %S = \((.*?)^\);', src, re.S | re.M)
    if not m:
        return None
    body = m.group(1)
    body = strip_line_comments(body)
    out = []
    for chunk in split_top_level(body):
        km = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*=>\s*(\S.*)$', chunk, re.S)
        if km:
            out.append((km.group(1), km.group(2).strip()))
    return out


def perl_langs(entry):
    """entry: '["ja","en"]' 或 '{ ja => "..", en => ".." }'"""
    inner = entry.strip()
    out = {}
    if inner.startswith('{'):
        body = inner[1:inner.rfind('}')]
        for chunk in split_top_level(body):
            km = re.match(r'(ja|en|zh)\s*=>\s*(\S.*)$', chunk, re.S)
            if km:
                out[km.group(1)] = km.group(2)
    elif inner.startswith('['):
        body = inner[1:inner.rfind(']')]
        for lang, chunk in zip(LANGS, split_top_level(body)):
            out[lang] = chunk
    return out


def perl_text(lit):
    """把 Perl 的引号字面量还原成原始文本（只为了数占位符，不必完全精确）。"""
    lit = lit.strip()
    m = re.match(r'"((?:[^"\\]|\\.)*)"', lit, re.S) or re.match(r"'((?:[^'\\]|\\.)*)'", lit, re.S)
    return m.group(1) if m else lit


# ---------------------------------------------------------------- GUI
def gui_entries():
    src = open(GUI_PATH, encoding='utf-8').read()
    m = re.search(r'^_S = \{(.*?)^\}', src, re.S | re.M)
    if not m:
        return None
    body = strip_comments(m.group(1))
    out = []
    for chunk in split_top_level(body):
        km = re.match(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*(\S.*)$', chunk, re.S)
        if km:
            out.append((km.group(1), km.group(2).strip()))
    return out


def gui_langs(entry):
    """用 ast 求值，正确处理相邻字面量拼接。失败时退回空。"""
    try:
        node = ast.parse(entry, mode='eval').body
        value = ast.literal_eval(node)
    except Exception:
        return {}
    if isinstance(value, dict):
        return {k: v for k, v in value.items() if k in LANGS and isinstance(v, str)}
    if isinstance(value, (tuple, list)):
        return {lang: v for lang, v in zip(LANGS, value) if isinstance(v, str)}
    return {}


# ---------------------------------------------------------------- 主流程

# ---------------------------------------------------------------- setup.sh
SETUP_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                          'setup.sh')


def setup_msg_blocks():
    """setup.sh 的 msg() 有三个 case 块（zh / en / ja）。

    这里查的是「三块是否一一对齐」：
      · 某个键只在其中一两块里出现 → 那只语言下会打印出裸键名
      · 占位符个数不一致 → printf 少一个参数会打空、多一个会重复
    这套结构是手写的，最容易在某次加文案时漏掉一块。
    """
    try:
        src = open(SETUP_PATH, encoding='utf-8').read()
    except OSError:
        return None
    bounds = []
    for marker in ('if [ "$LANGCODE" = "zh" ]; then\n    case "$key" in',
                   'if [ -z "$fmt" ] && [ "$IS_EN" = "1" ]; then\n    case "$key" in',
                   'if [ -z "$fmt" ]; then\n    case "$key" in'):
        i = src.find(marker)
        if i < 0:
            return None
        j = src.find('*) fmt="$key" ;;', i)
        if j < 0:
            return None
        bounds.append(src[i:j])
    out = []
    for seg in bounds:
        d = {}
        for m in re.finditer(r'^\s*([a-z][a-z0-9_]*)\) fmt="([^\n]*)" ;;', seg, re.M):
            d[m.group(1)] = m.group(2).count('%s')
        out.append(d)
    return out


def check_setup():
    blocks = setup_msg_blocks()
    if blocks is None:
        print('::error::%s: 解析不出 msg() 的三语块（结构变了？）' % SETUP_PATH)
        return 1
    zh, en, ja = blocks
    bad = 0
    for name, other in (('en', en), ('ja', ja)):
        only = sorted(set(zh) - set(other))
        extra = sorted(set(other) - set(zh))
        if only:
            print('::error::setup.sh: %s 缺这些键（会打印出裸键名）：%s'
                  % (name, ', '.join(only)))
            bad += 1
        if extra:
            print('::error::setup.sh: %s 有 zh 没有的键：%s' % (name, ', '.join(extra)))
            bad += 1
        for k in sorted(set(zh) & set(other)):
            if zh[k] != other[k]:
                print('::error::setup.sh: 键 %s 的占位符个数 zh=%d %s=%d'
                      % (k, zh[k], name, other[k]))
                bad += 1
    print('setup.sh: msg() 三语各 %d 条' % len(zh))
    return bad



def run():
    strict = '--strict' in sys.argv
    bad = 0
    totals = []

    for path, getter, langs_fn, ph_fn, label in (
        (PERL_PATH, perl_entries, perl_langs,
         lambda lit: perl_placeholders(perl_text(lit)), 'Perl'),
        (GUI_PATH, gui_entries, gui_langs, py_placeholders, 'GUI'),
    ):
        entries = getter()
        if entries is None:
            print('::error::%s: 找不到 %s 文案表' % (path, label))
            bad += 1
            totals.append((0, 0))
            continue

        with_zh = 0
        for key, entry in entries:
            langs = langs_fn(entry)
            if 'zh' in langs:
                with_zh += 1
            counts = {lang: ph_fn(lit) for lang, lit in langs.items()}
            if len(set(counts.values())) > 1:
                # 三语里只有中文缺失时不算问题（回退到英文），只有都已写
                # 却个数不一致才是真错误。
                print('::error::%s: 条目 %s 的占位符个数不一致 %s'
                      % (path, key, counts))
                bad += 1
        print('%s: 共 %d 条，已含中文 %d 条，待译 %d 条'
              % (path, len(entries), with_zh, len(entries) - with_zh))
        totals.append((len(entries), with_zh))

    bad += check_setup()

    if bad:
        print('占位符一致性检查未通过')
        return 1

    untranslated = sum(t - z for t, z in totals)
    if strict and untranslated:
        print('::error::仍有 %d 条未补中文（--strict 模式）' % untranslated)
        return 1

    print('占位符一致性检查通过；未译 %d 条' % untranslated)
    return 0


if __name__ == '__main__':
    sys.exit(run())
