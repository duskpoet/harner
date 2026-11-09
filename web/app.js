// harner web UI: mirrors every nvim's chats from the host (SSE /events),
// answers questions and confirms, sends prompts, cancels runs.
// Everything from the server is untrusted text: markdown goes through marked
// with raw HTML escaped and links limited to http(s)/mailto; everything else
// is set with textContent.
"use strict";

const SEP = "─".repeat(40);
const $ = (id) => document.getElementById(id);

// nvim id -> { id, pid, cwd, gone, chats: Map(chat id -> chat), pending: Map(call -> q) }
let nvims = new Map();
let sel = parseHash();
let loaded = false; // first snapshot seen (no notifications for old questions)

// ---------------------------------------------------------------------------
// Markdown

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

marked.use({
  gfm: true,
  renderer: {
    html(token) {
      return escapeHtml(token.text ?? token.raw ?? "");
    },
    link(token) {
      const label = this.parser.parseInline(token.tokens);
      const href = String(token.href || "");
      if (!/^(https?:|mailto:)/i.test(href)) return label;
      return `<a href="${escapeHtml(href)}" rel="noopener noreferrer nofollow" target="_blank">${label}</a>`;
    },
    image(token) {
      return escapeHtml(token.text || "");
    },
  },
});

// tool notes (`_→ nvim:show_text · …_`) follow each other on consecutive
// lines; a hard break keeps them one per line instead of one paragraph
const NOTE = /^_→ .*_$/;

function render(lines) {
  const md = lines.map((l) => (l === SEP ? "\n---\n" : NOTE.test(l) ? l + "  " : l)).join("\n");
  return marked.parse(md);
}

// ---------------------------------------------------------------------------
// State

