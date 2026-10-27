#!/usr/bin/env python3
"""scripts/test-gui-recursion.py —— GUI 里「函数无条件调用自己」的静态卡口

为什么需要：
    `_pointing_cursor()` 曾经长这样：

        return _pointing_cursor() if sys.platform == "darwin" else "hand2"

    在 macOS 上它调用自己 → RecursionError → **双击 app 启动即崩溃**，而且
    Linux 上永远复现不了（Linux 走 else 分支）。这类「只在某个平台炸」的
    自递归，跑不起来就发现不了，只能静态查。

做的事：
    1. 用 ast 扫 gui/advisor_gui.py，找出「函数体里直接调用自己、且没有任何
       可以提前返回的分支」的函数 —— 那就是必然无限递归；
    2. 单独断言 _pointing_cursor 的 darwin 分支返回的是字符串而不是自调用。

只覆盖这一个文件里能静态看出来的形态（不追跨文件调用、不追间接递归）。
运行：python3 scripts/test-gui-recursion.py
"""

import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
GUI = os.path.join(REPO, 'gui', 'advisor_gui.py')

results = []


def check(name, ok, detail=None):
    results.append((name, ok))
    print(('  ok    ' if ok else '  FAIL  ') + name
          + ((' | ' + str(detail)) if detail and not ok else ''))
    if not ok:
        print('::error::GUI 递归检查失败: %s%s'
              % (name, (' | 细节: ' + str(detail)) if detail else ''))


def calls_itself(node, fname):
    """函数体里是否有对自己名字的调用（不含属性调用 obj.fname）。"""
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name):
            if sub.func.id == fname:
                return True
    return False


def has_early_return(node, fname):
    """函数里是否存在「不带自调用」的 return —— 有的话至少不是必然无限递归。"""
    for sub in ast.walk(node):
        if isinstance(sub, ast.Return) and sub.value is not None:
            if not (isinstance(sub.value, ast.Call)
                    and isinstance(sub.value.func, ast.Name)
                    and sub.value.func.id == fname):
                return True
    return False


def main():
    if not os.path.exists(GUI):
        check('gui/advisor_gui.py 存在', False, GUI)
        return finish()
    check('gui/advisor_gui.py 存在', True)

    with open(GUI, encoding='utf-8') as f:
        src = f.read()
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        check('gui/advisor_gui.py 语法正确', False, e)
        return finish()
    check('gui/advisor_gui.py 语法正确', True)

    funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
    check('能解析到函数定义', len(funcs) > 10, '只有 %d 个函数' % len(funcs))

    # ---- 1. 全局：找出必然无限递归的函数
    self_recursive = []
    for name, node in funcs.items():
        if calls_itself(node, name) and not has_early_return(node, name):
            self_recursive.append(name)
    check('没有「必然无限递归」的函数（某平台启动即崩的那种）',
          not self_recursive, '可疑函数: %s' % (self_recursive or ''))

    # ---- 2. 点名：上次崩在 _pointing_cursor
    fn = funcs.get('_pointing_cursor')
    check('_pointing_cursor 存在', fn is not None)
    if fn:
        body_src = ast.get_source_segment(src, fn) or ''
        check('_pointing_cursor 不调用自己', not calls_itself(fn, '_pointing_cursor'),
              body_src[:120])
        check('darwin 分支返回字符串 pointinghand（不是自调用）',
              '"pointinghand"' in body_src or "'pointinghand'" in body_src,
              body_src[:160])
        check('非 darwin 仍走 hand2', 'hand2' in body_src, body_src[:160])

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
