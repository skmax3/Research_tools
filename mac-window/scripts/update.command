#!/bin/sh
# 窓割りを最新版にする（最新のプログラムを取得 → ビルド → アプリケーションフォルダに入れて起動）。
# 窓割りのメニュー「最新版にアップデート…」から開くと、ターミナルで実行される。
cd "$(dirname "$0")/../.." || exit 1
echo "▶ 最新のプログラムを取得しています"
# Xcode が自動で書き換えることがあるプロジェクトファイルは元に戻してから取得する
git checkout -- mac-window/MadoWari.xcodeproj mac-clipboard/ClipShelf.xcodeproj 2>/dev/null || true
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != "main" ]; then
  git checkout main || { echo "❌ main に切り替えられませんでした。GitHub Desktop で main を選んでから、もう一度実行してください"; exit 1; }
fi
git pull --ff-only origin main || { echo "❌ 取得に失敗しました。GitHub Desktop で Pull してから、もう一度実行してください"; exit 1; }
sh mac-window/scripts/install.sh
echo ""
echo "このウィンドウは閉じて大丈夫です。"
