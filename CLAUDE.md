# research_tools

FWR（羽ばたきロータ機）研究用の小さなWebツール集。GitHub Pages（main ブランチ / root）で公開。
公開URL: https://skmax3.github.io/Research_tools/

## ルール
- ユーザーは学部4年の機械工学科学生。返答・UI・コメントは日本語。GitHub操作には不慣れなので手順は具体的に。
- 1ツール = 1フォルダ（例 `photo-memo/`）。外部ライブラリ・ビルド不要の静的ファイルで作る（index.html にCSS/JSを内包が基本）。
- スマホ（iPhone Safari）と Mac の両方で使えること。ホーム画面アプリ化のため各フォルダに
  `manifest.webmanifest` / `sw.js`（ネットワーク優先・オフライン時キャッシュ）/ `icon-192.png` `icon-512.png` `apple-touch-icon.png` を置く。`photo-memo/` を雛形にする。
- 新しいツールを追加したら、ルートの `index.html` の一覧と `README.md` の表に1行追加する。`README.md` の「今後の予定」も更新する。
- 端末間の同期が必要なときも外部サーバーは使わず、同期ファイル（JSON）の書き出し/読み込み＋AirDrop・iCloud Drive で受け渡す（`clip-box/` を参照）。
- 研究データ（実験結果・写真・未発表の図）はリポジトリに入れない。ツールはデータを外部送信しない。
- 作業ブランチで作業 → プルリクエスト → ユーザーが GitHub 上でマージ、の流れ。マージ後数分で Pages に反映される。
