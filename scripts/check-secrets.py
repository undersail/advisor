#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""入库前的「不许泄漏」卡口。

查的是**会被推到公开仓库的东西**：
    · API key / 令牌 / 私钥
    · 带真实 token 的 webhook 地址
    · 本机绝对路径（/home/<name>/、/Users/<name>/、C:\\Users\\…）
    · 个人标识（邮箱、微信 ID、chat id）
    · 本机生成的工具状态目录（.wrangler/、node_modules 之类）

    python3 scripts/check-secrets.py            # 扫已跟踪文件
    python3 scripts/check-secrets.py --history  # 连带扫提交历史（慢）

命中即 exit 1，并打印文件:行号。占位符（带 ... 的示例、明显是假的值）在白名单里。
"""
import re
import subprocess
import sys

ROOT = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                      capture_output=True, text=True).stdout.strip() or '.'

# ---------------------------------------------------------------- 规则
RULES = [
    ('OpenAI 风格密钥', re.compile(r'\bsk-[A-Za-z0-9_\-]{20,}')),
    ('Anthropic 密钥', re.compile(r'\bsk-ant-[A-Za-z0-9_\-]{20,}')),
    ('GitHub 令牌', re.compile(r'\b(ghp_|gho_|ghs_|ghu_|github_pat_)[A-Za-z0-9_]{20,}')),
    ('AWS key', re.compile(r'\bAKIA[0-9A-Z]{16}\b')),
    ('Slack 令牌', re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{10,}')),
    ('私钥块', re.compile(r'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY')),
    ('URL 里带长 token', re.compile(r'[?&](?:key|token|access_token|secret)=[A-Za-z0-9_\-]{20,}')),
    ('企微 webhook（带真 key）',
     re.compile(r'qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9\-]{20,}')),
    ('飞书 webhook（带真 hook id）',
     re.compile(r'open\.feishu\.cn/open-apis/bot/v2/hook/[0-9a-f\-]{20,}')),
    ('本机家目录（Linux）', re.compile(r'/home/(?!user\b|\*)[a-z_][a-z0-9_-]*/')),
    ('本机家目录（macOS）', re.compile(r'/Users/(?!user\b|\*)[a-z_][a-z0-9_-]*/')),
    ('本机工作目录', re.compile(r'/data/[\w-]+/|/workspace/[\w-]+/|/opt/[\w-]+/work')),
    ('本机家目录（Windows）', re.compile(r'C:\\\\?Users\\\\?(?!user\b)[A-Za-z0-9_.-]+')),
    ('邮箱地址', re.compile(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')),
    ('微信/企微 chat id', re.compile(r'@im\.wechat\b|o9cq[A-Za-z0-9_\-]{10,}')),
    ('本机工具状态目录',
     re.compile(r'(?<![\w/])\.wrangler/|node_modules/[A-Za-z]')),
    ('疑似硬编码的 Bearer', re.compile(r'Bearer\s+[A-Za-z0-9._\-]{24,}')),
    # ---- Cloudflare：本项目是纯前端，任何云资源都必须由使用者填自己的账号 ----
    ('Cloudflare 账号/命名空间 ID', re.compile(r'(?:account_id|zone_id|namespace_id)\s*[=:]\s*[\"\']?[0-9a-f]{32}')),
    ('Cloudflare 令牌环境变量被赋值',
     re.compile(r'(?:CLOUDFLARE_(?:API_TOKEN|ACCOUNT_ID|ZONE_ID|API_KEY)|CF_API_(?:TOKEN|KEY))\s*[=:]\s*[\"\']?[A-Za-z0-9_\-]{16,}')),
    ('具体的 workers.dev 子域',
     re.compile(r'https?://(?!<)[A-Za-z0-9][A-Za-z0-9-]*\.(?!<)[A-Za-z0-9-]+\.workers\.dev')),
    ('KV 命名空间真实 id（非全零占位）',
     re.compile(r'id\s*=\s*[\"\'](?!0{32})[0-9a-f]{32}[\"\']')),
    ('Cloudflare 全局 API key 形态', re.compile(r'\b[0-9a-f]{37}\b')),
]

# 允许的「明显是假的 / 占位的」值：按出现位置放行
ALLOW_SUBSTR = [
    'sk-local-test', 'sk-x', 'sk-test', 'sk-xxx', 'sk-...',
    'test-token-123', 'devtoken', 'SECRETKEY', 'SECRET123',
    'example.com', 'example.org', 'localhost', '127.0.0.1',
    'user@host', 'you@example.com', 'noreply@',
    'your-key-here', '<', '...', 'xxxx',
]

# 二进制/生成物不扫
SKIP_EXT = ('.png', '.icns', '.jpg', '.jpeg', '.gif', '.zip', '.ico', '.pdf')

# 这个文件本身不扫：它的规则文本里必然出现被禁的模式（例如 .wrangler/），
# 那是规则的定义，不是泄漏。
SKIP_FILES = {'scripts/check-secrets.py'}


def allowed(line, m):
    # git@github.com:owner/repo.git 是 SSH 地址，不是邮箱
    if m.group(0).startswith('git@'):
        return True
    window = line[max(0, m.start() - 40):m.end() + 40]
    return any(a in window for a in ALLOW_SUBSTR)


def scan_text(where, text, hits):
    for i, line in enumerate(text.split('\n'), 1):
        for name, rx in RULES:
            for m in rx.finditer(line):
                if allowed(line, m):
                    continue
                hits.append((where, i, name, line.strip()[:140]))


def tracked_files():
    out = subprocess.run(['git', 'ls-files', '-z'], capture_output=True, text=True,
                         cwd=ROOT).stdout
    return [f for f in out.split('\0') if f]


def main():
    hits = []
    files = tracked_files()
    for f in files:
        if f.endswith(SKIP_EXT) or f in SKIP_FILES:
            continue
        try:
            with open(f'{ROOT}/{f}', 'rb') as fh:
                raw = fh.read()
        except OSError:
            continue
        if b'\0' in raw[:2000]:        # 二进制
            continue
        scan_text(f, raw.decode('utf-8', 'replace'), hits)

    if '--history' in sys.argv:
        # 扫历史提交里"新增的行" —— 只关心被加进去的东西。
        # 按文件切分，才能让 SKIP_FILES 生效（否则卡口自身的规则文本会自命中）。
        shas = subprocess.run(['git', 'rev-list', '--all'], capture_output=True,
                              text=True, cwd=ROOT).stdout.split()
        for sha in shas:
            d = subprocess.run(['git', 'show', '--format=%h', '--unified=0', sha],
                               capture_output=True, text=True, cwd=ROOT).stdout
            cur = ''
            buf = []
            for line in d.split('\n'):
                if line.startswith('+++ b/'):
                    if buf and cur not in SKIP_FILES and not cur.endswith(SKIP_EXT):
                        scan_text('commit %s:%s' % (sha[:8], cur), '\n'.join(buf), hits)
                    cur = line[6:]
                    buf = []
                elif line.startswith('+') and not line.startswith('+++'):
                    buf.append(line[1:])
            if buf and cur not in SKIP_FILES and not cur.endswith(SKIP_EXT):
                scan_text('commit %s:%s' % (sha[:8], cur), '\n'.join(buf), hits)

    # 使用者的本地配置与 wrangler 状态：必须被忽略，不能入库
    unignored = must_be_ignored(['remote/relay/wrangler.local.toml',
                                 'remote/relay/.wrangler/',
                                 'remote/relay/.dev.vars'])
    if unignored:
        print('这些路径没有被 .gitignore 覆盖，使用者填了自己的账号信息就会被提交：')
        for p in unignored:
            print('  · ' + p)
        return 1

    if hits:
        print('发现可能泄漏的内容（%d 处）：' % len(hits))
        for where, line_no, name, text in hits[:40]:
            print('  %s:%s  [%s]\n    %s' % (where, line_no, name, text))
        if len(hits) > 40:
            print('  ...（还有 %d 处）' % (len(hits) - 40))
        print('\n这些内容一旦推送就进了公开历史。要么改成占位值，'
              '要么加进 ALLOW_SUBSTR 并说明为什么它是安全的。')
        return 1

    print('泄漏检查通过：%d 个已跟踪文件%s' % (len(files), '，含提交历史' if '--history' in sys.argv else ''))
    return 0


def must_be_ignored(paths):
    """这些路径必须在 .gitignore 里：一旦被跟踪，使用者的账号信息就会跟着提交。"""
    bad = []
    for p in paths:
        r = subprocess.run(['git', 'check-ignore', '-q', p], cwd=ROOT)
        if r.returncode != 0:
            bad.append(p)
    return bad


if __name__ == '__main__':
    sys.exit(main())
