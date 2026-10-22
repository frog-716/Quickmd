#!/bin/bash
# 生成 macOS .icns 图标（从 tools/icon-generator.swift 绘制，不依赖 AI）
# 用法：./tools/make-icons.sh <设计号 1|2|3>
# 产物：assets/icons/Quickmd-<设计号>.icns
set -e
cd "$(dirname "$0")/.."

DESIGN="${1:-1}"
NAME="Quickmd-${DESIGN}"
OUT="assets/icons"
GEN="/tmp/quickmd-icongen"

[ -x "$GEN" ] || swiftc tools/icon-generator.swift -o "$GEN"

rm -rf "$OUT/${NAME}.iconset"
mkdir -p "$OUT/${NAME}.iconset"

# iconset 需要这些尺寸：@1x 与 @2x
render() { "$GEN" "$DESIGN" "$2" "$OUT/${NAME}.iconset/$1"; }

render icon_16x16.png      16
render icon_16x16@2x.png   32
render icon_32x32.png      32
render icon_32x32@2x.png   64
render icon_128x128.png    128
render icon_128x128@2x.png 256
render icon_256x256.png    256
render icon_256x256@2x.png 512
render icon_512x512.png    512
render icon_512x512@2x.png 1024

iconutil -c icns "$OUT/${NAME}.iconset" -o "$OUT/${NAME}.icns"
rm -rf "$OUT/${NAME}.iconset"
echo "已生成 $OUT/${NAME}.icns"
