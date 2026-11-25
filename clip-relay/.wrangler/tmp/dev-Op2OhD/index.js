var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/index.js
import { DurableObject } from "cloudflare:workers";

// src/quick.js
var TAG = "clipshelf-v1";
var enc = new TextEncoder();
var ascii = /* @__PURE__ */ __name((b, from, to) => String.fromCharCode(...b.subarray(from, to)), "ascii");
function sniff(b) {
  if (b.length >= 3 && b[0] === 255 && b[1] === 216 && b[2] === 255) return { kind: "image", mime: "image/jpeg", ext: "jpg" };
  if (b.length >= 8 && b[0] === 137 && ascii(b, 1, 4) === "PNG") return { kind: "image", mime: "image/png", ext: "png" };
  if (b.length >= 6 && ascii(b, 0, 4) === "GIF8") return { kind: "image", mime: "image/gif", ext: "gif" };
  if (b.length >= 12 && ascii(b, 0, 4) === "RIFF" && ascii(b, 8, 12) === "WEBP") return { kind: "image", mime: "image/webp", ext: "webp" };
  if (b.length >= 12 && ascii(b, 4, 8) === "ftyp" && ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].includes(ascii(b, 8, 12))) {
    return { kind: "image", mime: "image/heic", ext: "heic" };
  }
  if (b.length === 0) return null;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(b);
    if (!text.includes("\0")) return { kind: "text", mime: "text/plain", ext: "txt" };
  } catch (_) {
  }
  return null;
}
__name(sniff, "sniff");
async function sealQuick(pubRaw, meta, body, fixed) {
  const recipient = await crypto.subtle.importKey("raw", pubRaw, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const eph = fixed?.eph || await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: recipient }, eph.privateKey, 256);
  const ikm = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveBits"]);
  const keyBits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode(TAG), info: enc.encode(TAG + " quick") },
    ikm,
    256
  );
  const key = await crypto.subtle.importKey("raw", keyBits, "AES-GCM", false, ["encrypt"]);
  const ephPub = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const m = enc.encode(typeof meta === "string" ? meta : JSON.stringify(meta));
  const plain = new Uint8Array(4 + m.length + body.length);
  new DataView(plain.buffer).setUint32(0, m.length);
  plain.set(m, 4);
  plain.set(body, 4 + m.length);
  const nonce = fixed?.nonce || crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: enc.encode(TAG), tagLength: 128 },
    key,
    plain
  ));
  const out = new Uint8Array(1 + 65 + 12 + ct.length);
  out[0] = 2;
  out.set(ephPub, 1);
  out.set(nonce, 66);
  out.set(ct, 78);
  return out;
}
__name(sealQuick, "sealQuick");

