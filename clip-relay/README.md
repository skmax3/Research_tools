# clip-relay（クリップ棚の中継サーバー）

Mac のクリップ棚と iPhone の間で、**端末側で暗号化されたデータ**を一時的に預かって渡すだけの小さなサーバー（Cloudflare Workers + Durable Objects、無料プランで動く）。

- サーバーは鍵を持たないので、中身は読めない（暗号文と、送った時刻・端末名・サイズだけを見る）。
- 部屋ID は、2台が QR で共有した秘密から作る推測できない文字列。部屋ごとに保存場所が分かれる。
- 保存は 24 時間で自動削除。1件 8MB まで、部屋ごとに 30 件・合計 40MB まで（古いものから消える）。
- 配置は、`main` に入ると GitHub Actions（`.github/workflows/clip-relay.yml`）が自動で行う。事前に GitHub の Secrets へ `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を登録しておく。

## API
| メソッド・パス | 内容 |
|---|---|
| `POST /r/<部屋ID>/items` | 暗号文を置く（本文＝バイナリ、ヘッダー `x-device`＝端末名） |
| `GET /r/<部屋ID>/items?after=N` | N より新しい項目の一覧（48KB 以下は中身も base64 で入る） |
| `GET /r/<部屋ID>/items/<番号>` | 1件の中身（バイナリ） |
| `DELETE /r/<部屋ID>/items` | 部屋の中身を全部消す |
| `GET /r/<部屋ID>/ws` | WebSocket。新しい項目が置かれると `{seq,t,dev,size}` が届く |

## ローカルで試す
```
cd clip-relay
npx wrangler dev --local --port 8799     # 1つ目のターミナル
node test/smoke.mjs                       # 2つ目のターミナル（16項目のテスト）
```
