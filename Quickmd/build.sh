#!/bin/bash
# 把 SwiftPM 产物打包成可直接双击运行的 .app（纯 Command Line Tools，无需 Xcode）。
# 注意：
#  - --disable-sandbox 绕过受限环境里 SwiftPM 自身 sandbox-exec 被拒的问题。
#  - 需要把 SPM 生成的资源包（*_Quickmd.bundle）一并拷进 .app，否则 editor.html 找不到。
#
# 图标选择：用 ICON 环境变量指定 1 / 2 / 3，默认 1（终端绿）。
#   ./build.sh          -> 用 1 号图标
#   ICON=2 ./build.sh   -> 用 2 号图标（蓝图靛蓝）
#   ICON=3 ./build.sh   -> 用 3 号图标（像素琥珀）
set -e
cd "$(dirname "$0")"
swift build -c release --disable-sandbox

ICON="${ICON:-1}"
ICON_SRC="../assets/icons/Quickmd-${ICON}.icns"
[ -f "$ICON_SRC" ] || ICON_SRC="../assets/icons/Quickmd.icns"

APP="Quickmd.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Quickmd "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
chmod +x "$APP/Contents/MacOS/Quickmd"

# 应用图标
cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

# 拷贝 SwiftPM 资源包（editor.html / editor.js / editor.css）
for b in .build/release/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
done

codesign --force --sign - "$APP" 2>/dev/null || true
echo "已生成 $APP (icon #${ICON})"
echo "运行：open $APP"
