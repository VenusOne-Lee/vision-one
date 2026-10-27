// Vision One share pages, on the creator's own free Cloudflare account.
//
//   GET  /v/:slug/            the page (index.html from R2)
//   GET  /v/:slug/:file       video.mp4, captions.vtt, poster.jpg (Range works)
//   POST /api/events          viewers: views, watch progress, reactions, questions
//   POST /api/notes           viewers: a note on one line, for the creator only
//   GET  /api/reactions       viewers: everyone's reactions, for the moments bar
//   GET  /api/health          creator: is this set up and is my key right
//   PUT  /api/pages/:slug/:f  creator: upload a bundle file
//   DELETE /api/pages/:slug   creator: take a page down
//   GET  /api/inbox           creator: notes since a time, events after an id
//
// Creator calls carry `Authorization: Bearer <CREATOR_KEY>`, a secret
// Vision One makes when it sets this up and keeps in the Mac's keychain.
// Viewers never sign in. Nothing stores IP addresses or sets cookies.

const VERSION = "1";
const BUNDLE_FILES = {
  "index.html": "text/html; charset=utf-8",
  "page.json": "application/json; charset=utf-8",
  "video.mp4": "video/mp4",
  "poster.jpg": "image/jpeg",
  "captions.vtt": "text/vtt; charset=utf-8",
};
const EVENT_KINDS = new Set(["view", "progress", "finish", "reaction", "question"]);
const EMOJI = new Set(["👍", "🔥", "😂", "🤔", "👏"]);
const SLUG = /^[a-z0-9][a-z0-9-]{0,63}$/;
const VISIT = /^[a-z0-9]{6,40}$/;
const MAX_EVENTS_PER_POST = 50;
const MAX_NOTES_PER_PAGE_PER_DAY = 200;
const MAX_EVENTS_PER_PAGE_PER_DAY = 50000;

// The page runs its own inline script and loads only its own files.
// ISO 8601 without milliseconds, which Swift's .iso8601 reads.
const isoNow = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

const PAGE_CSP = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  "style-src 'unsafe-inline'",
  "img-src 'self' data:",
  "media-src 'self'",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error(err);
      return json({ error: "Something went wrong on the share server." }, 500);
    }
  },
};

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  let m;
  if ((m = path.match(/^\/v\/([^/]+)\/?$/)) && (method === "GET" || method === "HEAD")) {
    if (!path.endsWith("/")) return Response.redirect(url.origin + path + "/" + url.search, 301);
    return serveFile(request, env, m[1], "index.html");
  }
  if ((m = path.match(/^\/v\/([^/]+)\/([^/]+)$/)) && (method === "GET" || method === "HEAD")) {
    return serveFile(request, env, m[1], m[2]);
  }

  if (path === "/api/events" && method === "POST") return postEvents(request, env);
  if (path === "/api/notes" && method === "POST") return postNote(request, env);
  if (path === "/api/reactions" && method === "GET") return getReactions(url, env);

  if (path === "/api/health" && method === "GET") {
    await requireCreator(request, env);
    return json({ ok: true, version: VERSION });
  }
  if ((m = path.match(/^\/api\/pages\/([^/]+)\/([^/]+)$/)) && method === "PUT") {
    await requireCreator(request, env);
    return putFile(request, env, m[1], m[2]);
  }
  if ((m = path.match(/^\/api\/pages\/([^/]+)$/)) && method === "DELETE") {
    await requireCreator(request, env);
    return deletePage(env, m[1]);
  }
  if (path === "/api/inbox" && method === "GET") {
    await requireCreator(request, env);
    return getInbox(url, env);
  }

  if (path === "/" || path === "") {
    return new Response("Vision One share pages live here.", { headers: { "content-type": "text/plain; charset=utf-8" } });
  }
  return json({ error: "Not found." }, 404);
}

// ---------- Viewers ----------

