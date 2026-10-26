#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""models.txt / providers.txt / %PROVIDERS 三者的一致性卡口（CI 与本地共用）。

拦的错都是「改了一处忘了另一处」造成的静默故障：
  · models.txt 声明的 provider 在 %PROVIDERS 里不存在 → 选到这个模型才炸
  · base_url 型 provider 但该行没写 base_url → 请求打到空地址
  · 模型 ID 重复 → 菜单里点哪个都算第一个
  · flags 里出现不认识的词 → 拼错了就等于没开
  · providers.txt 少了一家 / 多了一家 → GUI 下拉里选不到的厂商
  · providers.txt 的 default_model 不在 models.txt 里 → 默认模型进不了菜单
  · provider 在 %PROVIDERS 里有 key_env/default_model → 已经搬到 providers.txt，
    留在代码里就是两处各写一份
  · 模型 ID 与 provider 的 model_prefix 不匹配 → 仅警告（models.txt 的
    provider 列优先，接前缀只是兜底推断）
"""
import re
import sys

PERL = 'agent/claude-agent.pl'
MODELS = 'models.txt'
PROVIDERS = 'providers.txt'
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
    for em in re.finditer(r'^\s{4}([a-z][a-z0-9_]*)\s*=>\s*\{(.*?)^\s{4}\},', body, re.S | re.M):
        name, inner = em.group(1), em.group(2)
        out[name] = set(re.findall(r'^\s*([a-z_]+)\s*=>', inner, re.M))
    return out


def providers():
    """providers.txt → {name: {key_env, default_model, key_url, ja, en, zh}}"""
    out = {}
    order = []
    for n, line in enumerate(open(PROVIDERS, encoding='utf-8'), 1):
        s = line.rstrip('\n')
        if not s.strip() or s.lstrip().startswith('#'):
            continue
        f = [x.strip() for x in s.split('|')]
        if len(f) < 4:
            print('::error::%s:%d 列数不足（至少 provider|key_env|default_model|key_url）：%s'
                  % (PROVIDERS, n, s))
            continue
        f += [''] * (7 - len(f))
        out[f[0]] = {'key_env': f[1], 'default_model': f[2], 'key_url': f[3],
                     'ja': f[4], 'en': f[5], 'zh': f[6], '_line': n}
        order.append(f[0])
    return out, order


def main():
    reg = registry()
    if not reg:
        print('::error::没能从 %PROVIDERS 解析出任何 provider')
        return 1

    ptab, porder = providers()
    bad = 0

    # ---- providers.txt 自身
    for name, info in ptab.items():
        ln = info['_line']
        if name not in reg:
            print('::error::%s:%d "%s" 不在 %%PROVIDERS 里' % (PROVIDERS, ln, name))
            bad += 1
        if not re.match(r'^[A-Z][A-Z0-9_]*$', info['key_env']):
            print('::error::%s:%d key_env "%s" 不像环境变量名' % (PROVIDERS, ln, info['key_env']))
            bad += 1
        if not info['key_url'].startswith('http'):
            print('::error::%s:%d key_url 不是网址：%s' % (PROVIDERS, ln, info['key_url']))
            bad += 1
        for lang in ('ja', 'en', 'zh'):
            if not info[lang]:
                print('::error::%s:%d 缺少 %s 标签' % (PROVIDERS, ln, lang))
                bad += 1
    for name in reg:
        if name not in ptab:
            print('::error::%%PROVIDERS 有 "%s"，但 %s 里没有它的行（GUI 下拉里会缺这家）'
                  % (name, PROVIDERS))
            bad += 1
        if 'key_env' in reg[name] or 'default_model' in reg[name]:
            print('::error::%%PROVIDERS 的 "%s" 仍写着 key_env/default_model —— '
                  '这两个字段的唯一定义处是 %s' % (name, PROVIDERS))
            bad += 1

    # ---- models.txt
    seen = {}
    rows = 0
    models_by_prov = {}
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
            models_by_prov.setdefault(prov, []).append(mid)
            if prov not in reg:
                print('::error::%s:%d provider "%s" 不在 %%PROVIDERS 里（已有：%s）'
                      % (MODELS, n, prov, ', '.join(sorted(reg))))
                bad += 1
                continue
            if prov not in ptab:
                print('::error::%s:%d provider "%s" 在 %s 里没有定义'
                      % (MODELS, n, prov, PROVIDERS))
                bad += 1
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
        # 前缀兜底推断是否说得通（仅提示）
        pfx = ''
        if prov and prov in reg:
            src = open(PERL, encoding='utf-8').read()
            pm = re.search(r'%s => \{.*?model_prefix\s*=>\s*\'([^\']*)\'' % re.escape(prov),
                           src, re.S)
            pfx = pm.group(1) if pm else ''
        if pfx and not mid.startswith(pfx):
            print('  note: %s 不以 %s 开头（provider 列已声明，不影响运行）' % (mid, pfx))

    # ---- providers.txt 的 default_model 必须在 models.txt 里
    for name, info in ptab.items():
        dm = info['default_model']
        if not dm:
            print('::error::%s 的 default_model 为空' % name)
            bad += 1
        elif dm not in seen:
            print('::error::provider "%s" 的 default_model "%s" 不在 %s 里'
                  % (name, dm, MODELS))
            bad += 1

    print('%s: %d 条模型；%s: %d 家；注册表: %d 个 provider（%s）'
          % (MODELS, rows, PROVIDERS, len(porder), len(reg), ', '.join(sorted(reg))))
    if bad:
        print('models.txt / providers.txt / 注册表 一致性检查未通过')
        return 1
    print('models.txt / providers.txt / 注册表 一致性检查通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
