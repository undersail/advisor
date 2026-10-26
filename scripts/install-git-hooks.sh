#!/bin/bash
# scripts/install-git-hooks.sh —— 装上仓库自带的 git hooks（每个克隆做一次）
#
# 为什么用 core.hooksPath 而不是往 .git/hooks/ 里拷贝：
#   .git/hooks/ 不在版本控制里，改了别人也拿不到、升级也不会同步。
#   指向仓库内的 scripts/hooks/ 之后，hook 本身也受 review、也能被 CI 检查。
#
# 用法：bash scripts/install-git-hooks.sh
# 卸载：git config --unset core.hooksPath

set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if [ ! -d scripts/hooks ]; then
  echo "找不到 scripts/hooks 目录 —— 请在仓库根目录执行这个脚本" >&2
  exit 1
fi

# hook 必须可执行，否则 git 会静默跳过（这种「装了等于没装」最坑）
chmod +x scripts/hooks/* 2>/dev/null || true

git config core.hooksPath scripts/hooks || {
  echo "设置 core.hooksPath 失败" >&2
  exit 1
}

echo "已启用仓库自带的 git hooks："
echo "  core.hooksPath = $(git config core.hooksPath)"
for h in scripts/hooks/*; do
  [ -f "$h" ] || continue
  printf '  %s%s\n' "$(basename "$h")" "$([ -x "$h" ] && echo '' || echo '（不可执行！）')"
done
echo ""
echo "下次 git commit 会自动跑：泄漏检查 / CRLF / 调试残留。"
echo "确需跳过：git commit --no-verify"
