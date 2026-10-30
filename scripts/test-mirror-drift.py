#!/usr/bin/env python3
"""scripts/test-mirror-drift.py —— 「反拉保护」的真场景测试

为什么测这个：
    Gitee 镜像是强推（--all --force / --tags --force）。保护逻辑要是漏判，
    别人在 Gitee 上的提交就被无声覆盖；反过来过度敏感，正常同步会一直被卡住。
    两种错误都只能靠「造出真实场景跑一遍」来验，所以这里用本地裸仓库当"镜像"。

每个用例都用独立的一对仓库，互不干扰；断言到退出码和提示文案。
运行：python3 scripts/test-mirror-drift.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
GUARD = os.path.join(REPO, 'scripts', 'check-mirror-drift.sh')

results = []


def check(name, ok, detail=None):
    results.append((name, ok))
    print(('  ok    ' if ok else '  FAIL  ') + name
          + ((' | ' + str(detail)) if detail and not ok else ''))
    if not ok:
        print('::error::镜像漂移保护测试失败: %s%s'
              % (name, (' | 细节: ' + str(detail)) if detail else ''))


def run(cmd, cwd, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, stdin=subprocess.DEVNULL, timeout=180,
                          text=True, encoding='utf-8', errors='replace', env=env)


def git(cwd, *args):
    r = run(['git'] + list(args), cwd)
    if r.returncode != 0:
        raise RuntimeError('git %s 失败: %s' % (' '.join(args), r.stderr[:300]))
    return r.stdout


def write_commit(repo, name, content, message):
    with open(os.path.join(repo, name), 'w') as f:
        f.write(content)
    git(repo, 'add', name)
    git(repo, 'commit', '-q', '-m', message)


def new_pair(work, tag):
    """本地仓 + 裸镜像仓，两者一致（镜像已有第一个提交）。"""
    base = os.path.join(work, tag)
    os.makedirs(base)
    local = os.path.join(base, 'local')
    mirror = os.path.join(base, 'mirror.git')
    os.makedirs(local)
    git(local, 'init', '-q', '-b', 'main')
    git(local, 'config', 'user.email', 'test@example.com')
    git(local, 'config', 'user.name', 'test')
    write_commit(local, 'a.txt', 'v1\n', 'first')
    git(work, 'init', '-q', '--bare', mirror)
    git(local, 'remote', 'add', 'mirror', mirror)
    git(local, 'push', '-q', 'mirror', 'main')
    return local, mirror, base


def side_clone(work, base, mirror):
    """模拟「有人在 Gitee 侧直接改」：克隆镜像，加提交/加 tag，推回去。"""
    side = os.path.join(base, 'side')
    if not os.path.exists(side):
        git(base, 'clone', '-q', mirror, side)
        git(side, 'config', 'user.email', 'other@example.com')
        git(side, 'config', 'user.name', 'other')
        # 裸仓的 HEAD 默认指向 master，clone 下来本地没有 main，要显式切过去
        git(side, 'checkout', '-q', '-B', 'main', 'origin/main')
    return side


def guard(local, mirror, *args):
    return run(['/bin/bash', GUARD, mirror] + list(args), local)


def guard_debug(local, mirror, *args):
    """带诊断开关跑一遍：探测到的分支/tag 名单会打到 stderr。"""
    env = dict(os.environ, ADVISOR_MIRROR_DEBUG='1')
    return run(['/bin/bash', GUARD, mirror] + list(args), local, env=env)


def main():
    if not (os.path.exists(GUARD) and os.access(GUARD, os.X_OK)):
        check('守卫脚本存在且可执行', False, GUARD)
        return finish()
    check('守卫脚本存在且可执行', True)

    # 工作流本身也要覆盖 tag：分支同步绿 ≠ tag 同步了。
    # 真实事故：v0.2.3 打完 tag 后 Gitee 上 tags 只到 v0.2.2 —— 因为 workflow
    # 只在 push main 时触发，而 tag 是那次 push 之后才创建的。
    wf = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      '.github', 'workflows', 'sync-gitee.yml')
    try:
        wf_txt = open(wf, encoding='utf-8').read()
    except OSError:
        wf_txt = ''
    check('镜像工作流在推 tag 时也会同步（否则发版后镜像缺 tag）',
          "tags: ['v*']" in wf_txt, wf)
    # 红了要能看出是哪一类失败：守卫失败分支里必须打开诊断（ADVISOR_MIRROR_DEBUG），
    # 否则日志里只剩「已中止同步」一句结论 —— v0.2.4 推 tag 那次就是看不出来。
    check('守卫失败时会带诊断重跑（红了能分清漂移/读不到/tag 形式不同）',
          'ADVISOR_MIRROR_DEBUG=1' in wf_txt, wf)

    work = tempfile.mkdtemp(prefix='drift-')
    try:
        # ---- A) 一致 → 放行
        local, mirror, base = new_pair(work, 'a')
        r = guard(local, mirror)
        check('镜像与本地一致 → 放行（退出 0）', r.returncode == 0,
              '退出 %d: %s' % (r.returncode, (r.stdout + r.stderr)[-200:]))

        # ---- B) 镜像多一个提交 → 拦住
        side = side_clone(work, base, mirror)
        write_commit(side, 'gitee.txt', '在 Gitee 上加的\n', 'gitee only work')
        git(side, 'push', '-q', 'origin', 'main')
        r = guard(local, mirror)
        out = r.stdout + r.stderr
        check('镜像有本地没有的提交 → 拦住（退出 2）', r.returncode == 2,
              '退出 %d: %s' % (r.returncode, out[-200:]))
        check('拦住时告诉人怎么反拉（cherry-pick / merge）',
              'cherry-pick' in out or 'merge' in out, out[-200:])
        check('拦住时指出是哪个分支漂移', 'main' in out, out[-160:])
        check('拦住时不会说「可以推」', '可以推' not in out, out[-160:])

        # ---- C) 反拉回来之后 → 恢复放行
        git(local, 'fetch', '-q', 'mirror', 'main')
        git(local, 'reset', '-q', '--hard', 'FETCH_HEAD')
        r = guard(local, mirror)
        check('反拉回来后恢复放行', r.returncode == 0,
              '退出 %d: %s' % (r.returncode, (r.stdout + r.stderr)[-160:]))

        # ---- C2) cherry-pick 回来之后：补丁等价 → 放行（不能永久卡住）
        local6, mirror6, base6 = new_pair(work, 'c2')
        side6 = side_clone(work, base6, mirror6)
        write_commit(side6, 'fix.txt', '修好的内容\n', 'fix on gitee')
        git(side6, 'push', '-q', 'origin', 'main')
        r = guard(local6, mirror6)
        check('cherry-pick 之前：镜像提交未进入本地 → 拦住', r.returncode == 2,
              '退出 %d' % r.returncode)
        git(local6, 'fetch', '-q', 'mirror', 'main')
        git(local6, 'cherry-pick', 'FETCH_HEAD')
        r = guard(local6, mirror6)
        out = r.stdout + r.stderr
        check('cherry-pick 之后：等价补丁存在 → 放行（不会永久卡住同步）',
              r.returncode == 0, '退出 %d: %s' % (r.returncode, out[-200:]))
        check('并说明是按等价补丁收敛的', '等价' in out, out[-160:])

        # ---- D) 镜像同名 tag 指向本地历史之外的提交 → 拦住
        local2, mirror2, base2 = new_pair(work, 'd')
        side2 = side_clone(work, base2, mirror2)
        git(side2, 'checkout', '-q', '-b', 'experiment')
        write_commit(side2, 'e.txt', 'x\n', 'experiment work')
        git(side2, 'tag', 'v9.9.9')
        git(side2, 'push', '-q', 'origin', 'v9.9.9')
        git(local2, 'tag', 'v9.9.9')          # 本地同名 tag，指向不同提交
        r = guard(local2, mirror2)
        out = r.stdout + r.stderr
        check('镜像同名 tag 指向本地没有的提交 → 拦住（退出 2）', r.returncode == 2,
              '退出 %d: %s' % (r.returncode, out[-200:]))
        check('拦住时点名是哪个 tag', 'v9.9.9' in out, out[-160:])

        # ---- E) 镜像上只是不同名的 tag → 放行（不会被覆盖）
        local3, mirror3, base3 = new_pair(work, 'e')
        side3 = side_clone(work, base3, mirror3)
        git(side3, 'tag', 'v0.0.1-mirror')
        git(side3, 'push', '-q', 'origin', 'v0.0.1-mirror')
        r = guard(local3, mirror3)
        out = r.stdout + r.stderr
        check('镜像上不同名的 tag 不拦', r.returncode == 0,
              '退出 %d: %s' % (r.returncode, out[-200:]))
        if 'v0.0.1-mirror' not in out:
            dbg = guard_debug(local3, mirror3)
            for ln in (dbg.stdout[-300:] + dbg.stderr[-300:]).splitlines():
                print('::notice::诊断 %s' % ln.replace('%', '％'))
        check('但会提示镜像上有本地没有的 tag', 'v0.0.1-mirror' in out, out[-160:])

        # ---- F) 镜像有本地完全没有的分支（网页建的 master）→ 放行 + 提示
        local4, mirror4, base4 = new_pair(work, 'f')
        side4 = side_clone(work, base4, mirror4)
        git(side4, 'checkout', '-q', '-b', 'master')
        write_commit(side4, 'readme.md', '网页建的\n', 'init by web')
        git(side4, 'push', '-q', 'origin', 'master')
        r = guard(local4, mirror4)
        out = r.stdout + r.stderr
        check('镜像独有的分支不拦（--all 不会删除它）', r.returncode == 0,
              '退出 %d: %s' % (r.returncode, out[-200:]))
        if 'master' not in out:
            dbg = guard_debug(local4, mirror4)
            for ln in (dbg.stdout[-300:] + dbg.stderr[-300:]).splitlines():
                print('::notice::诊断 %s' % ln.replace('%', '％'))
        check('但会提示还有本地没有的分支', 'master' in out, out[-160:])

        # ---- G) 镜像落后于本地 → 放行（强推是预期收敛）
        local5, mirror5, _ = new_pair(work, 'g')
        write_commit(local5, 'b.txt', 'v2\n', 'second')
        git(local5, 'push', '-q', 'mirror', 'main')
        prev = git(local5, 'rev-parse', 'HEAD~1').strip()
        git(mirror5, 'update-ref', 'refs/heads/main', prev)
        r = guard(local5, mirror5)
        check('镜像落后于本地 → 放行', r.returncode == 0,
              '退出 %d: %s' % (r.returncode, (r.stdout + r.stderr)[-200:]))

        # ---- H) 读不到镜像 → 中止，绝不盲目推
        r = guard(local5, os.path.join(work, 'nope.git'))
        out = r.stdout + r.stderr
        check('读不到镜像时中止（不盲目强推）', r.returncode != 0, '退出 %d' % r.returncode)
        check('读不到镜像时说明原因', '镜像' in out, out[-160:])
    finally:
        shutil.rmtree(work, ignore_errors=True)

    return finish()


def finish():
    bad = [n for n, ok in results if not ok]
    print('\n%d/%d 通过' % (len(results) - len(bad), len(results)))
    if bad:
        print('失败项: ' + '；'.join(bad))
        return 1
    return 0


if __name__ == '__main__':
    import traceback
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        tb = traceback.format_exc()
        print('::error::镜像漂移测试异常（未到断言就崩了）: %s'
              % tb.strip().split('\n')[-1][:200])
        print(tb)
        sys.exit(1)
