#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布流水线里「非 macOS 部分」的本地验证。

做法：**从 .github/workflows/release.yml 里取出 `run:` 原文**，在本机真跑一遍
（换掉 github 表达式）。这样验的是 workflow 自己那几行，而不是我另抄一份逻辑
—— 手抄过一次 CI 检查逻辑，结果本地绿线上红。

不验的部分（本机做不到，如实跳过）：
    · py2app 打包（只能在 macOS 上跑）
    · gh release create（要 GitHub token）

    python3 scripts/test-release-workflow.py [-v]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, '.github', 'workflows', 'release.yml')
VERBOSE = '-v' in sys.argv
results = []


def check(name, ok, detail=None):
    results.append((name, ok))
    print('  %s %s' % ('ok  ' if ok else 'FAIL', name))
    if not ok:
        if detail:
            print('       细节: %s' % str(detail)[:400].replace('\n', ' / '))
        # 变成 GitHub annotation：macOS runner 的 step 日志要鉴权才能读，
        # annotation 不用（本机无 token 也能定位到底哪条断言红了）。
        print('::error::%s | 细节: %s' % (name, str(detail or '')[:300].replace('\n', ' / ')))


def steps_of(workflow_path):
    """极简 YAML 取块：只认 release.yml 这个结构（steps 列表 + name/run/env）。"""
    out = []
    cur = None
    in_run = False
    with open(workflow_path, encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^      - name: (.+)$', line)
            if m:
                if cur:
                    out.append(cur)
                cur = {'name': m.group(1).strip(), 'run': [], 'env': {}}
                in_run = False
                continue
            if cur is None:
                continue
            if re.match(r'^        run: \|$', line):
                in_run = True
                continue
            if re.match(r'^        [a-z]+:', line) and not line.startswith('          '):
                in_run = False
            if re.match(r'^        env:$', line):
                in_run = False
                continue
            m2 = re.match(r'^          ([A-Z_]+): (.+)$', line)
            if m2 and not in_run:
                cur['env'][m2.group(1)] = m2.group(2).strip()
                continue
            if in_run:
                cur['run'].append(line[10:] if line.startswith(' ' * 10) else line.lstrip())
    if cur:
        out.append(cur)
    for s in out:
        s['run'] = ''.join(s['run'])
    return out


def find_step(steps, keyword):
    for s in steps:
        if keyword in s['name']:
            return s
    return None


def run_script(text, workdir, extra_env=None):
    env = dict(os.environ)
    env.pop('GITHUB_REF_NAME', None)
    if extra_env:
        env.update(extra_env)
    p = subprocess.run(['bash', '-euo', 'pipefail', '-c', text],
                       cwd=workdir, env=env, capture_output=True, text=True)
    return p


def main():
    if not os.path.exists(WF):
        print('找不到 %s' % WF)
        return 1

    print('环境: %s %s' % (sys.platform, sys.version.split()[0]))
    steps = steps_of(WF)
    if VERBOSE:
        print('workflow 里的步骤：')
        for s in steps:
            print('  - %s (run: %d 字符)' % (s['name'], len(s['run'])))

    ver = find_step(steps, '解析版本')
    check('找到「解析版本」步骤', ver is not None)
    verif = find_step(steps, '校验产物')
    check('找到「校验产物」步骤', verif is not None)
    build = find_step(steps, '构建 standalone')
    check('找到「构建 standalone」步骤', build is not None)

    # ---------------- 版本解析：真跑 workflow 里那段 shell ----------------
    if ver:
        tmp = tempfile.mkdtemp(prefix='relver-')
        out_file = os.path.join(tmp, 'gh_output')
        open(out_file, 'w').close()
        # 把 ${{ github.event.inputs.tag }} 换成本地可控的字面量
        body = ver['run'].replace('${{ github.event.inputs.tag }}', '')
        p = run_script(body, tmp, {'GITHUB_REF_NAME': 'v0.2.0', 'GITHUB_OUTPUT': out_file})
        got = dict(l.split('=', 1) for l in open(out_file).read().strip().split('\n') if '=' in l)
        check('tag v0.2.0 → tag=v0.2.0', got.get('tag') == 'v0.2.0', got)
        check('tag v0.2.0 → version=0.2.0', got.get('version') == '0.2.0', got)
        check('版本解析退出码 0', p.returncode == 0, p.stderr.strip()[:200])

        # 不带 v 前缀的 tag 也要能解析
        open(out_file, 'w').close()
        p = run_script(body, tmp, {'GITHUB_REF_NAME': 'v1.10.3', 'GITHUB_OUTPUT': out_file})
        got = dict(l.split('=', 1) for l in open(out_file).read().strip().split('\n') if '=' in l)
        check('tag v1.10.3 → version=1.10.3（两位数字版本号不会被截断）',
              got.get('version') == '1.10.3', got)

    # ---------------- 产物校验：正例 + 负例 ----------------
    if verif:
        work = tempfile.mkdtemp(prefix='relzip-')
        os.makedirs(os.path.join(work, 'dist'))
        zip_path = os.path.join(work, 'dist', 'Advisor-v0.2.0-standalone.zip')

        def make_zip(members):
            with zipfile.ZipFile(zip_path, 'w') as z:
                for m in members:
                    z.writestr(m, 'x')

        full = ['Advisor.app/Contents/Resources/claude-agent.pl',
                'Advisor.app/Contents/Resources/models.txt',
                'Advisor.app/Contents/Resources/providers.txt',
                'ReadMe_ZH.txt']
        body = verif['run'].replace('${{ steps.ver.outputs.version }}', '0.2.0')

        # workflow 里 ADVISOR_VERSION 来自 env:（github 表达式），本机要显式给
        menv = {'ADVISOR_VERSION': '0.2.0'}

        make_zip(full)
        p = run_script(body, work, menv)
        check('资源齐全的 zip → 校验通过', p.returncode == 0, (p.stderr or p.stdout)[-200:])
        check('生成了 SHA256SUMS.txt',
              os.path.exists(os.path.join(work, 'dist', 'SHA256SUMS.txt')))
        if VERBOSE and p.returncode == 0:
            print('   ', p.stdout.strip().split('\n')[-1][:100])

        # 负例不仅要非 0，还要「因为缺文件」而失败 —— 否则变量没传也算通过，是假绿
        def negative(missing):
            make_zip([m for m in full if not m.endswith(missing)])
            r = run_script(body, work, menv)
            out = (r.stdout or '') + (r.stderr or '')
            return r, out

        r, out = negative('models.txt')
        check('缺 models.txt 的 zip → 校验失败（防止发出跑不起来的包）',
              r.returncode != 0 and 'models.txt' in out, out.strip()[-160:])

        r, out = negative('ReadMe_ZH.txt')
        check('缺 ReadMe_ZH.txt 的 zip → 校验失败',
              r.returncode != 0 and 'ReadMe_ZH.txt' in out, out.strip()[-160:])

        # 清单很长时也不能假红：macOS 管道缓冲 16KB，`unzip -l | grep -q` 会因 SIGPIPE
        # 让 pipeline 返回 141 → pipefail 下被判成「文件缺失」。这里把 zip 塞满条目，
        # 让清单明显超过 16KB 再真跑一次。
        many = full + ['Advisor.app/Contents/Resources/filler_%04d.bin' % i for i in range(1200)]
        make_zip(many)
        p = run_script(body, work, menv)
        check('清单很长（>16KB）的 zip 仍校验通过（防 SIGPIPE 假阴性）',
              p.returncode == 0, (p.stderr or p.stdout)[-200:])
        shutil.rmtree(work, ignore_errors=True)

    # ---------------- 静态规则：pipefail + 提前退出的下游 = 假阴性 ----------------
    # `生产者 | grep -q` 里 grep 一命中就退出，生产者收到 SIGPIPE(141)；
    # 在 set -o pipefail 下 pipeline 返回 141，`if` 把它当成失败 —— 文件在也报缺失。
    # 这不是理论问题：CI 的 macOS 腿就是这么假红过一次，真发布也会中招。
    bad_pipe = []
    for st in steps:
        run = st.get('run') or ''
        if 'pipefail' not in run:
            continue
        for line in run.split('\n'):
            bare = line.split('#')[0].strip()
            if not bare or bare.endswith('|| true'):
                continue          # 显式吞掉退出码是可以的（SIGPIPE 已在注释里说明）
            if '|' in bare and any(t in bare for t in ('grep -q', 'head -', 'grep -m')):
                bad_pipe.append((st.get('name', '?'), bare[:70]))
    check('pipefail 的步骤里没有「管道 + 会提前退出的下游」（SIGPIPE 会造成假阴性）',
          not bad_pipe, str(bad_pipe[:3]))

    # ---------------- 发布说明检查步骤：四种组合真跑 ----------------
    # 这一步在 v0.2.1 的首次真实发布里把 job 弄红了；它本身只该提示、不该拦。
    # 所以在本地把 workflow 里的原文抽出来，四种组合逐一真跑。
    notes_step = find_step(steps, '检查发布说明是否存在')
    check('找到「检查发布说明是否存在」步骤', notes_step is not None)
    if notes_step:
        work = tempfile.mkdtemp(prefix='relnotes-')
        os.makedirs(os.path.join(work, 'docs', 'releases'), exist_ok=True)
        open(os.path.join(work, 'docs', 'releases', 'v0.2.1.md'), 'w').write('# notes\n')
        body = notes_step['run']

        def run_notes(tag_out, ref_name):
            b = body.replace('${{ steps.ver.outputs.tag }}', tag_out)
            return run_script(b, work, {'GITHUB_REF_NAME': ref_name})

        r = run_notes('v0.2.1', 'v0.2.1')
        check('说明文件存在 → 退出码 0 且报出文件名',
              r.returncode == 0 and '找到发布说明' in r.stdout, (r.stdout or '')[-160:])
        check('说明文件存在 → 打印实际行数', '1 行' in r.stdout, r.stdout[-80:])

        r = run_notes('v9.9.9', 'v9.9.9')
        check('说明文件缺失 → 仍然退出码 0（只提示，不拦发布）',
              r.returncode == 0 and '缺少' in r.stdout, (r.stdout + r.stderr)[-160:])
        check('说明文件缺失 → 给出 warning 注解', '::warning::' in r.stdout)

        r = run_notes('', 'v0.2.1')
        check('步骤输出为空 → 回退用 GITHUB_REF_NAME，仍能找到',
              r.returncode == 0 and '找到发布说明' in r.stdout, r.stdout[-160:])

        shutil.rmtree(os.path.join(work, 'docs'), ignore_errors=True)
        r = run_notes('v0.2.1', 'v0.2.1')
        check('连 docs/releases 目录都没有 → 仍然退出码 0',
              r.returncode == 0 and '缺少' in r.stdout, (r.stdout + r.stderr)[-160:])
        shutil.rmtree(work, ignore_errors=True)

    # ---------------- 触发与权限的静态约束 ----------------
    wf = open(WF, encoding='utf-8').read()
    check('tag 触发模式包含 v*', "tags:" in wf and "'v*'" in wf)
    check('需要 contents: write（建 Release 用）', 'contents: write' in wf)
    check('只在 macOS 上构建（py2app 限制）', 'runs-on: macos-latest' in wf)
    check('Release 只在 tag 触发时创建', "github.event_name == 'push'" in wf)
    check('有手动触发（可在发版前演练）', 'workflow_dispatch' in wf)
    check('发布说明缺失时给警告而不是静默', 'generate-notes' in wf and '::warning' in wf)

    bad = [r for r in results if not r[1]]
    print('\n%d/%d 通过' % (len(results) - len(bad), len(results)))
    if bad:
        print('失败项：')
        for n, _ in bad:
            print('  · ' + n)
        return 1
    print('注：py2app 打包与 gh release create 只能在 macOS runner 上验，本机跳过。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
