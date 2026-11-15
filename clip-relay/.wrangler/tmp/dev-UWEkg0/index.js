var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// src/index.js
import { DurableObject } from "cloudflare:workers";
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
    const m = url.pathname.match(/^\/r\/([A-Za-z0-9_-]{22,64})\/(items(?:\/\d+)?|ws)$/);
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
      if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(t + TTL_MS + 1e3);
      const info = { seq, t, dev, size: buf.byteLength };
      for (const ws of this.ctx.getWebSockets()) {
        try {
          ws.send(JSON.stringify(info));
        } catch (_) {
        }
      }
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

// .wrangler/tmp/bundle-RIWXXo/middleware-insertion-facade.js
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

// .wrangler/tmp/bundle-RIWXXo/middleware-loader.entry.ts
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
