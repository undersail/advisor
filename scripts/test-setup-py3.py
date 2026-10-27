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



def srun(cmd, **kw):
    """跑子进程的统一入口。

    两条硬约定，都是被 macOS 上的挂死教育过的：
      · stdin=DEVNULL —— 生成的 wrapper 里有交互式 `read`（选模型），
        CI 的 stdin 是条不关闭的管道，不给 DEVNULL 就会永久阻塞；
      · timeout —— 挂住时要快速失败并报出原因，而不是耗掉整个 job 的超时预算。
    """
    kw.setdefault('stdin', subprocess.DEVNULL)
    kw.setdefault('capture_output', True)
    kw.setdefault('text', True)
    kw.setdefault('encoding', 'utf-8')
    kw.setdefault('errors', 'replace')
    kw.setdefault('timeout', 120)
    try:
        return subprocess.run(cmd, **kw)
    except subprocess.TimeoutExpired:
        class _T:
            returncode = -1
            stdout = ''
            stderr = '[超时] 命令 %d 秒未退出（大概率在等输入）: %s' % (
                kw['timeout'], ' '.join(cmd)[:120])
        print('::error::子进程超时，几乎一定是卡在等输入：%s' % ' '.join(cmd)[:160])
        return _T()


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
        r = srun(['/bin/bash', '-c', 'PATH=%s; %s; PY3="$(find_python3 || true)"; printf "%%s" "$PY3"'
                            % (empty, func_empty)], )
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
        r = srun(['/bin/bash', '-c', 'PATH=%s; %s; PY3="$(find_python3 || true)"; printf "%%s" "$PY3"'
                            % (okdir, func_ok)], )
        check('找到可执行的 python3 时选中它', r.stdout.strip() == fake, '得到 %r' % r.stdout.strip())

        # c) 同名但不可执行 → 不能被选中（这正是「看着有、其实用不了」的那类坑）
        nodir = os.path.join(work, 'noexec')
        os.makedirs(nodir)
        dead = os.path.join(nodir, 'python3')
        with open(dead, 'w') as f:
            f.write('#!/bin/bash\nexit 0\n')
        os.chmod(dead, 0o644)
        func_no = redirect(func, nodir)
        r = srun(['/bin/bash', '-c', 'PATH=%s; %s; PY3="$(find_python3 || true)"; printf "%%s" "$PY3"'
                            % (nodir, func_no)], )
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
        r = srun(['/bin/bash', path])
        check('解释器不存在时 wrapper 以非 0 退出', r.returncode != 0, '退出码 %s' % r.returncode)
        check('解释器不存在时给出人能看懂的提示（提到 python.org）',
              'python.org' in r.stderr, r.stderr.strip()[:160])
        check('提示里写清是哪个解释器找不到',
              '/nonexistent/python3' in r.stderr, r.stderr.strip()[:160])
        check('不再出现裸 exec「No such file or directory」那种噪音',
              'No such file or directory' not in r.stderr, r.stderr.strip()[:160])
    finally:
        shutil.rmtree(run, ignore_errors=True)

    # ---------------- 3. PATH 写入（advisor: command not found 那次） ----------------
    # 旧写法用 grep -F 判断，注释掉的 `# export PATH=$HOME/bin:$PATH` 会被当成
    # 「已经加过了」，于是一个字都不写，用户开新终端还是找不到 advisor。
    try:
        pfunc = extract_func(src, 'path_ensure')
    except SystemExit:
        pfunc = None
    check('setup.sh 里有 path_ensure（PATH 写入集中在一处）', pfunc is not None)
    if pfunc:
        pwork = tempfile.mkdtemp(prefix='pathtest-')
        try:
            def run_path_ensure(profile, shell='/bin/bash'):
                script = 'msg() { :; }\n' + pfunc + \
                         '\nPATH_WROTE_TO=""\npath_ensure "$1"\nprintf "%%s" "$PATH_WROTE_TO"\n'
                return srun(['/bin/bash', '-c', script, 'bash', profile],
                                                                            env=dict(os.environ, SHELL=shell))

            # a) 文件不存在 → 创建并写入
            missing = os.path.join(pwork, 'new_profile')
            run_path_ensure(missing)
            body = open(missing, encoding='utf-8').read() if os.path.exists(missing) else ''
            check('PATH 文件不存在时会创建并写入一行',
                  'export PATH=$HOME/bin:$PATH' in body, body)

            # b) 已经有生效的行 → 不重复写
            dup = os.path.join(pwork, 'dup_profile')
            with open(dup, 'w') as f:
                f.write('export PATH=$HOME/bin:$PATH\n')
            r = run_path_ensure(dup)
            lines = open(dup, encoding='utf-8').read().count('export PATH=$HOME/bin:$PATH')
            check('已有生效的 PATH 行时不重复写入', lines == 1, '出现 %d 次' % lines)

            # c) 只有注释行 → 必须补真行（这就是那次 command not found 的形态）
            commented = os.path.join(pwork, 'commented_profile')
            with open(commented, 'w') as f:
                f.write('# export PATH=$HOME/bin:$PATH\n')
            run_path_ensure(commented)
            body = open(commented, encoding='utf-8').read()
            effective = [l for l in body.split('\n')
                         if l.strip().startswith('export PATH=') and '$HOME/bin' in l]
            check('只有注释掉的 PATH 行时会补一条真正生效的', len(effective) == 1,
                  '生效行 %d 条' % len(effective))

            # d) 写完真的能被登录 shell 解析到（端到端，不只是文件里有那行字）
            home = os.path.join(pwork, 'home')
            os.makedirs(home)
            r = run_path_ensure(os.path.join(home, '.bash_profile'))
            os.makedirs(os.path.join(home, 'bin'), exist_ok=True)
            with open(os.path.join(home, 'bin', 'advisor'), 'w') as f:
                f.write('#!/bin/bash\necho ok\n')
            os.chmod(os.path.join(home, 'bin', 'advisor'), 0o755)
            r = srun(['/bin/bash', '-lc', 'command -v advisor'],
                                                              env=dict(os.environ, HOME=home))
            check('写完后登录 shell 能解析到 advisor（端到端）',
                  home in r.stdout, r.stdout.strip()[:120] or r.stderr.strip()[:120])
        finally:
            shutil.rmtree(pwork, ignore_errors=True)

        check('path_ensure 支持 zsh 的 ~/.zprofile（macOS 默认 shell）',
              '.zprofile' in src, '没找到 .zprofile')

    # ---------------- 4. 主流程：没有 Tk 就不生成 app ----------------
    check('主流程要求 python3 且具备 Tk 才生成 app',
          'PY3_HAS_TK' in src and re.search(r'if \[ -n "\$PY3" \] && \[ "\$PY3_HAS_TK" = 1 \]', src) is not None,
          '没找到 PY3_HAS_TK 判断')
    check('缺 python3/Tk 时给出可复制的安装命令（python.org 与 brew 两条）',
          'python.org/downloads/macos' in src and 'brew install python-tk' in src)
    check('提示里说明「只装 CLT 仍没有 Tk」（这一步最容易走错）',
          'Xcode Command Line Tools' in src and 'Tk' in src)

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
