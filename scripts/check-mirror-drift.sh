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
#   · 镜像上同名分支有未进入本地的提交        → 拦（--force 会覆盖它）
#     ★ 用 patch-id 判定「未进入」：cherry-pick 回来的等价补丁算已收敛，
#       否则按本脚本建议的方式修复完，同步还是永久卡着。
#   · 镜像上同名 tag 指向本地历史之外的提交    → 拦（--tags --force 会覆盖它）
#   · 镜像上还有我们完全没有的分支（如网页建的 master）→ 只提示，不拦
#     （`--all` 不会删除它们，谈不上丢失）
#   · 镜像上只有我们没有的 tag（不同名）       → 只提示，不拦（不会被覆盖）
#   · 镜像落后于本地                          → 放行（强推是预期收敛）
#
# 实现上的两个刻意选择（都被真实故障教育过）：
#   1. 分支/tag 名单一律来自 `git ls-remote`，再按分支**单独** fetch；
#      不依赖 for-each-ref 的 lstrip 之类格式特性 —— 不同 git 版本行为不一致，
#      在 macOS runner 上就因此探测不到分支，提示是空的、比较全被跳过。
#   2. 提示文案累积到临时文件而不是变量，并明确区分「阻塞」与「仅提示」；
#      子 shell 与多行变量的行为差异踩过坑。
#
# 覆盖范围（别当成万能）：
#   · 只比较分支与 tag 的提交关系，不比较文件内容；
#   · 镜像被回滚到更早的提交（本地历史的祖先）不算漂移 —— 强推是预期的收敛；
#   · 只看 SHA 与 patch-id，不检查被覆盖的提交里是否夹带了别的东西。

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

TMP_REF="refs/advisor-mirror-check"
NOTES_FILE="$(mktemp -t advisor-mirror-notes.XXXXXX)" || exit 1
FETCH_LOG="$(mktemp -t advisor-mirror-fetch.XXXXXX)" || exit 1
cleanup() {
  rm -f "$NOTES_FILE" "$FETCH_LOG"
  git for-each-ref --format='%(refname)' "$TMP_REF" 2>/dev/null \
    | while IFS= read -r r; do git update-ref -d "$r" 2>/dev/null; done
  git update-ref -d "$TMP_REF/branch" 2>/dev/null
  return 0
}
trap cleanup EXIT

note()  { printf 'NOTE %s\n' "$*" >> "$NOTES_FILE"; }
block() { printf 'BLOCK %s\n' "$*" >> "$NOTES_FILE"; }

# ---------------------------------------------------------------- 读取镜像
HEADS="$(git ls-remote --heads "$URL" 2>"$FETCH_LOG")"
HEADS_RC=$?
if [ "$HEADS_RC" != 0 ] || { [ -z "$HEADS" ] && [ -s "$FETCH_LOG" ]; }; then
  say "✗ 读不到镜像仓（网络或凭据问题），为安全起见不推："
  sed 's/^/    /' "$FETCH_LOG" | head -10
  exit 1
fi

# ---------------------------------------------------------------- tag 名单（供调试与比较）
TAGS="$(git ls-remote --tags "$URL" 2>/dev/null | grep -v '\^{}')"

# ---------------------------------------------------------------- 分支比较
# 再抓一份（来源二）：批量 fetch 后从 refs 里读名字。
# 某些平台上 ls-remote 与 for-each-ref 只有其一是可靠的，取并集最稳。
git fetch --no-tags --quiet "$URL" "+refs/heads/*:$TMP_REF/heads/*" 2>>"$FETCH_LOG" || true
EXTRA_HEADS="$(git for-each-ref --format='%(refname:lstrip=3)' "$TMP_REF/heads" 2>/dev/null)"

# 名字先算好再打：别把 awk/sed 塞进双引号里（`$2` 会被 bash 先展开，整段语法崩）
HEADS_NAMES="$(printf '%s\n' "$HEADS" | sed 's|.*refs/heads/||')"
TAGS_NAMES="$(printf '%s\n' "$TAGS" | sed 's|.*refs/tags/||')"
ALL_HEADS="$(printf '%s\n%s\n' "$HEADS_NAMES" "$EXTRA_HEADS" | grep -v '^$' | sort -u)"

if [ -n "${ADVISOR_MIRROR_DEBUG:-}" ]; then
  printf 'DEBUG lsremote_heads=[%s]\n' "$(printf '%s' "$HEADS_NAMES" | tr '\n' ' ')" >&2
  printf 'DEBUG foreach_heads=[%s]\n' "$(printf '%s' "$EXTRA_HEADS" | tr '\n' ' ')" >&2
  printf 'DEBUG tags=[%s]\n' "$(printf '%s' "$TAGS_NAMES" | tr '\n' ' ')" >&2
  printf 'DEBUG all_heads=[%s]\n' "$(printf '%s' "$ALL_HEADS" | tr '\n' ' ')" >&2
fi

