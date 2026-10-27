#!/usr/bin/env python3
"""scripts/test-hooks.py —— 验证 pre-commit hook 真的会拦东西

为什么测这个：
    hook 最坑的形态是「装了但没生效」——比如文件没有执行位、core.hooksPath 写错、
    判断写反。这种失败悄无声息，直到某次把密钥/本机路径提交上去才发现。
    所以这里在临时 git 仓库里**真去 commit 一次**，断言：该拦的拦住了、该过的过了。

运行：python3 scripts/test-hooks.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
HOOKS = os.path.join(REPO, 'scripts', 'hooks')

results = []


def check(name, ok, detail=None):
    results.append((name, ok))
    print(('  ok    ' if ok else '  FAIL  ') + name + ((' | ' + str(detail)) if detail and not ok else ''))
    if not ok:
        print('::error::git hook 测试失败: %s%s' % (name, (' | 细节: ' + str(detail)) if detail else ''))


def git(cwd, *args, env=None):
    return subprocess.run(['git'] + list(args), cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL, timeout=180,
                          text=True, encoding='utf-8', errors='replace', env=env)


def make_repo(tmp):
    """造一个装了本项目 hook 的最小仓库。"""
    git(tmp, 'init', '-q')
    git(tmp, 'config', 'user.email', 'test@example.com')
    git(tmp, 'config', 'user.name', 'test')
    git(tmp, 'config', 'core.hooksPath', HOOKS)      # 直接用仓库里那份 hook
    os.makedirs(os.path.join(tmp, 'scripts'), exist_ok=True)
    shutil.copy(os.path.join(HERE, 'check-secrets.py'), os.path.join(tmp, 'scripts'))
    # check-secrets.py 还会核对 .gitignore 是否覆盖了敏感路径（wrangler.local.toml 等），
    # 所以临时仓库也要带上仓库自己的 .gitignore，否则「干净内容」也会因为缺 .gitignore 被拦。
    gi = os.path.join(REPO, '.gitignore')
    if os.path.exists(gi):
        shutil.copy(gi, os.path.join(tmp, '.gitignore'))
    return tmp


def commit(work, message='t'):
    return git(work, 'commit', '-q', '-m', message)


def main():
    hook = os.path.join(HOOKS, 'pre-commit')
    check('scripts/hooks/pre-commit 存在', os.path.exists(hook))
    if not os.path.exists(hook):
        return finish()
    check('pre-commit 有执行位（没有的话 git 会静默跳过）', os.access(hook, os.X_OK),
          '权限 %o' % (os.stat(hook).st_mode & 0o777))
    check('有安装脚本 scripts/install-git-hooks.sh',
          os.path.exists(os.path.join(REPO, 'scripts', 'install-git-hooks.sh')))

    # 拼出来而不是写字面量：check-secrets 会扫自己仓库的文件，
    # 夹具里留一个字面量 /Users/<名字>/ 就等于自己制造泄漏。
    fake_home = '/' + 'Users' + '/' + 'exampleuser'

    tmp = tempfile.mkdtemp(prefix='hooktest-')
    try:
        make_repo(tmp)

        # a) 干净的文件应该能提交
        good = os.path.join(tmp, 'clean.txt')
        with open(good, 'w') as f:
            f.write('这是一份干净的说明文件\n')
        git(tmp, 'add', 'clean.txt')
        r = commit(tmp, 'clean')
        check('干净内容可以正常提交', r.returncode == 0, (r.stderr or r.stdout)[-200:])

        # b) 含本机家目录 → 必须被拦
        leak = os.path.join(tmp, 'leak.txt')
        with open(leak, 'w') as f:
            f.write('路径: %s/Applications/Advisor.app\n' % fake_home)
        git(tmp, 'add', 'leak.txt')
        r = commit(tmp, 'leak')
        check('含 /Users/<名字>/ 的提交被拦下', r.returncode != 0, '返回 %d' % r.returncode)
        check('拦下时给出人能看懂的说明', '泄漏' in (r.stdout + r.stderr),
              (r.stdout + r.stderr).strip()[:160])
        git(tmp, 'reset', '-q', 'HEAD', 'leak.txt')
        os.remove(leak)

        # c) 含密钥样子的内容 → 必须被拦
        key = os.path.join(tmp, 'key.txt')
        with open(key, 'w') as f:
            # 同样运行期拼接：文件里不留 key 字面量，但临时仓库里那份是真的 key 形态
            f.write('API_KEY=%s\n' % ('sk-' + 'live' + '-' + 'abcdefghijklmnopqrstuvwxyz0123'))
        git(tmp, 'add', 'key.txt')
        r = commit(tmp, 'key')
        check('含疑似真实 API key 的提交被拦下', r.returncode != 0, '返回 %d' % r.returncode)
        git(tmp, 'reset', '-q', 'HEAD', 'key.txt')
        os.remove(key)

        # d) CRLF → 必须被拦
        crlf = os.path.join(tmp, 'crlf.txt')
        with open(crlf, 'wb') as f:
            f.write('第一行\r\n第二行\r\n'.encode('utf-8'))
        git(tmp, 'add', 'crlf.txt')
        r = commit(tmp, 'crlf')
        check('含 CRLF 的提交被拦下', r.returncode != 0, '返回 %d' % r.returncode)
        git(tmp, 'reset', '-q', 'HEAD', 'crlf.txt')
        os.remove(crlf)

        # e) 调试残留 → 必须被拦
        dbg = os.path.join(tmp, 'dbg.txt')
        with open(dbg, 'w') as f:
            f.write('TEMP_MARK 调试用的，提交前该删\n')
        git(tmp, 'add', 'dbg.txt')
        r = commit(tmp, 'dbg')
        check('含调试/临时标记的提交被拦下', r.returncode != 0, '返回 %d' % r.returncode)
        git(tmp, 'reset', '-q', 'HEAD', 'dbg.txt')
        os.remove(dbg)

        # f) --no-verify 应该能绕过（明确的逃生门，别做成拦死）
        with open(leak, 'w') as f:
            f.write('路径: %s/x\n' % fake_home)
        git(tmp, 'add', 'leak.txt')
        r = git(tmp, 'commit', '-q', '--no-verify', '-m', 'force')
        check('--no-verify 可以显式跳过（留逃生门）', r.returncode == 0,
              (r.stderr or r.stdout)[-160:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

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
