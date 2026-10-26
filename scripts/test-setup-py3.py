#!/usr/bin/env python3
"""scripts/test-setup-py3.py —— setup.sh 的 python3 探测与 GUI 前置条件

为什么单独测这个：
    线上报过一个真实故障 —— 装完 setup.sh，双击 Advisor.app 得到
        <家目录>/Applications/Advisor.app/Contents/MacOS/Advisor: line 3:
        /usr/bin/python3: No such file or directory
    原因是旧代码最后一路兜底写死 `PY3=/usr/bin/python3`，而 macOS 12.3 起这个
    路径只有在装了 Xcode Command Line Tools 之后才存在。于是「兜底」兜到一个
    不存在的解释器，装配出来的 app 必然打不开，而 setup.sh 还以为一切正常。

    这类 bug 不会让任何现有测试变红（它是「成功生成了一个坏东西」），所以这里
    直接对 setup.sh 的两段行为下断言：
      1. find_python3 只接受**真能执行**的候选，不存在的路径不能被选中；
      2. 生成出来的简易版 wrapper 在解释器缺失时要给出人能看懂的话并退出 1，
         而不是 exec 一个不存在的路径。

运行：python3 scripts/test-setup-py3.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SETUP = os.path.join(HERE, '..', 'setup.sh')

results = []


def check(name, ok, detail=None):
    results.append((name, ok))
    print(('  ok    ' if ok else '  FAIL  ') + name + ((' | ' + str(detail)) if detail and not ok else ''))
    if not ok:
        # 让 CI 不用登录也能看到失败项
        print('::error::setup 前置条件测试失败: %s%s'
              % (name, (' | 细节: ' + str(detail)) if detail else ''))


def read_setup():
    with open(SETUP, encoding='utf-8') as f:
        return f.read()


def extract_func(src, name):
    """从 setup.sh 里抠出一个 shell 函数的原文。"""
    m = re.search(r'^%s\(\) \{.*?^\}' % re.escape(name), src, re.S | re.M)
    if not m:
        raise SystemExit('在 setup.sh 里找不到函数 %s' % name)
    return m.group(0)


def extract_wrapper(src):
    """抠出简易版 wrapper 的 here-doc 正文（模拟 setup.sh 展开）。"""
    start = src.index('cat > "$APP_PATH/Contents/MacOS/Advisor" << APPEOF')
    body = src[start:].split('<< APPEOF', 1)[1].lstrip('\n').split('\nAPPEOF')[0]
    return body


def main():
    src = read_setup()

    # ---------------- 1. find_python3 ----------------
    try:
        func = extract_func(src, 'find_python3')
    except SystemExit as e:
        check('setup.sh 里有 find_python3（python3 探测集中在一处）', False, e)
        return finish()

    check('setup.sh 里有 find_python3（python3 探测集中在一处）', True)

    # 不再写死 /usr/bin/python3 兜底（有 -x 判断才允许出现）
    hard = re.search(r'^\s*PY3=/usr/bin/python3\s*$', src, re.M)
    check('没有「无条件把 PY3 写死成 /usr/bin/python3」的兜底', hard is None,
          hard.group(0) if hard else None)

    work = tempfile.mkdtemp(prefix='py3test-')
    try:
        # 候选里的绝对路径（/usr/bin/python3 等）在测试机上可能真的存在，
        # 那会被正确选中，反而测不到「不存在/不可执行」的分支。
        # 所以把这些绝对路径重定向到临时目录，保留 -x 判断逻辑本身。
        def redirect(func_src, target_dir):
            return re.sub(r'(?<=[ \t"])/[A-Za-z0-9_./-]*python3(?="|[ \t]|$|;)',
                          os.path.join(target_dir, 'python3'), func_src)

        # a) 一个可执行文件都没有 → 必须返回空（调用方据此走「没有 python3」分支）
        empty = os.path.join(work, 'empty')
        os.makedirs(empty)
        func_empty = redirect(func, empty)
        r = subprocess.run(['/bin/bash', '-c', 'PATH=%s; %s; PY3="$(find_python3 || true)"; printf "%%s" "$PY3"'
                            % (empty, func_empty)], capture_output=True, text=True)
        check('没有任何可用 python3 时不选中任何路径', r.stdout.strip() == '',
              '选中了 %r' % r.stdout.strip())

        # b) 有一个可执行的假 python3 → 必须选中它
        okdir = os.path.join(work, 'ok')
        os.makedirs(okdir)
        fake = os.path.join(okdir, 'python3')
        with open(fake, 'w') as f:
            f.write('#!/bin/bash\nexit 0\n')
        os.chmod(fake, 0o755)
        func_ok = redirect(func, okdir)
        r = subprocess.run(['/bin/bash', '-c', 'PATH=%s; %s; PY3="$(find_python3 || true)"; printf "%%s" "$PY3"'
                            % (okdir, func_ok)], capture_output=True, text=True)
        check('找到可执行的 python3 时选中它', r.stdout.strip() == fake, '得到 %r' % r.stdout.strip())

        # c) 同名但不可执行 → 不能被选中（这正是「看着有、其实用不了」的那类坑）
        nodir = os.path.join(work, 'noexec')
        os.makedirs(nodir)
        dead = os.path.join(nodir, 'python3')
        with open(dead, 'w') as f:
            f.write('#!/bin/bash\nexit 0\n')
        os.chmod(dead, 0o644)
        func_no = redirect(func, nodir)
        r = subprocess.run(['/bin/bash', '-c', 'PATH=%s; %s; PY3="$(find_python3 || true)"; printf "%%s" "$PY3"'
                            % (nodir, func_no)], capture_output=True, text=True)
        check('不可执行的 python3 不被选中（这正是线上那次故障的形态）', r.stdout.strip() == '',
              '选中了 %r' % r.stdout.strip())
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # ---------------- 2. 生成的 wrapper ----------------
    try:
        body = extract_wrapper(src)
    except ValueError:
        check('setup.sh 里有简易版 wrapper 的 here-doc', False)
        return finish()
    check('setup.sh 里有简易版 wrapper 的 here-doc', True)

    run = tempfile.mkdtemp(prefix='wrptest-')
    try:
        # 用不存在的解释器路径展开（模拟「生成后解释器被删/当初就不存在」）
        wrapper = body.replace('$PY3', '/nonexistent/python3').replace('\\$', '$')
        path = os.path.join(run, 'Advisor')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(wrapper + '\n')
        os.chmod(path, 0o755)
        r = subprocess.run(['/bin/bash', path], capture_output=True, text=True)
        check('解释器不存在时 wrapper 以非 0 退出', r.returncode != 0, '退出码 %s' % r.returncode)
        check('解释器不存在时给出人能看懂的提示（提到 python.org）',
              'python.org' in r.stderr, r.stderr.strip()[:160])
        check('提示里写清是哪个解释器找不到',
              '/nonexistent/python3' in r.stderr, r.stderr.strip()[:160])
        check('不再出现裸 exec「No such file or directory」那种噪音',
              'No such file or directory' not in r.stderr, r.stderr.strip()[:160])
    finally:
        shutil.rmtree(run, ignore_errors=True)

    # ---------------- 3. 主流程：没有 Tk 就不生成 app ----------------
    check('主流程要求 python3 且具备 Tk 才生成 app',
          'PY3_HAS_TK' in src and re.search(r'if \[ -n "\$PY3" \] && \[ "\$PY3_HAS_TK" = 1 \]', src) is not None,
          '没找到 PY3_HAS_TK 判断')
    check('缺 Tk 时有三语提示 gui_no_tk',
          len(re.findall(r'gui_no_tk\)\s*fmt=', src)) == 3,
          '%d 条' % len(re.findall(r'gui_no_tk\)\s*fmt=', src)))

    return finish()


def finish():
    bad = [n for n, ok in results if not ok]
    print('\n%d/%d 通过' % (len(results) - len(bad), len(results)))
    if bad:
        print('失败项: ' + '；'.join(bad))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
