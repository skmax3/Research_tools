// クリップ棚の中継サーバー。
// 端末側で暗号化されたデータ（暗号文）を「部屋」ごとに一時的に預かり、相手の端末に渡すだけ。
// サーバーは鍵を持たないので中身は読めない。部屋IDは端末どうしが共有した秘密から作られる推測できない文字列。
//
//   POST   /r/<部屋ID>/items          暗号文を置く（本文＝バイナリ、ヘッダー x-device＝送った端末の名前）
//   GET    /r/<部屋ID>/items?after=N  N より新しい項目の一覧（小さいものは中身も base64 で入る）
//   GET    /r/<部屋ID>/items/<番号>   1件の中身（バイナリ）
//   DELETE /r/<部屋ID>/items          部屋の中身を全部消す
//   GET    /r/<部屋ID>/ws             WebSocket。新しい項目が置かれたら {seq,t,dev,size} が届く
import { DurableObject } from "cloudflare:workers";

const TTL_MS = 24 * 60 * 60 * 1000;      // 24時間で自動削除
const MAX_ITEM = 8 * 1024 * 1024;        // 1件の上限 8MB
const MAX_ROOM = 40 * 1024 * 1024;       // 部屋の合計上限 40MB
const MAX_ITEMS = 30;                    // 部屋に残す件数
const CHUNK = 1024 * 1024;               // 保存は1MBずつ（1行2MBの制限のため）
const INLINE = 48 * 1024;                // これ以下は一覧に中身も入れる

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,DELETE,OPTIONS",
  "access-control-allow-headers": "content-type,x-device",
  "access-control-max-age": "86400",
};
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS } });

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (url.pathname === "/") return json({ ok: true, service: "clip-relay" });
    const m = url.pathname.match(/^\/r\/([A-Za-z0-9_-]{22,64})\/(items(?:\/\d+)?|ws)$/);
    if (!m) return json({ error: "not found" }, 404);
    return env.ROOM.get(env.ROOM.idFromName(m[1])).fetch(req);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS items (seq INTEGER PRIMARY KEY AUTOINCREMENT, t INTEGER, dev TEXT, size INTEGER)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS chunks (seq INTEGER, n INTEGER, data BLOB, PRIMARY KEY (seq, n))`);
  }

  async fetch(req) {
    const url = new URL(req.url);
    const sub = url.pathname.replace(/^\/r\/[^/]+\//, "");

    if (sub === "ws") {
      if (req.headers.get("upgrade") !== "websocket") return json({ error: "websocket only" }, 426);
      const pair = new WebSocketPair();
      this.ctx.acceptWebSocket(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }

    if (sub === "items" && req.method === "POST") {
      if (Number(req.headers.get("content-length") || 0) > MAX_ITEM) return json({ error: "too large" }, 413);
      const buf = await req.arrayBuffer();
      if (buf.byteLength === 0) return json({ error: "empty" }, 400);
      if (buf.byteLength > MAX_ITEM) return json({ error: "too large" }, 413);
      const dev = (req.headers.get("x-device") || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 40);
      const t = Date.now();
      const seq = this.sql.exec(`INSERT INTO items (t, dev, size) VALUES (?, ?, ?) RETURNING seq`, t, dev, buf.byteLength).one().seq;
      for (let n = 0, p = 0; p < buf.byteLength; n++, p += CHUNK) {
        this.sql.exec(`INSERT INTO chunks (seq, n, data) VALUES (?, ?, ?)`, seq, n, buf.slice(p, p + CHUNK));
      }
      this.prune();
      if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(t + TTL_MS + 1000);
      const info = { seq, t, dev, size: buf.byteLength };
      for (const ws of this.ctx.getWebSockets()) { try { ws.send(JSON.stringify(info)); } catch (_) {} }
      return json(info, 201);
    }

    if (sub === "items" && req.method === "GET") {
      this.prune();
      const after = Number(url.searchParams.get("after") || 0) || 0;
      const rows = this.sql.exec(`SELECT seq, t, dev, size FROM items WHERE seq > ? ORDER BY seq LIMIT 50`, after).toArray();
      for (const r of rows) if (r.size <= INLINE) r.data = toBase64(this.read(r.seq));
      return json({ items: rows, now: Date.now() });
    }

    if (sub === "items" && req.method === "DELETE") {
      this.sql.exec(`DELETE FROM chunks`);
      this.sql.exec(`DELETE FROM items`);
      await this.ctx.storage.deleteAlarm();
      return json({ ok: true });
    }

    const one = sub.match(/^items\/(\d+)$/);
    if (one && req.method === "GET") {
      this.prune();
      const data = this.read(Number(one[1]));
      if (!data) return json({ error: "not found" }, 404);
      return new Response(data, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store", ...CORS } });
    }
    return json({ error: "method not allowed" }, 405);
  }

  read(seq) {
    const parts = this.sql.exec(`SELECT data FROM chunks WHERE seq = ? ORDER BY n`, seq).toArray().map((r) => new Uint8Array(r.data));
    if (!parts.length) return null;
    const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
    let k = 0;
    for (const p of parts) { out.set(p, k); k += p.length; }
    return out;
  }

  // 期限切れ・件数オーバー・容量オーバーの古い項目を消す
  prune() {
    const del = (seq) => { this.sql.exec(`DELETE FROM chunks WHERE seq = ?`, seq); this.sql.exec(`DELETE FROM items WHERE seq = ?`, seq); };
    for (const r of this.sql.exec(`SELECT seq FROM items WHERE t < ?`, Date.now() - TTL_MS).toArray()) del(r.seq);
    const rows = this.sql.exec(`SELECT seq, size FROM items ORDER BY seq DESC`).toArray();
    let total = 0;
    rows.forEach((r, i) => { total += r.size; if (i >= MAX_ITEMS || (i > 0 && total > MAX_ROOM)) del(r.seq); });
  }

  async alarm() {
    this.prune();
    const oldest = this.sql.exec(`SELECT MIN(t) AS t FROM items`).one().t;
    if (oldest) await this.ctx.storage.setAlarm(oldest + TTL_MS + 1000);
  }

  webSocketMessage(ws, msg) { if (msg === "ping") ws.send("pong"); }
  webSocketClose(ws, code) { try { ws.close(code, "closed"); } catch (_) {} }
  webSocketError(ws) { try { ws.close(1011, "error"); } catch (_) {} }
}

function toBase64(u8) {
  let s = "";
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return btoa(s);
}
