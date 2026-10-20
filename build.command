#!/bin/bash
# Pencil Test — ビルドスクリプト
# このファイルをダブルクリックすると PencilTest.app が同じフォルダに作られます。

set -e
cd "$(dirname "$0")"

APP="PencilTest.app"
BIN="$APP/Contents/MacOS/PencilTest"

echo "==> 以前のビルドを削除"
rm -rf "$APP"

echo "==> アプリバンドルを作成"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp macOS/Info.plist "$APP/Contents/Info.plist"
cp Resources/PencilTest.icns "$APP/Contents/Resources/"

echo "==> Swift をコンパイル（30秒ほどかかります）"
swiftc -O -parse-as-library macOS/PencilTest.swift Shared/FrameStore.swift Shared/MP4Exporter.swift Shared/SequenceExporter.swift -o "$BIN" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework UniformTypeIdentifiers

echo "==> 署名（カメラ許可に必要）"
codesign --force --deep --sign - "$APP"

echo ""
echo "完了しました。同じフォルダの PencilTest.app を開いてください。"
echo ""
read -n 1 -s -r -p "何かキーを押すと閉じます..."
echo ""