function parseHash() {
  const m = location.hash.match(/^#(\d+)\/(\d+)$/);
  return m ? { nvim: +m[1], chat: +m[2] } : null;
}

function getNvim(id) {
  let nv = nvims.get(id);
  if (!nv) {
    nv = { id, pid: null, cwd: "", gone: false, chats: new Map(), pending: new Map() };
    nvims.set(id, nv);
  }
  return nv;
}

function getChat(nv, id) {
  let c = nv.chats.get(id);
  if (!c) {
    c = { id, title: null, state: null, auto: false, running: false, lines: [""] };
    nv.chats.set(id, c);
  }
  return c;
}

function splice(t, first, last, repl) {
  const n = t.length;
  first = Math.max(0, Math.min(first < 0 ? n : first, n));
  last = last < 0 ? n : Math.min(last, n);
  if (last < first) last = first;
  return t.slice(0, first).concat(repl, t.slice(last));
}

function apply(msg) {
  switch (msg.type) {
    case "snapshot": {
      nvims = new Map();
      for (const n of msg.nvims) {
        const nv = getNvim(n.id);
        Object.assign(nv, { pid: n.pid, cwd: n.cwd, gone: n.gone });
        for (const c of n.chats) Object.assign(getChat(nv, c.id), c);
        for (const q of n.pending) nv.pending.set(q.call, q);
      }
      loaded = true;
      return "all";
    }
    case "hello": {
      const nv = getNvim(msg.nvim);
      Object.assign(nv, { pid: msg.pid, cwd: msg.cwd, gone: false, chats: new Map(), pending: new Map() });
      return "all";
    }
    case "chat": {
      const c = getChat(getNvim(msg.nvim), msg.chat);
      for (const k of ["title", "state", "auto", "running"]) if (k in msg) c[k] = msg[k];
      return "list";
    }
    case "lines": {
      const c = getChat(getNvim(msg.nvim), msg.chat);
      c.lines = splice(c.lines, msg.first, msg.last, msg.lines);
      return sel && sel.nvim === msg.nvim && sel.chat === msg.chat ? "transcript" : null;
    }
    case "pending": {
      getNvim(msg.nvim).pending.set(msg.call, msg);
      if (loaded) notify(msg);
      return "all";
    }
    case "resolved": {
      getNvim(msg.nvim).pending.delete(msg.call);
      return "all";
    }
    case "gone": {
      const nv = getNvim(msg.nvim);
      nv.gone = true;
      nv.pending = new Map();
      for (const c of nv.chats.values()) c.running = false;
      return "all";
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Rendering

let dirty = new Set();
function schedule(what) {
  if (!what) return;
  dirty.add(what);
  requestAnimationFrame(flush);
}

function flush() {
  if (dirty.size === 0) return;
  const all = dirty.has("all");
  if (all || dirty.has("list")) renderList();
  if (all || dirty.has("list")) renderPending();
  if (all || dirty.has("transcript") || dirty.has("list")) renderTranscript();
  renderForm();
  updateTitle();
  dirty.clear();
}

function pendingFor(nv, chatId) {
  return [...nv.pending.values()].filter((q) => q.chat === chatId || (q.chat === null && chatId === null));
}

function el(tag, attrs = {}, text) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else e.setAttribute(k, v);
  }
  if (text !== undefined) e.textContent = text;
  return e;
}

function renderList() {
  const list = $("list");
  list.replaceChildren();
  const sorted = [...nvims.values()].sort((a, b) => a.id - b.id);
  for (const nv of sorted) {
    const box = el("div", { class: "nvim" + (nv.gone ? " gone" : "") });
    box.append(el("h2", { title: nv.cwd || "" }, `nvim ${nv.pid ?? "?"} · ${nv.cwd || ""}`));
    const chats = [...nv.chats.values()].sort((a, b) => a.id - b.id);
    for (const c of chats) {
      const a = el("a", { href: `#${nv.id}/${c.id}` });
      if (sel && sel.nvim === nv.id && sel.chat === c.id) a.classList.add("sel");
      a.append(el("span", { class: "t" }, `#${c.id} ${c.title || "(empty)"}`));
      const asks = pendingFor(nv, c.id).length;
      if (asks) a.append(el("span", { class: "badge ask", title: "waiting for you" }, String(asks)));
      if (c.running) a.append(el("span", { class: "badge run" }, "running"));
      if (c.auto) a.append(el("span", { class: "badge auto" }, "AUTO"));
      box.append(a);
    }
    // questions from a call with no chat id
    const loose = pendingFor(nv, null).length;
    if (loose) box.append(el("div", { class: "muted" }, `${loose} question(s) outside a chat`));
    list.append(box);
  }
}

function selected() {
  if (!sel) return null;
  const nv = nvims.get(sel.nvim);
  const c = nv && nv.chats.get(sel.chat);
  return c ? { nv, c } : null;
}

function renderTranscript() {
  const s = selected();
  const t = $("transcript");
  $("empty").hidden = !!s;
  if (!s) {
    t.replaceChildren();
    $("title").textContent = "harner";
    return;
  }
  $("title").textContent = `#${s.c.id} ${s.c.title || "(empty)"}${s.c.state ? " · " + s.c.state : ""}`;
  const atBottom = t.scrollHeight - t.scrollTop - t.clientHeight < 40;
  t.innerHTML = render(s.c.lines);
  if (atBottom) t.scrollTop = t.scrollHeight;
}

// Cards are kept by key across renders so a half-typed answer survives
// unrelated updates; only questions that came or went change.
function renderPending() {
  const box = $("pending");
  const s = selected();
  const qs = s ? pendingFor(s.nv, s.c.id).concat(pendingFor(s.nv, null)) : [];
  const want = new Map(qs.map((q) => [`${s.nv.id}-${q.call}`, q]));
  for (const node of [...box.children]) {
    if (!want.has(node.dataset.key)) node.remove();
  }
  const have = new Set([...box.children].map((n) => n.dataset.key));
  for (const [key, q] of want) {
    if (have.has(key)) continue;
    const c = card(s.nv, q);
    c.dataset.key = key;
    box.append(c);
  }
}

function card(nv, q) {
  const c = el("div", { class: "card" });
  c.append(el("h3", {}, q.title || "Question"));
  c.append(el("pre", {}, (q.body || []).join("\n")));
  if (q.note) c.append(el("div", { class: "note" }, q.note));
  if (Array.isArray(q.items)) {
    const items = el("div", { class: "items" });
    q.items.forEach((item, i) => {
      const b = el("button", { type: "button" }, `${i + 1}. ${item}`);
      b.addEventListener("click", () => answer(nv.id, q.call, "item", i + 1));
      items.append(b);
    });
    c.append(items);
  }
  let input;
  if (q.input) {
    input = el("textarea", { rows: "3", placeholder: "Your answer" });
    c.append(input);
  }
  const keys = el("div", { class: "keys" });
  if (q.input) {
    const b = el("button", { type: "button", class: "primary" }, "Send answer");
    b.addEventListener("click", () => answer(nv.id, q.call, "text", input.value));
    keys.append(b);
  }
  for (const k of q.keys || []) {
    const cls = k.value === "yes" ? "primary" : k.value === "no" ? "danger" : "";
    const b = el("button", { type: "button", class: cls }, `${k.label} (${k.key})`);
    b.addEventListener("click", () => answer(nv.id, q.call, k.value));
    keys.append(b);
  }
  c.append(keys);
  return c;
}

function renderForm() {
  const s = selected();
  const form = $("promptForm");
  form.hidden = !s;
  if (!s) return;
  const live = !s.nv.gone;
  $("prompt").disabled = !live;
  $("send").disabled = !live || s.c.running;
  $("cancel").disabled = !live || !s.c.running;
  $("status").textContent = !live ? "this nvim has exited (read-only)" : s.c.running ? "running…" : "";
}

function updateTitle() {
  let n = 0;
  for (const nv of nvims.values()) n += nv.pending.size;
  document.title = n ? `(${n}) harner` : "harner";
}

// ---------------------------------------------------------------------------
// Actions

async function post(path, body) {
  try {
    const r = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "same-origin",
    });
    const j = await r.json().catch(() => ({ ok: false, error: `HTTP ${r.status}` }));
    if (!j.ok) alert(j.error || "failed");
    return j.ok;
  } catch (e) {
    alert(String(e));
    return false;
  }
}

