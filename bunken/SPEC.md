# 文献管理（bunken）仕様メモ

卒論に向けて、読んだ論文・引用する論文を管理する。Zotero ほど大きくなく、FWR 研究で必要なことだけ。

## やること（MVP）
- 追加: DOI（Crossref から書誌情報を取得）／BibTeX 貼り付け・.bib ファイル／PDF ファイル／手入力
- 論文フォルダをつなぐ（Mac の Chrome・Edge。File System Access API）
  - PDF はフォルダに置いたまま。アプリは「フォルダ内の相対パス」だけ覚える
  - サブフォルダ名をタグにする。PDF の中（圧縮されていない部分）から DOI を探し、見つかれば Crossref で書誌情報を取得（確認してから）
  - 一覧（メモ・タグなど）をフォルダ内の `bunken-library.json` に保存・読み込み（自動保存も可）。
    フォルダを iCloud Drive / Google ドライブに置けば、論文や研究データを GitHub に入れずに別の端末と共有できる
- Safari・iPhone はフォルダをつなげないので、PDF をアプリ内（IndexedDB）に取り込む
- 文献ごと: 状態（未読／読んでる／読んだ／引用する）、重要度（★1〜3）、タグ、要点メモ、卒論での使いどころ、その他メモ
- 検索・状態・タグで絞り込み、並べ替え
- 書き出し: BibTeX（.bib）、参考文献リスト（機械学会論文集に近い形）、JSON バックアップ／読み込み（id と更新日時で統合）

## 外部への送信
- 「DOI で追加」「取得」ボタン、PDF から DOI を見つけたときの確認後だけ、**DOI の文字列だけ**を `api.crossref.org` に送る。PDF・メモは送らない。
- Service Worker は同じサイトのファイルだけキャッシュする（Crossref の応答は保存しない）。

## 保存場所
- IndexedDB `bunken`: `kv`（papers 配列・つないだフォルダのハンドル・表示設定）、`files`（アプリ内に取り込んだ PDF）
- データ形式: `{id, type, title, authors[「姓, 名」], year, journal, volume, number, pages, doi, url, tags[], status, stars, summary, usage, note, key, file:{kind:'dir'|'app', path?, name}, added, updated}`

## 実機でのみ確認できること
- Mac の Chrome でフォルダを選ぶ → 許可 → PDF の取り込み、再起動後に PDF を開くときの許可の出方
- iCloud Drive 上のフォルダで（ダウンロードされていない PDF の扱い）
- Crossref からの取得（このクラウド環境からは接続できず、テストは偽の応答で行った）
- iPhone で PDF を取り込んで開く

## 今後の候補
- ユーザーの論文フォルダで試して、ファイル名・DOI の拾い方を調整
- PDF のタイトルを XMP メタデータから読む
- 本文での引用番号の管理（Word 用）、研究室指定の参考文献形式
- 重複の統合画面
