#!/bin/bash
# scripts/check-mirror-drift.sh —— 单向镜像的「反拉保护」
#
# 背景：main 被强推镜像到 Gitee（`git push --all --force` + `--tags --force`）。
# 如果有人在 Gitee 侧直接提交/tag，下一次同步会**无声覆盖**它们 —— 不报错、不可恢复。
# 这个脚本在推之前先看一眼镜像仓：只要发现「推上去会覆盖掉对方独有的东西」就停下，
# 让人先把改动反拉回来。
#
# 用法：
#   scripts/check-mirror-drift.sh <镜像仓 URL> [--branch <本地分支>]
#
# 退出码：
#   0  安全，可以推
#   2  发现会被覆盖的内容 → 不要推（打印怎么反拉）
#   1  读取镜像失败（网络/凭据）→ 也不要盲目推
#
# 只拦「真的会丢东西」的情况，避免误报把同步卡死：
#   · 镜像上同名分支有我们没有的提交        → 拦（--force 会覆盖它）
#   · 镜像上同名 tag 指向不同的提交          → 拦（--tags --force 会覆盖它）
#   · 镜像上还有我们完全没有的分支（如网页建的 master）→ 只提示，不拦
#     （`--all` 不会删除它们，所以谈不上丢失）
#   · 镜像上只有我们没有的 tag（不同名）     → 只提示，不拦（不会被覆盖）
#
# 覆盖范围（别当成万能）：
#   · 只比较分支与 tag 的提交关系，不比较文件内容；
#   · 镜像仓若被回滚到更早的提交（是我们历史的祖先），不算漂移 —— 那种情况强推是预期的收敛。

set -o pipefail

URL="${1:-}"
shift || true
BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$URL" ]; then
  echo "用法: scripts/check-mirror-drift.sh <镜像仓 URL> [--branch <本地分支>]" >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "不在 git 仓库里" >&2
  exit 1
}
cd "$ROOT" || exit 1

[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD)"
say() { printf '%s\n' "$*"; }

BLOCKED=0
NOTES=""

# ---------------------------------------------------------------- 读取镜像
MIRROR_TMP="refs/advisor-mirror-check"
git for-each-ref --format='%(refname)' "$MIRROR_TMP" 2>/dev/null | while IFS= read -r r; do
  git update-ref -d "$r"
done

if ! git fetch --no-tags --quiet "$URL" "+refs/heads/*:$MIRROR_TMP/heads/*" 2>/tmp/advisor-mirror-fetch.log; then
  say "✗ 读不到镜像仓（网络或凭据问题），为安全起见不推："
  sed 's/^/    /' /tmp/advisor-mirror-fetch.log | head -10
  exit 1
fi

# ---------------------------------------------------------------- 分支比较
# 注意用 lstrip=3：refs/advisor-mirror-check/heads/main → main
# （strip=2 会得到 heads/main，分支名对不上，比较就全被跳过 —— 这个坑踩过一次）
MIRROR_BRANCHES="$(git for-each-ref --format='%(refname:lstrip=3)' "$MIRROR_TMP/heads" 2>/dev/null)"

