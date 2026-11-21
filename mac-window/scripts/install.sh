#!/bin/sh
# 窓割りをビルドして「アプリケーション」フォルダに入れ、起動する。
# 使い方: GitHub Desktop の「Repository → Open in Terminal」で開いたターミナルで
#   sh mac-window/scripts/install.sh
set -e
cd "$(dirname "$0")/.."
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

# 署名の設定（Config/Local.xcconfig。Git には入らない）がなければ、自動で用意する。
# 1) 前にインストールした場所（リポジトリを取り直す前）にあればコピー
# 2) なければ、Apple Development の証明書から作る（setup-signing.sh と同じ）
if [ ! -f Config/Local.xcconfig ]; then
  here="$(cd .. && pwd)"
  for old in "$(defaults read io.github.skmax3.madowari repoPath 2>/dev/null)" "$(defaults read io.github.skmax3.clipshelf repoPath 2>/dev/null)"; do
    if [ -n "$old" ] && [ "$old" != "$here" ] && [ -f "$old/mac-window/Config/Local.xcconfig" ]; then
      cp "$old/mac-window/Config/Local.xcconfig" Config/Local.xcconfig
      echo "▶ 前の場所（$old）から署名の設定を引き継ぎました"
      break
    fi
  done
fi

# クリップ棚で Apple ID の署名を設定済みなら、同じチームで署名する（許可が外れなくなる）
if [ ! -f Config/Local.xcconfig ] && [ -f ../mac-clipboard/Config/Local.xcconfig ]; then
  sed -e 's/CLIP_/MADO_/g' ../mac-clipboard/Config/Local.xcconfig > Config/Local.xcconfig
  echo "▶ クリップ棚と同じ署名の設定を使います"
fi
if [ ! -f Config/Local.xcconfig ] && sh scripts/setup-signing.sh >/dev/null 2>&1; then
  echo "▶ Apple ID の証明書から署名の設定を作りました（アクセシビリティの許可が外れなくなります）"
fi

echo "▶ ビルドしています（1〜2分）…"
xcodebuild -project MadoWari.xcodeproj -scheme MadoWari -configuration Release \
  -derivedDataPath build -quiet build

echo "▶ 動いている窓割りを終了します"
osascript -e 'tell application id "io.github.skmax3.madowari" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x MadoWari >/dev/null 2>&1 || true

# macOS は「署名の決まり（designated requirement）」でアプリを見分ける。これが前と変わったのに古い許可が残っていると、
# 設定画面ではオンに見えるのに効かない。変わったときだけ古い許可を消して、許可し直してもらう
# （Apple ID で署名していれば毎回同じなので、2 回目からは消さない。署名なしだとビルドのたびに変わる）
req() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
old_req=""
if [ -d /Applications/MadoWari.app ]; then old_req=$(req /Applications/MadoWari.app); fi
new_req=$(req build/Build/Products/Release/MadoWari.app)
if [ -z "$new_req" ] || [ "$old_req" != "$new_req" ]; then
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
  if [ -f Config/Local.xcconfig ]; then
    echo "   （署名が変わったため、今回だけ必要です。次からはアップデートしても許可は外れません）"
  else
    echo "   （毎回これが必要なのは、Apple ID で署名していないためです。sh mac-window/scripts/setup-signing.sh で解消できます）"
  fi
fi
