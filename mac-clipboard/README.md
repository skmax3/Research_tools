# クリップ棚（Mac アプリ）

⌘C したものを自動で記録し、**⇧⌘X で画面の下から履歴パネルを出して**、選ぶとそのまま元のアプリに貼り付ける Mac 用クリップボードアプリ。
Web 版（`clipboard/`）と違い、ネイティブアプリなのでバックグラウンドの記録・どこでも効くショートカット・自動貼り付けができる。

- データは `~/Library/Application Support/ClipShelf/` にだけ保存し、外部には送らない。
- パスワードマネージャーが「記録しないで」と印を付けたコピーは記録しない。
- 必要環境: macOS 14 Sonoma 以降、Xcode（App Store から無料）。

## 使い方
| 操作 | キー・マウス |
|---|---|
| パネルを出す／閉じる | ⇧⌘X（メニューバーのアイコンからも開ける） |
| 選ぶ | クリック、← → |
| 貼り付け | ダブルクリック、Enter（⌥Enter で書式なし）、⌘1〜⌘9 |
| 複数選択 | ⌘クリック・⇧クリック・Space・カード右上の丸、⇧← → で連続、⌘A で全部（選んだ順に番号が付く） |
| 複数を貼る | Enter＝番号順に1件ずつ貼る（テキストの間は改行）／⇧Enter＝1回にまとめて貼る |
| 種類で絞り込み | 上のチップ（テキスト・リンク・画像・ファイルで色分け）、Tab で切り替え |
| コピー元で絞り込み・並べ替え | アプリのチップ（件数の多い順）、「アプリ順」でアプリごとに並べる |
| 文字で絞り込み | 検索欄に入力 |
| ピン留め／削除 | ⌘P ／ ⌘⌫ |
| 他のアプリへ渡す | カードをドラッグ |
| 閉じる | Esc（複数選択中は選択の解除） |

自動で貼り付けるには、初回に「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で ClipShelf を許可する。許可するまでは「コピーまで」で、⌘V は自分で押す。

## 自分の Mac でビルドして動かす
1. GitHub Desktop でこのリポジトリを取得（更新は「Fetch origin → Pull origin」）
2. 試すとき: `mac-clipboard/ClipShelf.xcodeproj` を Xcode で開いて ▶（Run）
3. 普段使い: GitHub Desktop の「Repository → Open in Terminal」で開いたターミナルで次を実行する。ビルドして「アプリケーション」フォルダに入れ、起動まで行う。
   ```
   sh mac-clipboard/scripts/install.sh
   ```
4. ビルドし直してもアクセシビリティの許可が外れないようにする（1回だけ）
   1. Xcode の Settings → Apple Accounts で Apple ID を追加
   2. Manage Certificates… → ＋ → Apple Development
   3. 次を実行する
      ```
      sh mac-clipboard/scripts/setup-signing.sh
      ```

## 開発メモ
- Xcode のプロジェクトは `project.yml`（XcodeGen）から GitHub Actions が自動生成してコミットする。設定変更は `project.yml` を編集する。
- 署名は初期値が「このMacで実行（ad-hoc）」。この場合、ビルドし直すたびにアクセシビリティの許可が外れることがある。`scripts/setup-signing.sh` で Apple ID の開発用証明書に切り替えると外れない（`Config/Local.xcconfig` は Git に入らない）。
- 起動時に、同じアプリがすでに動いていれば古いほうを終了する（Xcode 実行版とインストール版の二重起動を防ぐ）。
- 構成:
  - `HotKey.swift`: グローバルショートカット（Carbon）
  - `PasteboardWatcher.swift`: クリップボードの監視
  - `ClipStore.swift`: 保存
  - `PanelController.swift` / `PanelView.swift`: 下から出るパネル（SwiftUI）
  - `Paster.swift`: 貼り付け（CGEvent で ⌘V を送る）
