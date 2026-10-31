#!/bin/bash
# release/build_standalone_app.sh
#
# 构建用于分发（放到自己站点/GitHub Release 上）的单体、自包含 Advisor.app。
# 与面向终端用户的 setup.sh 不是一回事，这是维护者工具。
#
# setup.sh 生成的 Advisor.app 是 "alias mode"(py2app -A)：每次运行都去读
# 构建机上的 ~/claude-build/advisor_gui.py，属于轻量形态。
# 它只能在同一台 Mac 上跑，所以不能用来分发。
#
# 这里则把 claude-agent.pl / models.txt 一起打进应用本体
# (Contents/Resources/)，构建出 "standalone" 版本。压成 zip 拿到任意 Mac 上，
# 即使一次都没跑过 setup.sh，双击即可运行
# (advisor_gui.py 启动时的引导页负责登记 API 密钥)。
#
# 必须在与分发目标同架构的机器上构建（二进制兼容性）。
#
# 用法: bash release/build_standalone_app.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 版本号可以用环境变量覆盖（Release 用构建从 tag 传入）。
# 未指定时沿用旧行为 0.1 —— 本地手动构建时的默认值。
VERSION="${ADVISOR_VERSION:-$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d ' \t\r\n')}"
if [ -z "$VERSION" ]; then
  echo "读不到 VERSION 文件（无法把版本号写进分发包）" >&2
  exit 1
fi
OUT_DIR="$SCRIPT_DIR/dist"
ICON_SRC="$SCRIPT_DIR/launcher/advisor.icns"

PY3="$(command -v python3 || true)"
[ -z "$PY3" ] && [ -x /Library/Frameworks/Python.framework/Versions/3.10/bin/python3 ] \
  && PY3=/Library/Frameworks/Python.framework/Versions/3.10/bin/python3
if [ -z "$PY3" ]; then
  echo "找不到 python3。" >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "正在安装 Xcode Command Line Tools（仅首次，约 190MB）..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  clt_label="$(softwareupdate -l 2>/dev/null | grep -o 'Command Line Tools[^,]*for Xcode-[0-9.]*' | tail -1)"
  [ -n "$clt_label" ] && softwareupdate -i "$clt_label" >/dev/null 2>&1
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Command Line Tools 安装失败。" >&2
    exit 1
  fi
fi

echo "正在安装 py2app / pyobjc ..."
# venv 里不能用 --user（User site-packages are not visible）。
# GitHub Actions 侧用 venv 跑，所以这里分叉，免得在那里落空。
PIP_USER_OPT="--user"
[ -n "${VIRTUAL_ENV:-}" ] && PIP_USER_OPT=""
"$PY3" -m pip install $PIP_USER_OPT --quiet py2app pyobjc-framework-Cocoa

BUILD_DIR="$SCRIPT_DIR/.standalone-app-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp "$SCRIPT_DIR/gui/advisor_gui.py" "$BUILD_DIR/advisor_gui.py"

iconfile_opt=""
[ -f "$ICON_SRC" ] && iconfile_opt="\"iconfile\": \"$ICON_SRC\","

cat > "$BUILD_DIR/setup.py" << PYEOF
from setuptools import setup

APP = ["advisor_gui.py"]
# ("", [...]) 表示放到 Contents/Resources/ 直下。advisor_gui.py 的
# _bundled_resource_dir() 就是到这里找。
DATA_FILES = [
    ("", ["$SCRIPT_DIR/agent/claude-agent.pl", "$SCRIPT_DIR/models.txt",
          "$SCRIPT_DIR/providers.txt", "$SCRIPT_DIR/VERSION"]),
    # remote/ 是 GUI 远程面板查找 wecom-ws.pl / gateway.pl 的目录。
    # 忘了打进去就会「找不到 wecom-ws.pl」（真机上出现过）。
    ("remote", ["$SCRIPT_DIR/remote/wecom-ws.pl", "$SCRIPT_DIR/remote/gateway.pl",
                "$SCRIPT_DIR/remote/notify.pl", "$SCRIPT_DIR/remote/platform.pl"]),
]
OPTIONS = {
    "argv_emulation": False,
    $iconfile_opt
    "plist": {
        "CFBundleName": "Advisor",
        "CFBundleDisplayName": "Advisor",
        "CFBundleIdentifier": "com.high-sierra-claude.advisor",
        "CFBundleVersion": "$VERSION",
        "CFBundleShortVersionString": "$VERSION",
        "NSHighResolutionCapable": True,
    },
}
setup(app=APP, data_files=DATA_FILES, options={"py2app": OPTIONS},
      setup_requires=["py2app"])
PYEOF

echo "正在构建 standalone（与 alias mode 不同，会把实体整个拷一份，首次要几分钟）..."
( cd "$BUILD_DIR" && rm -rf build dist && "$PY3" setup.py py2app )

if [ ! -d "$BUILD_DIR/dist/Advisor.app" ]; then
  echo "构建失败。请查看 $BUILD_DIR/build.log 等。" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/Advisor.app"
cp -R "$BUILD_DIR/dist/Advisor.app" "$OUT_DIR/Advisor.app"

# 首次启动时 macOS 会报「无法验证开发者」警告（因为用的是 ad-hoc 签名，
# 而不是正式的 Apple Developer ID 签名），把应对办法放在解开 zip 后一眼
# 就能看到的位置随包附上。随包附上的只有中文(主)与英文(副)两份。
# 文件名保持 ASCII —— macOS 自带的 Info-ZIP(3.0) 没有办法控制
# UTF-8 文件名标志，非 ASCII 名字在不同解压环境里会乱码
# (正文文本保持 UTF-8 没有问题)。
cp "$SCRIPT_DIR/release/ReadMe_EN.txt" "$OUT_DIR/ReadMe_EN.txt"
cp "$SCRIPT_DIR/release/ReadMe_ZH.txt" "$OUT_DIR/ReadMe_ZH.txt"

ZIP_NAME="Advisor-v${VERSION}-standalone.zip"
( cd "$OUT_DIR" && rm -f "$ZIP_NAME" && \
  zip -r -q "$ZIP_NAME" Advisor.app ReadMe_EN.txt ReadMe_ZH.txt )

echo ""
echo "完成: $OUT_DIR/$ZIP_NAME"
du -sh "$OUT_DIR/Advisor.app" "$OUT_DIR/$ZIP_NAME"
