#!/bin/sh
# 窓割り・クリップ棚の「最新版にアップデート…」が使う、安全な取得（git pull の代わり）。
# 手元に変更があっても止まらず、消さずに「local-backup-日付」ブランチへ退避してから main を最新にする。
# 使い方: sh scripts/safe-pull.sh（どこから実行してもよい）
cd "$(dirname "$0")/.." || exit 1
repo=$(pwd)
stamp=$(date +%Y%m%d-%H%M%S)

# git の名前・メールが未設定でも退避のコミットができるように
ident=""
[ -z "$(git config user.email)" ] && ident="-c user.name=update -c user.email=update@localhost"

# 1. iCloud Drive の中にあるか（一部のファイルがクラウドだけに置かれると、取得が途中で止まる: mmap failed など）
icloud=""
case "$repo" in
  "$HOME/Library/Mobile Documents/"*) icloud=1 ;;
  "$HOME/Desktop"*|"$HOME/Documents"*)
    [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Desktop" ] && icloud=1 ;;
esac
if [ -n "$icloud" ]; then
  echo "⚠️  このリポジトリは iCloud Drive の中にあります: $repo"
  echo "   iCloud の外（例: ホームフォルダの GitHub フォルダ）に取り直すのがおすすめです。"
  echo "   手順: GitHub Desktop の File → Clone Repository… で Local Path に iCloud の外のフォルダを選ぶ"
  offline=$(find . \( -name build -o -name node_modules \) -prune -o -flags +dataless -print 2>/dev/null | head -n 1)
  if [ -n "$offline" ]; then
    echo "❌ クラウドだけに置かれていて、この Mac にないファイルがあります（例: $offline）。"
    echo "   Finder でこのフォルダを右クリック →「今すぐダウンロード」してから、もう一度実行してください。"
    exit 1
  fi
fi

# 2. 途中で止まった取得・結合が残っていれば、やめる
[ -f .git/MERGE_HEAD ] && git merge --abort 2>/dev/null
{ [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; } && git rebase --abort 2>/dev/null

# 3. Xcode が自動で書き換えるプロジェクトファイルは、元に戻す（Actions が作ったものが正しい）
git checkout -- mac-window/MadoWari.xcodeproj mac-clipboard/ClipShelf.xcodeproj 2>/dev/null

git fetch -q origin main || { echo "❌ GitHub に接続できませんでした。ネットにつながっているか確かめてください"; exit 1; }

# 4. 手元の変更（＋最新版と同じ名前の、Git に入っていないファイル）があれば、ブランチへ退避する
conflicts=$(git ls-files --others --exclude-standard | while IFS= read -r f; do
  git cat-file -e "origin/main:$f" 2>/dev/null && printf '%s\n' "$f"
done)
if [ -n "$(git status --porcelain --untracked-files=no)" ] || [ -n "$conflicts" ]; then
  cur=$(git rev-parse --abbrev-ref HEAD)
  b="local-backup-$stamp"
  git checkout -q -b "$b" || { echo "❌ 退避用のブランチを作れませんでした"; exit 1; }
  git add -u
  [ -n "$conflicts" ] && printf '%s\n' "$conflicts" | while IFS= read -r f; do git add -- "$f"; done
  # shellcheck disable=SC2086
  git $ident commit -q -m "アップデート前の自動退避（$cur にあった変更）" \
    || { echo "❌ 退避のコミットに失敗しました"; exit 1; }
  echo "💾 手元の変更をブランチ「$b」に退避しました（消えていません。GitHub Desktop の Current Branch から見られます）"
fi

# 5. main に切り替えて、最新版にそろえる
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
  git checkout -q main || { echo "❌ main に切り替えられませんでした"; exit 1; }
fi
if git merge-base --is-ancestor HEAD origin/main; then
  git merge -q --ff-only origin/main || { echo "❌ 最新版にできませんでした"; exit 1; }
else
  # main に手元だけのコミットがある（GitHub とずれている）→ 退避してから GitHub にそろえる
  b="local-backup-main-$stamp"
  git branch "$b" HEAD
  git reset -q --hard origin/main
  echo "💾 main にあった手元だけのコミットを、ブランチ「$b」に退避しました"
fi
echo "✅ 最新のプログラムを取得しました（$(git log -1 --format=%h)）"
