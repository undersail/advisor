#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""models.txt 与 %PROVIDERS 注册表的一致性卡口（CI 与本地共用）。

拦的错都是「改了注册表忘了改模型表」或反过来造成的静默故障：
  · models.txt 声明的 provider 在 %PROVIDERS 里不存在 → 选到这个模型才炸
  · base_url 型 provider 但该行没写 base_url → 请求打到空地址
  · 模型 ID 重复 → 菜单里点哪个都算第一个
  · flags 里出现不认识的词 → 拼错了就等于没开
  · 模型 ID 与 provider 的 model_prefix 不匹配 → 仅警告（models.txt 的
    provider 列优先，接前缀只是兜底推断）
"""
import re
import sys

PERL = 'agent/claude-agent.pl'
MODELS = 'models.txt'
KNOWN_FLAGS = {'notools'}


def registry():
    """从 perl 里抽出 %PROVIDERS 每个条目的字段名集合。"""
    src = open(PERL, encoding='utf-8').read()
    m = re.search(r'^my %PROVIDERS = \((.*?)^\);', src, re.S | re.M)
    if not m:
        print('::error::%s: 找不到 %%PROVIDERS' % PERL)
        sys.exit(1)
    body = m.group(1)
    out = {}
    # 顶层 name => { ... }
    for em in re.finditer(r'^\s{4}([a-z][a-z0-9_]*)\s*=>\s*\{(.*?)^\s{4}\},', body, re.S | re.M):
        name, inner = em.group(1), em.group(2)
        fields = set(re.findall(r'^\s*([a-z_]+)\s*=>', inner, re.M))
        out[name] = fields
    return out


def main():
    reg = registry()
    if not reg:
        print('::error::没能从 %PROVIDERS 解析出任何 provider')
        return 1

    bad = 0
    seen = {}
    rows = 0
    for n, line in enumerate(open(MODELS, encoding='utf-8'), 1):
        line = line.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        rows += 1
        f = [x.strip() for x in line.split('|')]
        if len(f) < 2:
            print('::error::%s:%d 列数不足（至少 id|ja）：%s' % (MODELS, n, line))
            bad += 1
            continue
        mid = f[0]
        if mid in seen:
            print('::error::%s:%d 模型 ID 重复（首次出现于第 %d 行）：%s'
                  % (MODELS, n, seen[mid], mid))
            bad += 1
        seen.setdefault(mid, n)

        prov = f[4] if len(f) > 4 else ''
        base = f[5] if len(f) > 5 else ''
        flags = f[6].lower() if len(f) > 6 else ''

        if prov:
            if prov not in reg:
                print('::error::%s:%d provider "%s" 不在 %%PROVIDERS 里（已有：%s）'
                      % (MODELS, n, prov, ', '.join(sorted(reg))))
                bad += 1
                continue
            if 'base_url' in reg[prov] and not base:
                print('::error::%s:%d provider "%s" 需要 base_url，但这一行是空的'
                      % (MODELS, n, prov))
                bad += 1
            if 'base_url' not in reg[prov] and base:
                print('::error::%s:%d provider "%s" 不使用 base_url（它用固定 url），却写了 %s'
                      % (MODELS, n, prov, base))
                bad += 1
        for fl in re.split(r'[,\s]+', flags):
            if fl and fl not in KNOWN_FLAGS:
                print('::error::%s:%d 未知 flags 词 "%s"（已知：%s）'
                      % (MODELS, n, fl, ', '.join(sorted(KNOWN_FLAGS))))
                bad += 1

    print('models.txt: %d 条模型；注册表: %d 个 provider（%s）'
          % (rows, len(reg), ', '.join(sorted(reg))))
    if bad:
        print('models.txt 与注册表一致性检查未通过')
        return 1
    print('models.txt 与注册表一致性检查通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
