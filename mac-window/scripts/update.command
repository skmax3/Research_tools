#!/bin/sh
# 窓割りを最新版にする（最新のプログラムを取得 → ビルド → アプリケーションフォルダに入れて起動）。
# 窓割りのメニュー「最新版にアップデート…」から開くと、ターミナルで実行される。
cd "$(dirname "$0")/../.." || exit 1
echo "▶ 最新のプログラムを取得しています"
# 手元に変更があっても止まらないように、退避してから最新にする（scripts/safe-pull.sh）
sh scripts/safe-pull.sh || { echo ""; echo "❌ 取得できませんでした。上の案内を確かめてください"; exit 1; }
sh mac-window/scripts/install.sh
echo ""
echo "🎉 窓割りを最新版（$(git log -1 --format=%h)）にしました。このウィンドウは閉じて大丈夫です。"
