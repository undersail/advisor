#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""真机连通性自查：用你自己的 key 跑一遍，只输出 PASS/FAIL。

设计原则：key 只从环境变量读，绝不出现在命令行参数、输出、临时文件里。
任何错误信息在打印前都会把 key 本身替换成 ***(厂商报错里偶尔会回显)。

用法（在你自己机器上）：

    export DEEPSEEK_API_KEY=sk-...
    python3 scripts/live-check.py deepseek

    # 或者不给厂商，按 CLAUDE_PROVIDER / 默认 deepseek
    python3 scripts/live-check.py

验的是四件事 —— 都是 mock 验不出、只有真端点才能回答的：
  1. 普通对话能不能通（鉴权 + 端点 + 模型 ID 对不对）
  2. 发一个工具定义，模型会不会返回 tool_calls（函数调用支持与否）
  3. 把工具结果以 role:tool 回传，能不能拿到最终回答（协议往返）
  4. 上一轮的 reasoning_content 没被回传（DeepSeek-R1 类必须如此）

余额提示：一次完整自查约花 3 次极短请求（max_tokens=16~64），成本可忽略。
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_providers():
    out = {}
    for path in (os.path.join(REPO, 'providers.txt'),
                 os.path.expanduser('~/claude-build/providers.txt')):
        if not os.path.isfile(path):
            continue
        for line in open(path, encoding='utf-8'):
            s = line.rstrip('\n')
            if not s.strip() or s.lstrip().startswith('#'):
                continue
            f = [x.strip() for x in s.split('|')]
            if len(f) >= 4 and f[0]:
                out[f[0]] = {'key_env': f[1], 'default_model': f[2], 'key_url': f[3]}
        break
    return out


def load_models():
    out = []
    for path in (os.path.join(REPO, 'models.txt'),
                 os.path.expanduser('~/claude-build/models.txt')):
        if not os.path.isfile(path):
            continue
        for line in open(path, encoding='utf-8'):
            s = line.rstrip('\n')
            if not s.strip() or s.lstrip().startswith('#'):
                continue
            f = [x.strip() for x in s.split('|')]
            if f and f[0]:
                f += [''] * (7 - len(f))
                out.append({'id': f[0], 'provider': f[4], 'base_url': f[5],
                            'flags': f[6].lower()})
        break
    return out


def redact(text, secret):
    if not secret:
        return text
    text = text.replace(secret, '***')
    return re.sub(r'(sk|key|token)[-_][A-Za-z0-9._-]{8,}', r'\1-***', text, flags=re.I)


class Result:
    def __init__(self):
        self.ok = 0
        self.bad = 0

    def check(self, cond, label, extra=''):
        if cond:
            self.ok += 1
            print('  ✅ ' + label)
        else:
            self.bad += 1
            print('  ❌ ' + label + (('  ← ' + str(extra)) if extra else ''))


def post(url, key, payload, timeout=60):
    """curl -K：配置走 stdin，key 不进 ps、不进参数。"""
    cfg = 'url = "%s"\n' % url
    cfg += 'header = "Authorization: Bearer %s"\n' % key
    cfg += 'header = "content-type: application/json"\n'
    cfg += 'data = %s\n' % json.dumps(json.dumps(payload))  # curl -K 的 data = "…json…"
    cfg += 'silent\n'
    cfg += 'max-time = "%d"\n' % timeout
    # -w 走命令行参数（不含秘密），配置里只放 url/header/data —— curl 的配置文件
    # 对 % 和引号的转义很挑剔，能不进配置的就不进。
    p = subprocess.run(['curl', '-K', '-', '-w', '\n%{http_code}'],
                       input=cfg, capture_output=True, text=True)
    body, _, code = p.stdout.rpartition('\n')
    try:
        parsed = json.loads(body) if body.strip() else None
    except Exception:
        parsed = None
    return code.strip(), parsed, body


