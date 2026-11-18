#!/bin/sh
# 窓割りをビルドして「アプリケーション」フォルダに入れ、起動する。
# 使い方: GitHub Desktop の「Repository → Open in Terminal」で開いたターミナルで
#   sh mac-window/scripts/install.sh
set -e
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

# クリップ棚で Apple ID の署名を設定済みなら、同じチームで署名する（許可が外れなくなる）
if [ ! -f Config/Local.xcconfig ] && [ -f ../mac-clipboard/Config/Local.xcconfig ]; then
  sed -e 's/CLIP_/MADO_/g' ../mac-clipboard/Config/Local.xcconfig > Config/Local.xcconfig
  echo "▶ クリップ棚と同じ署名の設定を使います"
fi

echo "▶ ビルドしています（1〜2分）…"
xcodebuild -project MadoWari.xcodeproj -scheme MadoWari -configuration Release \
  -derivedDataPath build -quiet build

echo "▶ 動いている窓割りを終了します"
osascript -e 'tell application id "io.github.skmax3.madowari" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x MadoWari >/dev/null 2>&1 || true

# Apple ID で署名していない場合、入れ直すと前のアクセシビリティの許可は無効になる（設定画面ではオンに見えるのに効かない）。
# 古い許可を消しておき、新しく許可し直せるようにする
if [ ! -f Config/Local.xcconfig ]; then
  tccutil reset Accessibility io.github.skmax3.madowari >/dev/null 2>&1 || true
  NEED_TRUST=1
fi

echo "▶ アプリケーションフォルダに入れます"
rm -rf /Applications/MadoWari.app
cp -R build/Build/Products/Release/MadoWari.app /Applications/

# メニューの「最新版にアップデート…」がこのリポジトリの場所を分かるように記録する
defaults write io.github.skmax3.madowari repoPath "$(cd .. && pwd)"

open /Applications/MadoWari.app
echo "✅ 完了。メニューバーのアイコン（縦に割った四角）から「ログイン時に起動」をオンにしてください。"
if [ -n "$NEED_TRUST" ]; then
  echo ""
  echo "⚠️  アクセシビリティの許可をやり直す必要があります（ウィンドウを動かすのに必要）。"
  echo "   出てくる案内に従って、システム設定で MadoWari をオンにしてください。"
  echo "   （毎回これが必要なのは、Apple ID で署名していないためです。sh mac-window/scripts/setup-signing.sh で解消できます）"
fi