for mb in $MIRROR_BRANCHES; do
  mref="$MIRROR_TMP/heads/$mb"
  if git show-ref --verify --quiet "refs/heads/$mb"; then
    # 同名分支：镜像上是否有我们没有的提交？
    extra="$(git rev-list --count "refs/heads/$mb..$mref" 2>/dev/null || echo 0)"
    if [ "${extra:-0}" -gt 0 ]; then
      # ★ 关键：反拉回来通常走 cherry-pick，补丁内容一样但 SHA 不同。
      #   只比 SHA 的话，反拉之后依然被判定为漂移，同步就永远卡住
      #   —— 而「先反拉再同步」正是本脚本自己建议的恢复路径。
      #   所以用 `git cherry` 比 patch-id：镜像上的提交若已有等价补丁在本地，
      #   就算已收敛（这类提交强推覆盖掉不会丢任何改动）。
      unapplied="$(git cherry "refs/heads/$mb" "$mref" 2>/dev/null | grep -c '^+')"
      applied="$(git cherry "refs/heads/$mb" "$mref" 2>/dev/null | grep -c '^-')"
      if [ "${unapplied:-0}" -gt 0 ]; then
        BLOCKED=1
        say "✗ 镜像分支 '$mb' 上有 $unapplied 个提交未以任何形式进入本地 '$mb' —— 强推会把它们覆盖掉："
        git cherry "refs/heads/$mb" "$mref" 2>/dev/null | grep '^+' | head -5 | sed 's/^/    /'
        MIRROR_DRIFT_BRANCH="$mb"
      elif [ "${applied:-0}" -gt 0 ]; then
        NOTES="$NOTES
    · 镜像分支 '$mb' 上的 $applied 个提交已有等价补丁在本地（cherry-pick 过），同步会收敛"
      fi
    fi
  else
    # 镜像独有的分支：强推不会删除它，只提示
    NOTES="$NOTES
    · 镜像上还有本地没有的分支：$mb（不会被删除，但也不会被更新）"
  fi
done

# ---------------------------------------------------------------- tag 比较
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # ls-remote 的输出是「<sha>\t<ref>」（制表符分隔），按空格切会把名和 sha 弄反
  tsha="${line%%[[:space:]]*}"
  tname="${line##*[[:space:]]}"
  local_sha="$(git rev-parse -q --verify "refs/tags/$tname" 2>/dev/null || true)"
  if [ -z "$local_sha" ]; then
    NOTES="$NOTES
    · 镜像上还有本地没有的 tag：$tname（不同名，不会被覆盖）"
  elif [ "$local_sha" != "$tsha" ]; then
    # 同名 tag 但不指向同一提交：--tags --force 会覆盖
    # 如果镜像那个提交已经被本地某个 ref 包含（例如是我们历史的祖先），覆盖是预期的
    if git cat-file -e "$tsha^{commit}" 2>/dev/null && git merge-base --is-ancestor "$tsha" "$BRANCH" 2>/dev/null; then
      NOTES="$NOTES
    · 镜像 tag $tname 指向较旧的提交（在本分支历史里），同步会把它更新到最新"
    else
      BLOCKED=1
      say "✗ 镜像 tag '$tname' 指向的提交不在本地历史里（$tsha）—— 同步会覆盖它"
    fi
  fi
done < <(git ls-remote --tags "$URL" 2>/dev/null | sed 's|refs/tags/||' | grep -v '\^{}')

# ---------------------------------------------------------------- 清理临时 ref
git for-each-ref --format='%(refname)' "$MIRROR_TMP" 2>/dev/null | while IFS= read -r r; do
  git update-ref -d "$r"
done

if [ -n "$NOTES" ]; then
  say "提示（不拦，仅供参考）：$NOTES"
fi

if [ "$BLOCKED" = 1 ]; then
  say ""
  say "镜像侧有会被覆盖的内容，已中止同步。先把它们反拉回来："
  if [ -n "${MIRROR_DRIFT_BRANCH:-}" ]; then
    say "  git remote add gitee $URL            # 只需要一次"
    say "  git fetch gitee"
    say "  git log --oneline $BRANCH..gitee/$MIRROR_DRIFT_BRANCH"
    say "  git cherry-pick <需要的提交>          # 或者 git merge gitee/$MIRROR_DRIFT_BRANCH"
    say "  git push origin main                 # 再同步回去"
  else
    say "  git fetch gitee --tags && git tag -l  # 确认 tag 指向后手工对齐"
  fi
  say ""
  say "确认镜像侧那些内容可以丢弃时，用 workflow_dispatch 的 force 选项重跑同步。"
  exit 2
fi

say "镜像无漂移（分支与 tag 都不会覆盖镜像侧独有的内容），可以推。"
exit 0