def main():
    provs = load_providers()
    models = load_models()
    name = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('CLAUDE_PROVIDER', 'deepseek')
    if name not in provs:
        print('未知厂商 %r。可选：%s' % (name, ', '.join(provs)))
        return 2
    info = provs[name]
    key = os.environ.get(info['key_env'], '')
    if not key:
        print('环境变量 %s 是空的。先 export 再跑，例如：\n'
              '    export %s=<粘贴密钥>\n    python3 scripts/live-check.py %s'
              % (info['key_env'], info['key_env'], name))
        print('\n密钥获取页面：%s' % info['key_url'])
        return 2

    model = info['default_model']
    base = ''
    for m in models:
        if m['id'] == model:
            base = m['base_url']
            break
    if not base:
        print('models.txt 里找不到 %s 的 base_url' % model)
        return 2
    url = os.environ.get('LIVE_CHECK_BASE_URL') or (base.rstrip('/') + '/chat/completions')
    r = Result()
    print('厂商: %s   模型: %s   端点: %s' % (name, model, url))
    print('（key 只从 %s 读取，不打印、不落盘）\n' % info['key_env'])

    # ---- 1. 最小对话
    sys_payload = {'model': model, 'max_tokens': 16,
                   'messages': [{'role': 'user', 'content': '只回复两个字：可以'}]}
    code, js, raw = post(url, key, sys_payload)
    js = js or {}
    r.check(code == '200', '普通对话 HTTP 200', 'HTTP %s: %s' % (code, redact(raw[:200], key)))
    if code != '200':
        print('\n后面的测试跳过（鉴权或端点就没通）。')
        print('结论: %d 通过 / %d 失败' % (r.ok, r.bad))
        return 1
    msg = (js.get('choices') or [{}])[0].get('message') or {}
    r.check(bool((msg.get('content') or '').strip()), '模型返回了文本内容',
            redact(str(msg)[:200], key))

    # ---- 2. 工具定义 → 是否返回 tool_calls
    tool = {
        'type': 'function',
        'function': {
            'name': 'read_file',
            'description': '读取一个文件的文本内容',
            'parameters': {
                'type': 'object',
                'properties': {'path': {'type': 'string', 'description': '文件路径'}},
                'required': ['path'],
            },
        },
    }
    tool_payload = {
        'model': model, 'max_tokens': 64,
        'messages': [{'role': 'user',
                      'content': '请用 read_file 工具读取 /tmp/demo.txt，不要直接回答内容。'}],
        'tools': [tool],
    }
    code2, js2, raw2 = post(url, key, tool_payload)
    js2 = js2 or {}
    r.check(code2 == '200', '带 tools 的请求 HTTP 200（说明该模型收这个 schema）',
            'HTTP %s: %s' % (code2, redact(raw2[:300], key)))
    calls = []
    if code2 == '200':
        m2 = (js2.get('choices') or [{}])[0].get('message') or {}
        calls = m2.get('tool_calls') or []
        r.check(bool(calls), '模型返回了 tool_calls（函数调用可用）',
                redact(str(m2)[:300], key))

    # ---- 3. role:tool 回传 → 能否拿到最终回答
    if calls:
        c = calls[0]
        fn = c.get('function') or {}
        r.check(bool(c.get('id')), 'tool_call 带 id（不给我就没法回传）', redact(str(c)[:200], key))
        r.check(isinstance(fn.get('arguments'), str), 'arguments 是 JSON 字符串',
                type(fn.get('arguments')).__name__)
        try:
            json.loads(fn.get('arguments') or '{}')
            r.check(True, 'arguments 能被 JSON 解析')
        except Exception as e:
            r.check(False, 'arguments 能被 JSON 解析', redact(str(e), key))
        m2 = (js2.get('choices') or [{}])[0].get('message') or {}
        assistant_msg = {'role': 'assistant', 'content': m2.get('content') or '',
                         'tool_calls': calls}
        round2 = {
            'model': model, 'max_tokens': 64,
            'messages': tool_payload['messages'] + [
                assistant_msg,
                {'role': 'tool', 'tool_call_id': c.get('id'), 'content': 'demo 内容：hello'},
            ],
            'tools': [tool],
        }
        code3, js3, raw3 = post(url, key, round2)
        js3 = js3 or {}
        r.check(code3 == '200', 'tool 结果回传 HTTP 200（协议往返闭合）',
                'HTTP %s: %s' % (code3, redact(raw3[:300], key)))
        if code3 == '200':
            m3 = (js3.get('choices') or [{}])[0].get('message') or {}
            r.check(bool((m3.get('content') or '').strip()),
                    '拿到基于工具结果的最终回答', redact(str(m3)[:200], key))

    # ---- 4. reasoning_content 是否被我们漏回传
    round2 = locals().get('round2')
    r.check('reasoning_content' not in json.dumps(round2 if calls else tool_payload),
            '请求体里不含 reasoning_content（回传会被某些厂商 400）')

    print('\n结论: %d 通过 / %d 失败' % (r.ok, r.bad))
    if r.bad:
        print('把上面 ❌ 的几行发我就行 —— 里面不含 key。')
    else:
        print('这条链路对 %s 是真的通的。把这段输出发我即可。' % name)
    return 0 if r.bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