function answer(nvim, call, choice, arg) {
  post("/api/answer", { nvim, call, choice, arg: arg === undefined ? null : arg });
}

$("promptForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const s = selected();
  const text = $("prompt").value;
  if (!s || !text.trim()) return;
  if (await post("/api/prompt", { nvim: s.nv.id, chat: s.c.id, text })) $("prompt").value = "";
});
$("prompt").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) $("promptForm").requestSubmit();
});
$("cancel").addEventListener("click", () => {
  const s = selected();
  if (s) post("/api/cancel", { nvim: s.nv.id, chat: s.c.id });
});
$("menu").addEventListener("click", () => $("list").classList.toggle("open"));
window.addEventListener("hashchange", () => {
  sel = parseHash();
  $("list").classList.remove("open");
  schedule("all");
});

// ---------------------------------------------------------------------------
// Notifications (need a secure context: localhost or HTTPS; over plain HTTP
// on another address only the title badge is available)

function notify(q) {
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  const n = new Notification(q.title || "harner asks", { body: (q.body || []).join("\n").slice(0, 200), tag: `q${q.nvim}-${q.call}` });
  n.onclick = () => {
    window.focus();
    if (q.chat !== null) location.hash = `#${q.nvim}/${q.chat}`;
  };
}
if ("Notification" in window && window.isSecureContext && Notification.permission === "default") {
  const b = $("notify");
  b.hidden = false;
  b.addEventListener("click", () => Notification.requestPermission().then(() => (b.hidden = true)));
}

// ---------------------------------------------------------------------------
// Event stream

function connect() {
  const es = new EventSource("/events");
  es.onopen = () => $("conn").classList.add("on");
  es.onerror = () => $("conn").classList.remove("on");
  es.onmessage = (e) => {
    let msg;
    try {
      msg = JSON.parse(e.data);
    } catch {
      return;
    }
    schedule(apply(msg));
  };
}
connect();