async function serveFile(request, env, slug, file) {
  if (!SLUG.test(slug) || !BUNDLE_FILES[file]) return notFound();
  const key = `pages/${slug}/${file}`;
  const range = parseRange(request.headers.get("range"));
  const object = await env.FILES.get(key, range ? { range } : undefined);
  if (!object) return notFound();

  const headers = new Headers();
  headers.set("content-type", BUNDLE_FILES[file]);
  headers.set("accept-ranges", "bytes");
  headers.set("etag", object.httpEtag);
  headers.set("x-content-type-options", "nosniff");
  headers.set("referrer-policy", "no-referrer");
  if (file === "index.html") {
    headers.set("content-security-policy", PAGE_CSP);
    headers.set("cache-control", "no-cache");
  } else {
    headers.set("cache-control", "public, max-age=300");
  }

  let status = 200;
  if (range && object.range) {
    const start = object.range.offset ?? 0;
    const length = object.range.length ?? object.size - start;
    headers.set("content-range", `bytes ${start}-${start + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    status = 206;
  } else {
    headers.set("content-length", String(object.size));
  }
  return new Response(request.method === "HEAD" ? null : object.body, { status, headers });
}

// "bytes=0-" / "bytes=100-199" / "bytes=-500", as R2 range options.
function parseRange(header) {
  if (!header) return null;
  const m = header.match(/^bytes=(\d*)-(\d*)$/);
  if (!m || (m[1] === "" && m[2] === "")) return null;
  if (m[1] === "") return { suffix: Number(m[2]) };
  const offset = Number(m[1]);
  if (m[2] === "") return { offset };
  const end = Number(m[2]);
  if (end < offset) return null;
  return { offset, length: end - offset + 1 };
}

async function postEvents(request, env) {
  const body = await readJSON(request, 64 * 1024);
  const slug = await knownPage(env, body.page);
  const list = Array.isArray(body.events) ? body.events.slice(0, MAX_EVENTS_PER_POST) : [];
  const now = isoNow();

  const today = await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE page = ?1 AND time >= ?2")
    .bind(slug, now.slice(0, 10)).first();
  if ((today?.n ?? 0) > MAX_EVENTS_PER_PAGE_PER_DAY) return json({ ok: true, kept: 0 });

  const rows = [];
  for (const e of list) {
    if (!e || !EVENT_KINDS.has(e.kind) || typeof e.visit !== "string" || !VISIT.test(e.visit)) continue;
    const at = typeof e.at === "number" && isFinite(e.at) && e.at >= 0 && e.at < 86400 ? Math.round(e.at * 10) / 10 : null;
    const emoji = e.kind === "reaction" && EMOJI.has(e.emoji) ? e.emoji : null;
    if (e.kind === "reaction" && (!emoji || at === null)) continue;
    const text = e.kind === "question" && typeof e.text === "string" ? e.text.trim().slice(0, 200) : null;
    if (e.kind === "question" && !text) continue;
    rows.push(env.DB.prepare("INSERT INTO events (page, visit, kind, at, emoji, text, time) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
      .bind(slug, e.visit, e.kind, at, emoji, text, now));
  }
  if (rows.length) await env.DB.batch(rows);
  return json({ ok: true, kept: rows.length });
}

async function postNote(request, env) {
  const body = await readJSON(request, 8 * 1024);
  const slug = await knownPage(env, body.page);
  const n = body.note || {};
  const text = typeof n.text === "string" ? n.text.trim().slice(0, 1000) : "";
  if (!text) throw new HttpError(400, "Write a note first.");
  const at = typeof n.at === "number" && isFinite(n.at) && n.at >= 0 ? Math.round(n.at * 10) / 10 : 0;
  const name = typeof n.name === "string" && n.name.trim() ? n.name.trim().slice(0, 60) : null;
  const quote = typeof n.quote === "string" ? n.quote.slice(0, 400) : null;
  const now = isoNow();

  const today = await env.DB.prepare("SELECT COUNT(*) AS n FROM notes WHERE page = ?1 AND created_at >= ?2")
    .bind(slug, now.slice(0, 10)).first();
  if ((today?.n ?? 0) >= MAX_NOTES_PER_PAGE_PER_DAY) throw new HttpError(429, "This page has had a lot of notes today. Try again tomorrow.");

  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO notes (id, page, name, text, at, quote, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
    .bind(id, slug, name, text, at, quote, now).run();
  return json({ ok: true, id });
}

async function getReactions(url, env) {
  const slug = url.searchParams.get("page") || "";
  if (!SLUG.test(slug)) return json({ reactions: [] });
  const { results } = await env.DB.prepare(
    "SELECT at, emoji FROM events WHERE page = ?1 AND kind = 'reaction' ORDER BY id DESC LIMIT 300"
  ).bind(slug).all();
  return json({ reactions: results }, 200, { "cache-control": "public, max-age=30" });
}

// ---------- Creator ----------

async function putFile(request, env, slug, file) {
  if (!SLUG.test(slug)) throw new HttpError(400, "That page name can't be used in a link.");
  if (!BUNDLE_FILES[file]) throw new HttpError(400, `Vision One doesn't publish ${file}.`);
  await env.FILES.put(`pages/${slug}/${file}`, request.body, { httpMetadata: { contentType: BUNDLE_FILES[file] } });
  if (file === "page.json" || file === "index.html") {
    let title = null;
    if (file === "page.json") {
      const stored = await env.FILES.get(`pages/${slug}/page.json`);
      try { title = String((await stored.json()).title || "").slice(0, 200) || null; } catch (_) {}
    }
    await env.DB.prepare(
      "INSERT INTO pages (slug, title, published_at) VALUES (?1, ?2, ?3) ON CONFLICT(slug) DO UPDATE SET title = COALESCE(?2, title), published_at = ?3"
    ).bind(slug, title, isoNow()).run();
  }
  return json({ ok: true, url: `${new URL(request.url).origin}/v/${slug}/` });
}

async function deletePage(env, slug) {
  if (!SLUG.test(slug)) throw new HttpError(400, "That page name can't be used in a link.");
  const listed = await env.FILES.list({ prefix: `pages/${slug}/` });
  if (listed.objects.length) await env.FILES.delete(listed.objects.map((o) => o.key));
  await env.DB.batch([
    env.DB.prepare("DELETE FROM pages WHERE slug = ?1").bind(slug),
    env.DB.prepare("DELETE FROM events WHERE page = ?1").bind(slug),
    env.DB.prepare("DELETE FROM notes WHERE page = ?1").bind(slug),
  ]);
  return json({ ok: true });
}

async function getInbox(url, env) {
  const slug = url.searchParams.get("page") || "";
  if (!SLUG.test(slug)) throw new HttpError(400, "Say which page.");
  // Notes from `since` on (Vision One skips ones it has by id); events
  // after the last id it saw, so none are missed or counted twice.
  const since = url.searchParams.get("since") || "1970-01-01T00:00:00Z";
  const after = Math.max(0, parseInt(url.searchParams.get("after") || "0", 10) || 0);
  const notes = await env.DB.prepare(
    "SELECT id, name, text, at, quote, created_at AS createdAt FROM notes WHERE page = ?1 AND created_at >= ?2 ORDER BY created_at LIMIT 1000"
  ).bind(slug, since).all();
  const events = await env.DB.prepare(
    "SELECT id, visit, kind, at, emoji, text, time FROM events WHERE page = ?1 AND id > ?2 ORDER BY id LIMIT 20000"
  ).bind(slug, after).all();
  const last = events.results.length ? events.results[events.results.length - 1].id : after;
  const clean = (row) => Object.fromEntries(Object.entries(row).filter(([, v]) => v !== null));
  return json({
    notes: notes.results.map((n) => ({ ...clean(n), done: false })),
    events: events.results.map(({ id, ...e }) => clean(e)),
    after: last,
    now: isoNow(),
  });
}

async function requireCreator(request, env) {
  const header = request.headers.get("authorization") || "";
  const given = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!env.CREATOR_KEY || !(await sameSecret(given, env.CREATOR_KEY))) {
    throw new HttpError(401, "Vision One's key for this account doesn't match. Reconnect Cloudflare in Vision One.");
  }
}

// Compares hashes so the time taken says nothing about the key.
async function sameSecret(a, b) {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(ha), y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0 && a.length > 0;
}

// ---------- Helpers ----------

async function knownPage(env, slug) {
  if (typeof slug !== "string" || !SLUG.test(slug)) throw new HttpError(400, "Unknown page.");
  const row = await env.DB.prepare("SELECT slug FROM pages WHERE slug = ?1").bind(slug).first();
  if (!row) throw new HttpError(404, "This page isn't published any more.");
  return slug;
}

async function readJSON(request, limit) {
  const text = await request.text();
  if (text.length > limit) throw new HttpError(413, "That's too much to send at once.");
  try {
    const value = JSON.parse(text);
    if (!value || typeof value !== "object") throw new Error();
    return value;
  } catch (_) {
    throw new HttpError(400, "That wasn't valid JSON.");
  }
}

function json(value, status = 200, extra = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "x-content-type-options": "nosniff", ...extra },
  });
}

function notFound() {
  return new Response("This video isn't here. It may have been taken down.", {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}
