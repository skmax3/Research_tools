#!/bin/sh
# クリップ棚をビルドして「アプリケーション」フォルダに入れ、起動する。
# 使い方: GitHub Desktop の「Repository → Open in Terminal」で開いたターミナルで
#   sh mac-clipboard/scripts/install.sh
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
  for old in "$(defaults read io.github.skmax3.clipshelf repoPath 2>/dev/null)" "$(defaults read io.github.skmax3.madowari repoPath 2>/dev/null)"; do
    if [ -n "$old" ] && [ "$old" != "$here" ] && [ -f "$old/mac-clipboard/Config/Local.xcconfig" ]; then
      cp "$old/mac-clipboard/Config/Local.xcconfig" Config/Local.xcconfig
      echo "▶ 前の場所（$old）から署名の設定を引き継ぎました"
      break
    fi
  done
fi
if [ ! -f Config/Local.xcconfig ] && sh scripts/setup-signing.sh >/dev/null 2>&1; then
  echo "▶ Apple ID の証明書から署名の設定を作りました（アクセシビリティの許可が外れなくなります）"
fi

echo "▶ ビルドしています（1〜2分）…"
xcodebuild -project ClipShelf.xcodeproj -scheme ClipShelf -configuration Release \
  -derivedDataPath build -quiet build

echo "▶ 動いているクリップ棚を終了します"
osascript -e 'tell application id "io.github.skmax3.clipshelf" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x ClipShelf >/dev/null 2>&1 || true

# Apple ID で署名していない場合、入れ直すと前のアクセシビリティの許可は無効になる（設定画面ではオンに見えるのに効かない）。
# 古い許可を消しておき、新しく許可し直せるようにする
if [ ! -f Config/Local.xcconfig ]; then
  tccutil reset Accessibility io.github.skmax3.clipshelf >/dev/null 2>&1 || true
  NEED_TRUST=1
fi

echo "▶ アプリケーションフォルダに入れます"
rm -rf /Applications/ClipShelf.app
cp -R build/Build/Products/Release/ClipShelf.app /Applications/

# メニューの「最新版にアップデート…」がこのリポジトリの場所を分かるように記録する
defaults write io.github.skmax3.clipshelf repoPath "$(cd .. && pwd)"

open /Applications/ClipShelf.app
echo "✅ 完了。メニューバーのアイコンから「ログイン時に起動」をオンにしてください。"
if [ -n "$NEED_TRUST" ]; then
  echo ""
  echo "⚠️  自動貼り付けの許可をやり直す必要があります。"
  echo "   ⇧⌘X でパネルを出し、下に出る「許可の設定を開く」を押して、ClipShelf をオンにしてください。"
  echo "   （毎回これが必要なのは、Apple ID で署名していないためです。sh mac-clipboard/scripts/setup-signing.sh で解消できます）"
fi
