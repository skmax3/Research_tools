# research_tools

FWR（羽ばたきロータ機）研究用の小さなWebツール集。GitHub Pages（main ブランチ / root）で公開。
公開URL: https://skmax3.github.io/Research_tools/

## ルール
- 作業の前に `ROADMAP.md`（アプリ一覧・進み具合）と、触るアプリのフォルダ内の `SPEC.md` / `CLAUDE.md` を読む。終わったら `ROADMAP.md` の状態を更新する。
- ユーザーは学部4年の機械工学科学生。返答・UI・コメントは日本語。GitHub操作には不慣れなので手順は具体的に。
- 1ツール = 1フォルダ（例 `photo-memo/`）。外部ライブラリ・ビルド不要の静的ファイルで作る（index.html にCSS/JSを内包が基本）。
- 例外: Mac ネイティブアプリは `mac-*/` フォルダに置く（例 `mac-clipboard/`）。Swift＋SwiftUI/AppKit、外部ライブラリなし。
  - Xcode プロジェクトは `project.yml`（XcodeGen）から GitHub Actions（`.github/workflows/`）が生成・ビルド確認する。
  - このクラウド環境では Mac アプリをビルドできないので、push 後に Actions の結果でコンパイルを確認し、動作確認はユーザーの Mac で行う。
  - ルートの `index.html`（Web ツール一覧）には載せず、`README.md` の「Mac アプリ」表に載せる。
- 例外: Windows ネイティブアプリは `win-*/` フォルダに置く（例 `win-clipboard/`）。C#（.NET 8）、外部ライブラリ（NuGet）なし。
  - ビルド・テストは GitHub Actions（`windows-latest`）で行う。このクラウド環境では .NET が使えないので、push 後の Actions の結果でコンパイルを確認し、動作確認はユーザーの Windows で行う。
  - 配布は GitHub の Releases（`main` に入ると、Actions が 1 つの exe を zip にして更新する）。
  - 画面を持たない部分（暗号など）は、別プロジェクトのテストで、Mac・Web 版と同じ固定の値との一致を確かめる。
- スマホ（iPhone Safari）と Mac の両方で使えること。ホーム画面アプリ化のため各フォルダに
  `manifest.webmanifest` / `sw.js`（ネットワーク優先・オフライン時キャッシュ）/ `icon-192.png` `icon-512.png` `apple-touch-icon.png` を置く。`photo-memo/` を雛形にする。
- 新しいツールを追加したら、ルートの `index.html` の一覧と `README.md` の表に1行追加する。
- 研究データ（実験結果・写真・未発表の図）はリポジトリに入れない。ツールはデータを外部送信しない。
- 作業ブランチで作業 → プルリクエスト → Claude がマージ、の流れ（ユーザー許可済み・2026-11-15）。マージ後数分で Pages に反映される。
  - Mac アプリ（`mac-*/`）を変えた PR は、GitHub Actions のビルドが成功してからマージする。
  - Web ツールは自動テスト（Playwright など）で確認してからマージする。
  - PR には変更内容と「実機でのみ確認できること」を書く。ユーザーはあとから PR で確認できる。
  - マージしたら、ユーザーに何が変わったか・何を試してほしいかを短く伝える。
  - Mac アプリの反映: ユーザーはメニューバーの「最新版にアップデート…」（中身は `mac-clipboard/scripts/update.command`）を押すだけ。
