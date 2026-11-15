#!/bin/sh
# クリップ棚をビルドして「アプリケーション」フォルダに入れ、起動する。
# 使い方: GitHub Desktop の「Repository → Open in Terminal」で開いたターミナルで
#   sh mac-clipboard/scripts/install.sh
set -e
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

echo "▶ ビルドしています（1〜2分）…"
xcodebuild -project ClipShelf.xcodeproj -scheme ClipShelf -configuration Release \
  -derivedDataPath build -quiet build

echo "▶ 動いているクリップ棚を終了します"
osascript -e 'tell application id "io.github.skmax3.clipshelf" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x ClipShelf >/dev/null 2>&1 || true

echo "▶ アプリケーションフォルダに入れます"
rm -rf /Applications/ClipShelf.app
cp -R build/Build/Products/Release/ClipShelf.app /Applications/

open /Applications/ClipShelf.app
echo "✅ 完了。メニューバーのアイコンから「ログイン時に起動」をオンにしてください。"