// src/index.js
var TTL_MS = 24 * 60 * 60 * 1e3;
var MAX_ITEM = 8 * 1024 * 1024;
var MAX_ROOM = 40 * 1024 * 1024;
var MAX_ITEMS = 30;
var CHUNK = 1024 * 1024;
var INLINE = 48 * 1024;
var CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,DELETE,OPTIONS",
  "access-control-allow-headers": "content-type,x-device",
  "access-control-max-age": "86400"
};
var json = /* @__PURE__ */ __name((obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...CORS } }), "json");
var src_default = {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (url.pathname === "/") return json({ ok: true, service: "clip-relay" });
    const m = url.pathname.match(/^\/r\/([A-Za-z0-9_-]{22,64})\/(items(?:\/\d+)?|ws|pub|quick)$/);
    if (!m) return json({ error: "not found" }, 404);
    return env.ROOM.get(env.ROOM.idFromName(m[1])).fetch(req);
  }
};
var Room = class extends DurableObject {
  static {
    __name(this, "Room");
  }
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS items (seq INTEGER PRIMARY KEY AUTOINCREMENT, t INTEGER, dev TEXT, size INTEGER)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS chunks (seq INTEGER, n INTEGER, data BLOB, PRIMARY KEY (seq, n))`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v BLOB)`);
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
      return json(await this.put(buf, dev), 201);
    }
    if (sub === "pub" && req.method === "PUT") {
      const raw = new Uint8Array(await req.arrayBuffer());
      if (raw.length !== 65 || raw[0] !== 4) return json({ error: "bad key" }, 400);
      try {
        await crypto.subtle.importKey("raw", raw, { name: "ECDH", namedCurve: "P-256" }, false, []);
      } catch (_) {
        return json({ error: "bad key" }, 400);
      }
      const cur = this.pub();
      if (cur) {
        const same = cur.length === raw.length && cur.every((v, i) => v === raw[i]);
        return same ? json({ ok: true }) : json({ error: "another key is registered" }, 409);
      }
      this.sql.exec(`INSERT INTO meta (k, v) VALUES ('pub', ?)`, raw.buffer);
      return json({ ok: true }, 201);
    }
    if (sub === "pub" && req.method === "GET") {
      const cur = this.pub();
      if (!cur) return json({ error: "not found" }, 404);
      return new Response(cur, { headers: { "content-type": "application/octet-stream", "cache-control": "no-store", ...CORS } });
    }
    if (sub === "quick" && req.method === "POST") {
      const pub = this.pub();
      if (!pub) return json({ error: "not paired" }, 409);
      if (Number(req.headers.get("content-length") || 0) > MAX_ITEM) return json({ error: "too large" }, 413);
      const body = new Uint8Array(await req.arrayBuffer());
      if (body.length > MAX_ITEM) return json({ error: "too large" }, 413);
      const kind = sniff(body);
      if (!kind) return json({ error: "unsupported (text or image only)" }, 415);
      const meta = { k: kind.kind, name: kind.kind === "text" ? "" : "iPhone\u304B\u3089." + kind.ext, mime: kind.mime };
      const sealed = await sealQuick(pub, meta, body);
      return json(await this.put(sealed.buffer, "iphone-quick"), 201);
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
      this.sql.exec(`DELETE FROM meta`);
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
  pub() {
    const r = this.sql.exec(`SELECT v FROM meta WHERE k = 'pub'`).toArray();
    return r.length ? new Uint8Array(r[0].v) : null;
  }
  /** 暗号文を1件保存して、待っている端末に知らせる */
  async put(buf, dev) {
    const t = Date.now();
    const seq = this.sql.exec(`INSERT INTO items (t, dev, size) VALUES (?, ?, ?) RETURNING seq`, t, dev, buf.byteLength).one().seq;
    for (let n = 0, p = 0; p < buf.byteLength; n++, p += CHUNK) {
      this.sql.exec(`INSERT INTO chunks (seq, n, data) VALUES (?, ?, ?)`, seq, n, buf.slice(p, p + CHUNK));
    }
    this.prune();
    if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(t + TTL_MS + 1e3);
    const info = { seq, t, dev, size: buf.byteLength };
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(JSON.stringify(info));
      } catch (_) {
      }
    }
    return info;
  }
  read(seq) {
    const parts = this.sql.exec(`SELECT data FROM chunks WHERE seq = ? ORDER BY n`, seq).toArray().map((r) => new Uint8Array(r.data));
    if (!parts.length) return null;
    const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
    let k = 0;
    for (const p of parts) {
      out.set(p, k);
      k += p.length;
    }
    return out;
  }
  // 期限切れ・件数オーバー・容量オーバーの古い項目を消す
  prune() {
    const del = /* @__PURE__ */ __name((seq) => {
      this.sql.exec(`DELETE FROM chunks WHERE seq = ?`, seq);
      this.sql.exec(`DELETE FROM items WHERE seq = ?`, seq);
    }, "del");
    for (const r of this.sql.exec(`SELECT seq FROM items WHERE t < ?`, Date.now() - TTL_MS).toArray()) del(r.seq);
    const rows = this.sql.exec(`SELECT seq, size FROM items ORDER BY seq DESC`).toArray();
    let total = 0;
    rows.forEach((r, i) => {
      total += r.size;
      if (i >= MAX_ITEMS || i > 0 && total > MAX_ROOM) del(r.seq);
    });
  }
  async alarm() {
    this.prune();
    const oldest = this.sql.exec(`SELECT MIN(t) AS t FROM items`).one().t;
    if (oldest) await this.ctx.storage.setAlarm(oldest + TTL_MS + 1e3);
  }
  webSocketMessage(ws, msg) {
    if (msg === "ping") ws.send("pong");
  }
  webSocketClose(ws, code) {
    try {
      ws.close(code, "closed");
    } catch (_) {
    }
  }
  webSocketError(ws) {
    try {
      ws.close(1011, "error");
    } catch (_) {
    }
  }
};
function toBase64(u8) {
  let s = "";
  for (let i = 0; i < u8.length; i += 32768) s += String.fromCharCode.apply(null, u8.subarray(i, i + 32768));
  return btoa(s);
}
__name(toBase64, "toBase64");

// ../../../../tmp/claude-0/-home-user-Research-tools/1520c710-3322-5703-9034-f935f8f48b86/scratchpad/wr/node_modules/wrangler/templates/middleware/middleware-ensure-req-body-drained.ts
var drainBody = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } finally {
    try {
      if (request.body !== null && !request.bodyUsed) {
        const reader = request.body.getReader();
        while (!(await reader.read()).done) {
        }
      }
    } catch (e) {
      console.error("Failed to drain the unused request body.", e);
    }
  }
}, "drainBody");
var middleware_ensure_req_body_drained_default = drainBody;

// ../../../../tmp/claude-0/-home-user-Research-tools/1520c710-3322-5703-9034-f935f8f48b86/scratchpad/wr/node_modules/wrangler/templates/middleware/middleware-miniflare3-json-error.ts
function reduceError(e) {
  return {
    name: e?.name,
    message: e?.message ?? String(e),
    stack: e?.stack,
    cause: e?.cause === void 0 ? void 0 : reduceError(e.cause)
  };
}
__name(reduceError, "reduceError");
var jsonError = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } catch (e) {
    const error = reduceError(e);
    const body = JSON.stringify(error);
    const headers = {
      "Content-Type": "application/json",
      "MF-Experimental-Error-Stack": "true"
    };
    const encoded = encodeURIComponent(body);
    if (encoded.length <= 8192) {
      headers["MF-Experimental-Error-Stack-Payload"] = encoded;
    }
    return new Response(body, { status: 500, headers });
  }
}, "jsonError");
var middleware_miniflare3_json_error_default = jsonError;

