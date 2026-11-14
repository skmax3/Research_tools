# クリップ棚（Mac アプリ）

⌘C したものを自動で記録し、**⇧⌘X で画面の下から履歴パネルを出して**、選ぶとそのまま元のアプリに貼り付ける Mac 用クリップボードアプリ。
Web 版（`clipboard/`）と違い、ネイティブアプリなのでバックグラウンドの記録・どこでも効くショートカット・自動貼り付けができる。

- データは `~/Library/Application Support/ClipShelf/` にだけ保存し、外部には送らない。
- パスワードマネージャーが「記録しないで」と印を付けたコピーは記録しない。
- 必要環境: macOS 14 Sonoma 以降、Xcode（App Store から無料）。

## 使い方
| 操作 | キー |
|---|---|
| パネルを出す／閉じる | ⇧⌘X（メニューバーのアイコンからも開ける） |
| 選ぶ | ← → ／ 文字を打つと絞り込み |
| 貼り付け | Enter またはクリック（⌥Enter で書式なし） |
| 番号で貼り付け | ⌘1〜⌘9 |
| ピン留め／削除 | ⌘P ／ ⌘⌫ |
| 閉じる | Esc |

自動で貼り付けるには、初回に「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で ClipShelf を許可する。許可するまでは「コピーまで」で、⌘V は自分で押す。

## 自分の Mac でビルドして動かす
1. GitHub Desktop でこのリポジトリを取得（初回のみ。手順はチャットで案内）
2. `mac-clipboard/ClipShelf.xcodeproj` をダブルクリックして Xcode で開く
3. 左上の ▶（Run）を押す → メニューバーにアイコンが出る
4. 更新があったら GitHub Desktop で「Fetch origin → Pull」→ Xcode で再度 ▶

## 開発メモ
- Xcode のプロジェクトは `project.yml`（XcodeGen）から GitHub Actions が自動生成してコミットする。設定変更は `project.yml` を編集する。
- 署名は初期値が「このMacで実行（ad-hoc）」。この場合、ビルドし直すたびにアクセシビリティの許可が外れることがある。
  - 外れないようにするには、Xcode の設定 → Accounts に Apple ID を追加する。
  - そのうえで `Config/Local.xcconfig` に自分のチーム ID を書く（`Config/Signing.xcconfig` のコメント参照）。
- 構成:
  - `HotKey.swift`: グローバルショートカット（Carbon）
  - `PasteboardWatcher.swift`: クリップボードの監視
  - `ClipStore.swift`: 保存
  - `PanelController.swift` / `PanelView.swift`: 下から出るパネル（SwiftUI）
  - `Paster.swift`: 貼り付け（CGEvent で ⌘V を送る）
