#!/bin/bash
# scripts/doctor-macos.sh —— 双击 Advisor.app 打不开时，用它定位真实原因
#
# 为什么需要它：从 Finder 双击启动时，程序的标准错误没有地方显示，
# 失败了就是「弹一下就没了」或者干脆没反应。同一个 .app 在终端里直接跑
# 就能看到 traceback。这个脚本把「终端里看不出来的那部分」逐条查一遍：
#   1. 包结构是否自洽（可执行文件在不在、有没有执行位、plist 对不对）
#   2. Gatekeeper / 隔离属性有没有拦（未签名 + quarantined 是常见拦截原因）
#   3. 依赖是否齐（alias 模式的 app 依赖本机 python3 和源码目录，Tk 缺了就静默退出）
#
# 用法：bash scripts/doctor-macos.sh
# 注意：只读检查，不改任何东西；每条都打印实际命令输出，不猜。

set -o pipefail

APP="${ADVISOR_APP:-$HOME/Applications/Advisor.app}"
SRC_DIR="$HOME/claude-build"
BAD=0

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  问题  %s\n' "$*"; BAD=$((BAD + 1)); }
info() { printf '        %s\n' "$*"; }

say "Advisor.app 双击失败诊断"
say "系统: $(sw_vers -productVersion 2>/dev/null || echo '非 macOS') / $(uname -m)"
say "包路径: $APP"

# ---------------------------------------------------------------- 1. 包结构
hdr "1. 包结构"
if [ ! -d "$APP" ]; then
  bad "找不到 $APP —— 先跑一次 setup.sh（它在第 6 步生成这个 app）"
else
  ok "包存在"
  EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)"
  [ -n "$EXEC_NAME" ] || EXEC_NAME="Advisor"
  EXEC="$APP/Contents/MacOS/$EXEC_NAME"
  if [ -f "$EXEC" ]; then
    ok "可执行文件存在: Contents/MacOS/$EXEC_NAME"
    if [ -x "$EXEC" ]; then ok "有执行权限"; else
      bad "可执行文件没有执行权限 —— 双击必然什么都不发生"
      info "修: chmod +x \"$EXEC\""
    fi
  else
    bad "Info.plist 说可执行文件是 $EXEC_NAME，但 Contents/MacOS/$EXEC_NAME 不存在"
  fi

  if plutil -lint "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    ok "Info.plist 格式合法"
  else
    bad "Info.plist 格式坏了"
    info "修: 重跑 setup.sh（这一步是它生成的）"
  fi

  # alias 模式的 py2app 产物：没有内嵌解释器，靠本机 python3 + 源码目录
  if [ -L "$APP/Contents/MacOS/$EXEC_NAME" ] || ! [ -d "$APP/Contents/Frameworks" ]; then
    info "这是 alias 模式构建（py2app -A）：依赖本机 python3 和 $SRC_DIR，不能拷到别的机器跑"
  else
    info "看起来是自带解释器的独立构建"
  fi
fi

# ---------------------------------------------------------------- 2. 依赖
hdr "2. 依赖（alias 模式最常在这里断）"
if [ -f "$SRC_DIR/advisor_gui.py" ]; then
  ok "GUI 源码在: $SRC_DIR/advisor_gui.py"
else
  bad "缺少 $SRC_DIR/advisor_gui.py —— alias 模式的 app 会立刻退出（Finder 里就是「打不开」）"
  info "修: 重跑 setup.sh（它会把源码铺到 $SRC_DIR）"
fi

for py in "$(command -v python3 2>/dev/null)" /usr/bin/python3 \
          /Library/Frameworks/Python.framework/Versions/3.10/bin/python3; do
  [ -n "$py" ] && [ -x "$py" ] || continue
  ver="$("$py" -V 2>&1 | head -1)"
  if "$py" -c 'import tkinter' >/dev/null 2>&1; then
    ok "$ver ($py) 能用 tkinter"
  else
    bad "$ver ($py) 缺 tkinter —— 图形界面起不来，双击就静默退出"
    info "修: 用 python.org 的 python3（自带 Tk）；Homebrew 的要另装 python-tk"
  fi
done

# ---------------------------------------------------------------- 3. 系统拦截
hdr "3. 系统拦截"
Q="$(xattr -p com.apple.quarantine "$APP" 2>/dev/null)"
if [ -n "$Q" ]; then
  bad "带隔离属性（下载来的包会被打上）: $Q"
  info "修: xattr -dr com.apple.quarantine \"$APP\""
else
  ok "没有隔离属性（不是下载来的）"
fi

SIG="$(codesign -dv --verbose=2 "$APP" 2>&1 | tr '\n' ' ')"
case "$SIG" in
  *"Signature=adhoc"*) ok "是 ad-hoc 签名" ;;
  *"Authority="*)      ok "有签名: $(printf '%s' "$SIG" | sed -n 's/.*Authority=\([^ ]*\).*/\1/p')" ;;
  *)                   info "未签名（本项目既定：不买 Developer ID，靠右键打开）" ;;
esac

if spctl -a -vv "$APP" >/dev/null 2>&1; then
  ok "Gatekeeper 放行"
else
  info "Gatekeeper 会拦（未签名包的正常结果）—— 处理方式见下面「怎么打开」"
fi

# ---------------------------------------------------------------- 4. 真跑一次
hdr "4. 真跑一次（这一步的输出就是 Finder 里看不到的东西）"
if [ -x "$APP/Contents/MacOS/${EXEC_NAME:-Advisor}" ]; then
  OUT="$("$APP/Contents/MacOS/${EXEC_NAME:-Advisor}" 2>&1 &
        pid=$!
        sleep 3
        if kill -0 "$pid" 2>/dev/null; then echo '__STAYED_ALIVE__'; kill "$pid" 2>/dev/null; fi
        wait "$pid" 2>/dev/null)"
  printf '%s\n' "$OUT" | sed 's/^/        /'
  case "$OUT" in
    *__STAYED_ALIVE__*) ok "进程活着 —— 说明能启动，双击打不开是系统层拦的（看第 3 节）" ;;
    *) bad "进程没撑过 3 秒就退了 —— 上面的输出就是原因" ;;
  esac
else
  info "没有可执行文件，跳过"
fi

hdr "5. 最近的崩溃日志（如果有）"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
FOUND=0
for f in "$CRASH_DIR"/Advisor*.ips "$CRASH_DIR"/Advisor*.crash; do
  [ -f "$f" ] || continue
  FOUND=1
  info "$(basename "$f")"
  head -c 600 "$f" | sed 's/^/        /'
  printf '\n'
done
[ "$FOUND" = 0 ] && ok "没有 Advisor 的崩溃日志"

say ""
if [ "$BAD" = 0 ]; then
  say "结论：没查到明确问题。手动试一次，并把第 4 节的输出发我。"
else
  say "结论：发现 $BAD 处问题，按上面每条的「修」处理即可。"
fi
say ""
say "怎么打开（未签名包的常规路径）："
say "  · macOS 13 及更早：Finder 里右键 → 打开 → 再点「打开」"
say "  · macOS 14/15+：系统设置 → 隐私与安全性 → 拉到底 → 「仍要打开」"
say "  · 等不及就用终端直接跑：\"$APP/Contents/MacOS/${EXEC_NAME:-Advisor}\""