// .wrangler/tmp/bundle-5wTyGI/middleware-insertion-facade.js
var __INTERNAL_WRANGLER_MIDDLEWARE__ = [
  middleware_ensure_req_body_drained_default,
  middleware_miniflare3_json_error_default
];
var middleware_insertion_facade_default = src_default;

// ../../../../tmp/claude-0/-home-user-Research-tools/1520c710-3322-5703-9034-f935f8f48b86/scratchpad/wr/node_modules/wrangler/templates/middleware/common.ts
var __facade_middleware__ = [];
function __facade_register__(...args) {
  __facade_middleware__.push(...args.flat());
}
__name(__facade_register__, "__facade_register__");
function __facade_invokeChain__(request, env, ctx, dispatch, middlewareChain) {
  const [head, ...tail] = middlewareChain;
  const middlewareCtx = {
    dispatch,
    next(newRequest, newEnv) {
      return __facade_invokeChain__(newRequest, newEnv, ctx, dispatch, tail);
    }
  };
  return head(request, env, ctx, middlewareCtx);
}
__name(__facade_invokeChain__, "__facade_invokeChain__");
function __facade_invoke__(request, env, ctx, dispatch, finalMiddleware) {
  return __facade_invokeChain__(request, env, ctx, dispatch, [
    ...__facade_middleware__,
    finalMiddleware
  ]);
}
__name(__facade_invoke__, "__facade_invoke__");

// .wrangler/tmp/bundle-5wTyGI/middleware-loader.entry.ts
var __Facade_ScheduledController__ = class ___Facade_ScheduledController__ {
  constructor(scheduledTime, cron, noRetry) {
    this.scheduledTime = scheduledTime;
    this.cron = cron;
    this.#noRetry = noRetry;
  }
  scheduledTime;
  cron;
  static {
    __name(this, "__Facade_ScheduledController__");
  }
  #noRetry;
  noRetry() {
    if (!(this instanceof ___Facade_ScheduledController__)) {
      throw new TypeError("Illegal invocation");
    }
    this.#noRetry();
  }
};
function wrapExportedHandler(worker) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return worker;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  const fetchDispatcher = /* @__PURE__ */ __name(function(request, env, ctx) {
    if (worker.fetch === void 0) {
      throw new Error("Handler does not export a fetch() function.");
    }
    return worker.fetch(request, env, ctx);
  }, "fetchDispatcher");
  return {
    ...worker,
    fetch(request, env, ctx) {
      const dispatcher = /* @__PURE__ */ __name(function(type, init) {
        if (type === "scheduled" && worker.scheduled !== void 0) {
          const controller = new __Facade_ScheduledController__(
            Date.now(),
            init.cron ?? "",
            () => {
            }
          );
          return worker.scheduled(controller, env, ctx);
        }
      }, "dispatcher");
      return __facade_invoke__(request, env, ctx, dispatcher, fetchDispatcher);
    }
  };
}
__name(wrapExportedHandler, "wrapExportedHandler");
function wrapWorkerEntrypoint(klass) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return klass;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  return class extends klass {
    #fetchDispatcher = /* @__PURE__ */ __name((request, env, ctx) => {
      this.env = env;
      this.ctx = ctx;
      if (super.fetch === void 0) {
        throw new Error("Entrypoint class does not define a fetch() function.");
      }
      return super.fetch(request);
    }, "#fetchDispatcher");
    #dispatcher = /* @__PURE__ */ __name((type, init) => {
      if (type === "scheduled" && super.scheduled !== void 0) {
        const controller = new __Facade_ScheduledController__(
          Date.now(),
          init.cron ?? "",
          () => {
          }
        );
        return super.scheduled(controller);
      }
    }, "#dispatcher");
    fetch(request) {
      return __facade_invoke__(
        request,
        this.env,
        this.ctx,
        this.#dispatcher,
        this.#fetchDispatcher
      );
    }
  };
}
__name(wrapWorkerEntrypoint, "wrapWorkerEntrypoint");
var WRAPPED_ENTRY;
if (typeof middleware_insertion_facade_default === "object") {
  WRAPPED_ENTRY = wrapExportedHandler(middleware_insertion_facade_default);
} else if (typeof middleware_insertion_facade_default === "function") {
  WRAPPED_ENTRY = wrapWorkerEntrypoint(middleware_insertion_facade_default);
}
var middleware_loader_entry_default = WRAPPED_ENTRY;
export {
  Room,
  __INTERNAL_WRANGLER_MIDDLEWARE__,
  middleware_loader_entry_default as default
};
//# sourceMappingURL=index.js.map
