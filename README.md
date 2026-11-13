# 研究ツール集（research_tools）

FWR 研究で使う小さなWebツールをまとめたリポジトリです。ブラウザだけで動き、スマホのホーム画面にアプリとして追加できます。

**公開ページ:** https://skmax3.github.io/Research_tools/ （GitHub Pages を有効にした後）

| ツール | フォルダ | 説明 |
|---|---|---|
| 写真寸法メモ | [`photo-memo/`](photo-memo/) | 写真に矢印・寸法線・コメント・番号を書き込み、画像として書き出す |
| クリップボード | [`clipboard/`](clipboard/) | テキスト・画像・ファイルをためて、順番を決めてコピー・番号付き保存。表→Markdown/LaTeX変換や記号パレットも |

今後の予定は [ROADMAP.md](ROADMAP.md) を参照。

---

## はじめての設定：GitHub Pages を有効にする（最初の1回だけ）
1. このリポジトリのページ（https://github.com/skmax3/Research_tools ）を開く
2. 上のタブの **Settings**（歯車）を押す（スマホでは横スクロール or「…」の中）
3. メニューの **Pages** を押す
4. 「Build and deployment」で **Source: Deploy from a branch**、**Branch: main / (root)** を選んで **Save**
5. 数分後、ページ上部に公開URLが表示される

## スマホのホーム画面に追加する
1. Safari で `https://skmax3.github.io/Research_tools/photo-memo/` を開く
2. 共有ボタン（□に↑）→ **ホーム画面に追加**
3. 以後はアイコンから起動（一度開けばオフラインでも起動できる）

## Mac で使う
- Safari で公開URLを開き、メニューの **ファイル → Dockに追加** でアプリのように使える
- ネットなしで使いたい場合は、各フォルダの `index.html` をダウンロードしてダブルクリックでもOK

## ツールを増やす・直すとき（Claude Code）
1. Claude Code で新しいセッションを始めるとき、リポジトリに **skmax3/Research_tools** を選ぶ
2. 「◯◯するツールを作って」「写真寸法メモの△△を直して」と頼む
3. Claude が作業用ブランチに保存し、頼めば **プルリクエスト**（変更の提案）を作る
4. GitHub で **Pull requests** タブ → その提案を開く → **Merge pull request** → **Confirm merge**
5. 数分で公開ページに反映される（ホーム画面のアプリは次回起動時に最新になる）

## 用語メモ
- **リポジトリ**: プロジェクトのフォルダ＋変更履歴。ここでは「研究ツール集」1つにまとめている
- **ブランチ**: 本流（main）と別に作業する枝。公開されるのは main だけ
- **プルリクエスト**: ブランチの変更を main に取り込む提案。マージ＝取り込み実行
- **push**: 変更を GitHub に送ること。Claude Code のクラウド環境は使い終わると消えるので push が必須