printf '%s\n' "$ALL_HEADS" | while IFS= read -r mb; do
  [ -n "$mb" ] || continue

  if ! git show-ref --verify --quiet "refs/heads/$mb"; then
    # 镜像独有的分支：--all 不会删除它，只提示
    note "镜像上还有本地没有的分支：$mb（不会被删除，但也不会被更新）"
    continue
  fi

  git update-ref -d "$TMP_REF/branch" 2>/dev/null
  if ! git fetch --no-tags --quiet "$URL" "+refs/heads/$mb:$TMP_REF/branch" 2>>"$FETCH_LOG"; then
    printf 'FETCHFAIL\n' >> "$NOTES_FILE"
    continue
  fi

  # 镜像上这个分支有、本地没有的提交里，哪些补丁在本地不存在（= 真的会丢）
  unapplied="$(git cherry "refs/heads/$mb" "$TMP_REF/branch" 2>/dev/null | grep -c '^+')"
  applied="$(git cherry "refs/heads/$mb" "$TMP_REF/branch" 2>/dev/null | grep -c '^-')"

  if [ "${unapplied:-0}" -gt 0 ]; then
    block "镜像分支 [$mb] 上有 $unapplied 个提交未进入本地 —— 强推会覆盖它们"
    git cherry "refs/heads/$mb" "$TMP_REF/branch" 2>/dev/null \
      | grep '^+' | head -5 | awk '{print "  提交 " $2}' >> "$NOTES_FILE"
  elif [ "${applied:-0}" -gt 0 ]; then
    note "镜像分支 [$mb] 上的 $applied 个提交已有等价补丁在本地（cherry-pick 过），同步会收敛"
  fi
done

# ---------------------------------------------------------------- tag 比较
TAGS="$(git ls-remote --tags "$URL" 2>/dev/null | grep -v '\^{}')"
if [ -n "$TAGS" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tsha="${line%%[[:space:]]*}"
    tname="${line##*[[:space:]]}"
    tname="${tname#refs/tags/}"
    [ -n "$tname" ] || continue
    local_sha="$(git rev-parse -q --verify "refs/tags/$tname" 2>/dev/null || true)"
    if [ -z "$local_sha" ]; then
      note "镜像上还有本地没有的 tag：$tname（不同名，不会被覆盖）"
    elif [ "$local_sha" != "$tsha" ]; then
      if git cat-file -e "$tsha^{commit}" 2>/dev/null \
         && git merge-base --is-ancestor "$tsha" "$BRANCH" 2>/dev/null; then
        note "镜像 tag $tname 指向较旧的提交（在本分支历史里），同步会把它更新到最新"
      else
        block "镜像 tag [$tname] 指向的提交不在本地历史里 —— 同步会覆盖它"
      fi
    fi
  done <<EOF
$TAGS
EOF
fi

# ---------------------------------------------------------------- 汇总
# 全部用 bash 内建读文件（while read + case），不拿 grep/sed/awk 去啃临时文件：
# BSD 工具在不同 locale / 二进制判定下的行为差异已经在 macOS runner 上坑过一次。
BLOCKED=0
DRIFT_BRANCH=""
has_marker() {   # $1 = BLOCK / FETCHFAIL
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in "$1 "*) return 0 ;; "$1") return 0 ;; esac
  done < "$NOTES_FILE"
  return 1
}

while IFS= read -r l || [ -n "$l" ]; do
  case "$l" in
    BLOCK*)
      BLOCKED=1
      msg="${l#BLOCK }"
      say "✗ $msg"
      case "$msg" in
        *"分支 ["*"]"*)
          tb="${msg#*分支 [}"; DRIFT_BRANCH="${tb%%]*}" ;;
      esac
      ;;
    FETCHFAIL) BLOCKED=2 ;;
  esac
done < "$NOTES_FILE"

if [ "$BLOCKED" = 2 ]; then
  say "✗ 取镜像分支失败，为安全起见不推："
  sed 's/^/    /' "$FETCH_LOG" | head -10
  exit 1
fi

if [ "$BLOCKED" = 1 ]; then
  # 附上具体是哪几个提交
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in "   提交 "*) say "$l" ;; esac
  done < "$NOTES_FILE"
  say ""
  say "镜像侧有会被覆盖的内容，已中止同步。先把它们反拉回来："
  if [ -n "$DRIFT_BRANCH" ]; then
    say "  git remote add gitee $URL            # 只需要一次"
    say "  git fetch gitee"
    say "  git log --oneline $BRANCH..gitee/$DRIFT_BRANCH"
    say "  git cherry-pick <需要的提交>          # 或者 git merge gitee/$DRIFT_BRANCH"
    say "  git push origin main                 # 再同步回去"
    say ""
    say "  cherry-pick 回来的算「已收敛」，再次同步会自动放行（按 patch-id 判定）。"
  else
    say "  git fetch gitee --tags && git tag -l  # 确认 tag 指向后手工对齐"
  fi
  say ""
  say "确认镜像侧那些内容可以丢弃时，用 workflow_dispatch 的 force 选项重跑同步。"
  exit 2
fi

# 非阻塞提示
NOTES_SHOWN=0
while IFS= read -r l || [ -n "$l" ]; do
  case "$l" in
    "NOTE "*)
      if [ "$NOTES_SHOWN" = 0 ]; then say "提示（不拦，仅供参考）："; NOTES_SHOWN=1; fi
      say "    · ${l#NOTE }"
      ;;
  esac
done < "$NOTES_FILE"

say "镜像无漂移（分支与 tag 都不会覆盖镜像侧独有的内容），可以推。"
exit 0
