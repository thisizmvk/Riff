// Offline harness for player-bridge.js — stubs the browser surface,
// evals the bridge, then drives __riffDebug.emitQueueSnapshot against
// simulated page-store shapes (including the proxy-wrapped ytmusic-app
// observed live on 2026-08-25).
import { readFileSync } from "node:fs";

let passes = 0, failures = 0;
function check(cond, label) {
  if (cond) { passes++; } else { failures++; console.log("FAIL: " + label); }
}

// ---- Browser surface stubs ------------------------------------------------
const posted = [];
const elements = new Map();   // selector -> element
const lists = new Map();      // selector -> element[] (querySelectorAll)
global.window = global;
global.location = { href: "https://music.youtube.com/watch?v=abc", hash: "", origin: "https://music.youtube.com" };
global.document = {
  readyState: "complete",
  querySelector: (sel) => elements.get(sel) || null,
  querySelectorAll: (sel) => lists.get(sel) || [],
  getElementById: () => null,
  addEventListener: () => {},
  documentElement: {},
};
global.URL = URL;
global.MutationObserver = class { observe() {} disconnect() {} };
global.webkit = { messageHandlers: { bridge: { postMessage: (p) => posted.push(p) } } };
global.window.webkit = global.webkit;
// setup() will retry via setTimeout(…, 500) — run only SHORT timers
// (the 0ms/300ms snapshot + verification shots) immediately, so async
// pipelines complete without letting setup() recurse forever.
const realSetTimeout = setTimeout;
global.setInterval = () => 0;
global.clearInterval = () => {};
global.setTimeout = (fn, delay) => {
  if (typeof fn === "function" && (delay ?? 0) < 500) { fn(); }
  return 0;
};
const settle = () => new Promise((r) => realSetTimeout(r, 5));

// ---- Load the bridge ------------------------------------------------------
const src = readFileSync(process.argv[2] ?? "../../../Riff/Resources/player-bridge.js", "utf8");
(0, eval)(src);
check(typeof window.musicBridge === "object", "musicBridge defined");
check(typeof window.__riffDebug?.emitQueueSnapshot === "function", "__riffDebug hook exposed");

function snap() {
  posted.length = 0;
  window.__riffQueueSig = undefined;
  window.__riffQueueShapeReported = false;
  window.__riffQueueSnapErrLogged = false;
  window.__riffDebug.emitQueueSnapshot();
  return {
    snapshots: posted.filter((p) => p.event === "queueSnapshot"),
    diags: posted.filter((p) => p.event === "diagnostic").map((d) => d.msg),
  };
}

const renderer = (id, title, byline, selected = false) => ({
  playlistPanelVideoRenderer: {
    videoId: id,
    title: { runs: [{ text: title }] },
    longBylineText: { runs: [{ text: byline }, { text: " • " }, { text: "Album" }] },
    thumbnail: { thumbnails: [{ url: `https://x/${id}-small.jpg` }, { url: `https://x/${id}-big.jpg` }] },
    selected,
  },
});
const wrapped = (id, title, byline, selected = false) => ({
  playlistPanelVideoWrapperRenderer: {
    primaryRenderer: renderer(id, title, byline, selected).playlistPanelVideoRenderer
      ? { playlistPanelVideoRenderer: renderer(id, title, byline, selected).playlistPanelVideoRenderer }
      : null,
  },
});
// fix: wrapper builds directly
const wrap = (id, title, byline, selected = false) => ({
  playlistPanelVideoWrapperRenderer: {
    primaryRenderer: { playlistPanelVideoRenderer: renderer(id, title, byline, selected).playlistPanelVideoRenderer },
  },
});

// ---- Case 1: nothing anywhere → one-shot diagnostic, no snapshot ----------
{
  elements.clear();
  const { snapshots, diags } = snap();
  check(snapshots.length === 0, "no elements → no snapshot");
  check(diags.some((m) => m.includes("no-queue-anywhere")), "no elements → probe diagnostic");
}

// ---- Case 2: classic app.store path ---------------------------------------
{
  elements.clear();
  elements.set("ytmusic-app", {
    store: { getState: () => ({ queue: { items: [renderer("v1", "One", "A1", true), renderer("v2", "Two", "A2")], automixItems: [renderer("v3", "Three", "A3")] } }) },
  });
  const { snapshots } = snap();
  check(snapshots.length === 1, "app.store → snapshot emitted");
  const rows = snapshots[0]?.items ?? [];
  check(rows.length === 3, "items ∪ automixItems rows");
  check(rows[0]?.videoId === "v1" && rows[0]?.selected === true, "selected flag mirrored");
  check(rows[0]?.title === "One" && rows[0]?.byline === "A1 • Album", "runs joined for title/byline");
  check(rows[0]?.thumbnail.endsWith("-small.jpg"), "SMALLEST thumbnail variant chosen");
}

// ---- Case 3: proxy-wrapped app (live 2026-08 shape): store on .inst -------
{
  elements.clear();
  elements.set("ytmusic-app", {
    inst: { store: { getState: () => ({ queue: { items: [renderer("p1", "P1", "B1")] } }) } },
  });
  const { snapshots } = snap();
  check(snapshots.length === 1 && snapshots[0].items[0].videoId === "p1", "app.inst.store path resolves");
}

// ---- Case 4: player-bar .queue with direct items (live alt shape) ---------
{
  elements.clear();
  elements.set("ytmusic-app", { inst: {} });   // app exists but no store anywhere on it
  elements.set("ytmusic-player-bar", {
    queue: { items: [wrap("w1", "W1", "C1", true), renderer("w2", "W2", "C2")] },
  });
  const { snapshots } = snap();
  check(snapshots.length === 1, "player-bar .queue direct-items path resolves");
  const rows = snapshots[0]?.items ?? [];
  check(rows.length === 2 && rows[0].videoId === "w1", "wrapper renderer unwrapped");
}

// ---- Case 5: player-bar .queue.getState() nesting -------------------------
{
  elements.clear();
  elements.set("ytmusic-player-bar", {
    queue: { getState: () => ({ items: [renderer("g1", "G1", "D1")] }) },
  });
  const { snapshots } = snap();
  check(snapshots.length === 1 && snapshots[0].items[0].videoId === "g1", "queue.getState() path resolves");
}

// ---- Case 6: flat item shape (no renderer wrapper) ------------------------
{
  elements.clear();
  elements.set("ytmusic-player-bar", {
    queue: { items: [{ videoId: "f1", title: "Flat", longBylineText: "FlatArtist", thumbnail: { thumbnails: [{ url: "https://x/f1.jpg" }] }, selected: true }] },
  });
  const { snapshots } = snap();
  const row = snapshots[0]?.items?.[0];
  check(row?.videoId === "f1" && row?.title === "Flat" && row?.byline === "FlatArtist", "flat item shape accepted, string text passthrough");
}

// ---- Case 7: unknown queue-prop shape → diagnostic with keys --------------
{
  elements.clear();
  elements.set("ytmusic-player-bar", { queue: { somethingElse: 1, weird: 2 } });
  const { snapshots, diags } = snap();
  check(snapshots.length === 0, "unknown shape → no snapshot");
  check(diags.some((m) => m.includes("queue-prop-unknown-shape") && m.includes("somethingElse")), "unknown shape → keys reported");
}

// ---- Case 8: sig dedup — same queue twice emits once ----------------------
{
  elements.clear();
  const state = { queue: { items: [renderer("d1", "D1", "E1", true), renderer("d2", "D2", "E2")] } };
  elements.set("ytmusic-app", { store: { getState: () => state } });
  posted.length = 0;
  window.__riffQueueSig = undefined;
  window.__riffDebug.emitQueueSnapshot();
  window.__riffDebug.emitQueueSnapshot();   // unchanged → deduped
  const count1 = posted.filter((p) => p.event === "queueSnapshot").length;
  check(count1 === 1, "unchanged queue emits exactly once");
  // Advance the selected row → sig changes → re-emit.
  state.queue.items = [renderer("d1", "D1", "E1"), renderer("d2", "D2", "E2", true)];
  window.__riffDebug.emitQueueSnapshot();
  const count2 = posted.filter((p) => p.event === "queueSnapshot").length;
  check(count2 === 2, "selected-row advance re-emits");
}

// ---- Case 9: 80-row cap ---------------------------------------------------
{
  elements.clear();
  const many = Array.from({ length: 120 }, (_, i) => renderer("m" + i, "M" + i, "A"));
  elements.set("ytmusic-app", { store: { getState: () => ({ queue: { items: many } }) } });
  const { snapshots } = snap();
  check((snapshots[0]?.items?.length ?? 0) === 80, "payload capped at 80 rows");
}

// ---- Case 10: rows without videoId skipped --------------------------------
{
  elements.clear();
  elements.set("ytmusic-app", {
    store: { getState: () => ({ queue: { items: [{ playlistPanelVideoRenderer: { title: { runs: [{ text: "NoId" }] } } }, renderer("ok1", "OK", "A")] } }) },
  });
  const { snapshots } = snap();
  check(snapshots[0]?.items?.length === 1 && snapshots[0].items[0].videoId === "ok1", "id-less rows skipped");
}

// ---- Case 11a: queueAddViaPage — store dispatch OFF by default -------------
{
  elements.clear(); lists.clear();
  elements.set("ytmusic-app", { store: { getState: () => ({ queue: { items: [renderer("d1", "D1", "A", true)] } }), dispatch: () => { throw new Error("must not dispatch"); } } });
  posted.length = 0;
  window.__riffStoreDispatchEnabled = undefined;
  window.musicBridge.queueAddViaPage("d2", "next");
  await settle();
  const rd = posted.filter((p) => p.event === "queueAddResult");
  check(rd.length === 1 && rd[0].ok === false && rd[0].via === "store-dispatch-disabled", "default: no store dispatch for add → ok=false store-dispatch-disabled (Swift keeps its path)");
}

// ---- Case 11: queueAddViaPage happy path (dispatch + verify, opt-in) -------
{
  window.__riffStoreDispatchEnabled = true;
  elements.clear();
  const dispatched = [];
  // Fake store whose dispatch behaves like YT's ADD_ITEMS reducer:
  // splices the items in at payload.index.
  const state = { queue: { items: [renderer("q1", "Q1", "A", true), renderer("q2", "Q2", "A")], nextQueueItemId: 77 } };
  elements.set("ytmusic-app", {
    store: {
      getState: () => state,
      dispatch: (a) => {
        dispatched.push(a);
        if (a.type === "ADD_ITEMS") state.queue.items.splice(a.payload.index, 0, ...a.payload.items);
      },
    },
    networkManager: {
      fetch: async (path, body) => ({
        queueDatas: [{ content: renderer(body.videoIds[0], "Injected", "AI") }],
      }),
    },
  });
  posted.length = 0;
  window.__riffQueueSig = undefined;
  window.musicBridge.queueAddViaPage("z1", "next");
  await settle();
  const results = posted.filter((p) => p.event === "queueAddResult");
  check(results.length === 1 && results[0].ok === true, "verified add reports ok=true (got " + JSON.stringify(results) + ")");
  const add = dispatched.find((a) => a.type === "ADD_ITEMS");
  check(!!add && add.payload.index === 1, "ADD_ITEMS lands after the selected row (index 1)");
  check(add?.payload.items?.[0]?.playlistPanelVideoRenderer?.videoId === "z1", "real fetched renderer dispatched, not a hand-built shape");
  check(posted.some((p) => p.event === "queueSnapshot" && p.items.some((r) => r.videoId === "z1")), "mirror re-emitted including the injected row");
}

// ---- Case 12: queueAddViaPage failure paths -------------------------------
{
  elements.clear();
  posted.length = 0;
  window.musicBridge.queueAddViaPage("z2", "end");
  await settle();
  let r = posted.filter((p) => p.event === "queueAddResult");
  check(r.length === 1 && r[0].ok === false && r[0].via === "no-dispatcher", "no dispatcher → ok=false with reason");

  elements.set("ytmusic-app", { store: { getState: () => ({ queue: { items: [] } }), dispatch: () => {} } });
  posted.length = 0;
  window.musicBridge.queueAddViaPage("z3", "end");
  await settle();
  r = posted.filter((p) => p.event === "queueAddResult");
  check(r.length === 1 && r[0].ok === false && r[0].via.startsWith("no-items"), "no renderers fetchable → ok=false no-items");
}

// ---- Case 13: queueRemoveViaPage — page's own row menu, never the store ----
{
  window.__riffStoreDispatchEnabled = undefined;
  const MENU_ITEMS_SEL = "ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, tp-yt-paper-listbox ytmusic-menu-service-item-renderer";
  const mkRow = (id, opened) => ({
    data: renderer(id, id, "A"),
    querySelector: (sel) => sel.startsWith("a[") ? { href: "https://music.youtube.com/watch?v=" + id } : { click: () => opened.push(id) },
  });
  const mkStore = (state, dispatched) => ({ store: { getState: () => state, dispatch: (a) => { dispatched.push(a); } } });

  // (a) list row: removed through the row menu; the store is never dispatched to.
  elements.clear(); lists.clear();
  const dispatched = []; const opened = [];
  const state = { queue: { items: [renderer("r1", "R1", "A", true), renderer("r2", "R2", "A"), renderer("r3", "R3", "A")] } };
  elements.set("ytmusic-app", mkStore(state, dispatched));
  lists.set("ytmusic-player-queue-item", [mkRow("r1", opened), mkRow("r2", opened), mkRow("r3", opened)]);
  lists.set(MENU_ITEMS_SEL, [
    { textContent: "Save to playlist", querySelector: () => null, click: () => {} },
    { textContent: " Remove from queue ", querySelector: () => null,
      click: () => { state.queue.items = state.queue.items.filter((r) => r.playlistPanelVideoRenderer.videoId !== "r2"); } },
  ]);
  posted.length = 0; window.__riffQueueSig = undefined;
  window.musicBridge.queueRemoveViaPage("r2");
  await settle();
  const r = posted.filter((p) => p.event === "queueRemoveResult");
  check(r.length === 1 && r[0].ok === true && r[0].via === "menu:removed", "list row removed via the row's own menu → ok=true menu:removed");
  check(opened.length === 1 && opened[0] === "r2", "menu opened on the identity-matched row only");
  check(dispatched.length === 0, "no store dispatch for removal (desyncs store from player)");
  check(posted.some((p) => p.event === "queueSnapshot" && !p.items.some((row) => row.videoId === "r2")), "mirror re-emitted without the removed row");

  // (b) automix row: same path.
  elements.clear(); lists.clear();
  const opened2 = []; const dispatched2 = [];
  const state2 = { queue: { items: [renderer("r1", "R1", "A", true)], automixItems: [renderer("m1", "M1", "A"), renderer("m2", "M2", "A")] } };
  elements.set("ytmusic-app", mkStore(state2, dispatched2));
  lists.set("ytmusic-player-queue-item", [mkRow("m1", opened2), mkRow("m2", opened2)]);
  lists.set(MENU_ITEMS_SEL, [{ textContent: "Remove from queue", querySelector: () => null,
    click: () => { state2.queue.automixItems = state2.queue.automixItems.filter((x) => x.playlistPanelVideoRenderer.videoId !== "m2"); } }]);
  posted.length = 0; window.__riffQueueSig = undefined;
  window.musicBridge.queueRemoveViaPage("m2");
  await settle();
  const rb = posted.filter((p) => p.event === "queueRemoveResult");
  check(rb.length === 1 && rb[0].ok === true && rb[0].via === "menu:removed", "automix row removed via the row menu");
  check(state2.queue.automixItems.length === 1 && state2.queue.automixItems[0].playlistPanelVideoRenderer.videoId === "m1" && dispatched2.length === 0, "only the target left the tail; no store dispatch");

  // (c) menu has no remove item → honest failure, queue untouched (Swift restores the row + toasts).
  state2.queue.automixItems.push(renderer("m3", "M3", "A"));
  lists.set("ytmusic-player-queue-item", [mkRow("m1", opened2), mkRow("m3", opened2)]);
  lists.set(MENU_ITEMS_SEL, []);
  posted.length = 0;
  window.musicBridge.queueRemoveViaPage("m3");
  await settle();
  const rc = posted.filter((p) => p.event === "queueRemoveResult");
  check(rc.length === 1 && rc[0].ok === false && rc[0].via === "menu:no-remove-item", "no remove item in the menu → ok=false menu:no-remove-item");
  check(state2.queue.automixItems.length === 2, "failed removal leaves the queue untouched");

  // (d) unknown id → not-in-items, no menu opened.
  posted.length = 0; opened2.length = 0;
  window.musicBridge.queueRemoveViaPage("nope");
  await settle();
  const r2 = posted.filter((p) => p.event === "queueRemoveResult");
  check(r2.length === 1 && r2[0].ok === false && r2[0].via === "not-in-items" && opened2.length === 0, "unknown id → ok=false not-in-items, nothing opened");
}

// ---- Case 14: queuePlayItem — identity-verified in-place jump -----------
{
  elements.clear(); lists.clear();
  const state = { queue: { items: [renderer("j1", "J1", "A", true), renderer("j2", "J2", "A"), renderer("j3", "J3", "A")] } };
  elements.set("ytmusic-app", { store: { getState: () => state, dispatch: () => {} } });
  const clicked = [];
  // Rows deliberately in a DIFFERENT order than the store, with the
  // videoId bound on the row's data — the old index-based click would
  // have hit the wrong one.
  const mkRow = (id) => ({ data: renderer(id, id, "A"), querySelector: () => ({ click: () => clicked.push(id) }), click: () => clicked.push(id + "-row") });
  lists.set("ytmusic-player-queue-item", [mkRow("j3"), mkRow("j1"), mkRow("j2")]);
  posted.length = 0;
  check(window.musicBridge.queuePlayItem("j2") === true && clicked.at(-1) === "j2", "clicks the row whose OWN data matches the id, regardless of position");
  check(window.musicBridge.queuePlayItem("nope") === false && clicked.at(-1) === "j2", "unknown id → no click at all");
  check(posted.some((p) => p.event === "diagnostic" && p.msg.includes("no identity-matched row")), "unknown id → diagnostic");
  // Row identified via inner watch link when no data property exists.
  lists.set("ytmusic-player-queue-item", [{ querySelector: (sel) => sel.startsWith("a[") ? { href: "https://music.youtube.com/watch?v=j1&list=x" } : { click: () => clicked.push("j1-link") } }]);
  check(window.musicBridge.queuePlayItem("j1") === true && clicked.at(-1) === "j1-link", "falls back to the row's watch link for identity");
  // No rows rendered → refuses (no playVideoAt index guessing anymore).
  lists.clear();
  const played = [];
  elements.set("ytmusic-player", { playerApi: { playVideoAt: (i) => played.push(i), getVideoData: () => ({}), addEventListener: () => {} } });
  check(window.musicBridge.queuePlayItem("j2") === false && played.length === 0, "no rows → returns false, never index-guesses via playVideoAt");
}

// ═══════════════════════════════════════════════════════════════════
// Cases 15–21 (QA batch 2026-09-10).
// Reuses the harness's stubs: posted, elements, lists, renderer, wrap,
// snap, settle, check, src. Cases 15–21.
// ═══════════════════════════════════════════════════════════════════

const MENU_SEL = "ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, tp-yt-paper-listbox ytmusic-menu-service-item-renderer";
const rowWith = (id, extra = {}) => ({
  data: renderer(id, id, "A"),
  querySelector: (sel) => sel.startsWith("a[") ? { href: "https://music.youtube.com/watch?v=" + id } : (extra.button === false ? null : { click: () => (extra.opened || []).push(id) }),
});
const storeOf = (state, dispatched = []) => ({ store: { getState: () => state, dispatch: (a) => dispatched.push(a) } });

// ---- Case 15: emitQueueSnapshot shape edge cases --------------------------
{
  // (a) automix-only queue (album drained; page padded with radio) — rows still emitted, selected honored.
  elements.clear(); lists.clear();
  elements.set("ytmusic-app", storeOf({ queue: { automixItems: [renderer("x1", "X1", "A", true), renderer("x2", "X2", "A")] } }));
  let r = snap();
  check(r.snapshots.length === 1 && r.snapshots[0].items.map((i) => i.videoId).join() === "x1,x2" && r.snapshots[0].items[0].selected === true, "automix-only queue mirrors with its selected row");

  // (b) wrapper without primaryRenderer is skipped; the rest survive.
  elements.clear();
  elements.set("ytmusic-app", storeOf({ queue: { items: [{ playlistPanelVideoWrapperRenderer: { counterpart: [] } }, renderer("ok", "OK", "A")] } }));
  r = snap();
  check(r.snapshots[0]?.items?.length === 1 && r.snapshots[0].items[0].videoId === "ok", "wrapper lacking primaryRenderer is skipped, not fatal");

  // (c) byline falls back to shortBylineText; title accepts simpleText; empty thumbnails → "".
  elements.clear();
  elements.set("ytmusic-app", storeOf({ queue: { items: [{ playlistPanelVideoRenderer: { videoId: "s1", title: { simpleText: "Simple" }, shortBylineText: { runs: [{ text: "Short" }] }, thumbnail: { thumbnails: [] } } }] } }));
  r = snap();
  const row = r.snapshots[0]?.items?.[0];
  check(row?.title === "Simple" && row?.byline === "Short" && row?.thumbnail === "", "simpleText title, shortByline fallback, empty thumbnail list → ''");

  // (d) shuffleEnabled mirrored as boolean, null when absent/non-boolean.
  elements.clear();
  elements.set("ytmusic-app", storeOf({ queue: { items: [renderer("h1", "H1", "A", true)], shuffleEnabled: true } }));
  check(snap().snapshots[0]?.shuffleEnabled === true, "page shuffle=true is mirrored");
  elements.set("ytmusic-app", storeOf({ queue: { items: [renderer("h1", "H1", "A", true)], shuffleEnabled: "yes" } }));
  check(snap().snapshots[0]?.shuffleEnabled === null, "non-boolean shuffle flag is reported as null (unknown), never coerced");

  // (e) signature covers ids + selected ONLY: a title-only change does not re-emit (documented).
  elements.clear();
  const st = { queue: { items: [renderer("t1", "Old", "A", true)] } };
  elements.set("ytmusic-app", storeOf(st));
  posted.length = 0; window.__riffQueueSig = undefined;
  window.__riffDebug.emitQueueSnapshot();
  st.queue.items = [renderer("t1", "New title", "A", true)];
  window.__riffDebug.emitQueueSnapshot();
  check(posted.filter((p) => p.event === "queueSnapshot").length === 1, "DOCUMENTED: a metadata-only change (same ids, same selection) is deduped by the signature");

  // (f) no selected row anywhere → still emits (Swift slices after the current videoId instead).
  elements.clear();
  elements.set("ytmusic-app", storeOf({ queue: { items: [renderer("n1", "N1", "A"), renderer("n2", "N2", "A")] } }));
  r = snap();
  check(r.snapshots.length === 1 && r.snapshots[0].items.every((i) => i.selected === false), "no selected row → snapshot still emitted with selected=false everywhere (Swift-side fallback slices by current id)");

  // (g) resolver: ytmusic-player-queue element paths (.queue.getState().queue nested, .queue.store nested, player-bar .queue.store flat).
  elements.clear();
  elements.set("ytmusic-player-queue", { queue: { getState: () => ({ queue: { items: [renderer("pq1", "PQ", "A")] } }) } });
  r = snap();
  check(r.snapshots[0]?.items?.[0]?.videoId === "pq1", "player-queue .queue.getState().queue nested path resolves");
  elements.clear();
  elements.set("ytmusic-player-queue", { queue: { store: { getState: () => ({ queue: { items: [renderer("ps1", "PS", "A")] } }) } } });
  r = snap();
  check(r.snapshots[0]?.items?.[0]?.videoId === "ps1", "player-queue .queue.store nested path resolves");
  elements.clear();
  elements.set("ytmusic-player-bar", { queue: { store: { getState: () => ({ items: [renderer("pf1", "PF", "A")] }) } } });
  r = snap();
  check(r.snapshots[0]?.items?.[0]?.videoId === "pf1", "player-bar .queue.store flat path resolves");

  // (h) a store whose getState throws → one diagnostic, no snapshot, no crash.
  elements.clear();
  elements.set("ytmusic-app", { store: { getState: () => { throw new Error("boom"); } } });
  r = snap();
  check(r.snapshots.length === 0 && r.diags.some((m) => m.includes("queueSnapshot failed")), "throwing store → one 'queueSnapshot failed' diagnostic, nothing emitted");
  // (i) app.store present but state has no queue → falls through to player elements.
  elements.clear();
  elements.set("ytmusic-app", { store: { getState: () => ({}) } });
  elements.set("ytmusic-player-bar", { queue: { items: [renderer("fb1", "FB", "A")] } });
  r = snap();
  check(r.snapshots[0]?.items?.[0]?.videoId === "fb1", "queue-less app state falls through to the player-bar queue");
}

// ---- Case 16: requestQueueSnapshot ----------------------------------------
{
  elements.clear(); lists.clear();
  const st = { queue: { items: [renderer("q1", "Q1", "A", true), renderer("q2", "Q2", "A")] } };
  elements.set("ytmusic-app", storeOf(st));
  posted.length = 0; window.__riffQueueSig = undefined;
  window.__riffDebug.emitQueueSnapshot();
  window.__riffDebug.emitQueueSnapshot();
  check(posted.filter((p) => p.event === "queueSnapshot").length === 1, "baseline: unchanged queue deduped");
  const ret = window.musicBridge.requestQueueSnapshot();
  check(ret === true && posted.filter((p) => p.event === "queueSnapshot").length === 2, "requestQueueSnapshot bypasses the signature and re-emits the unchanged queue");
  check(posted.at(-1).items.length === 2 && posted.at(-1).items[0].videoId === "q1", "forced snapshot carries the full current queue");
  elements.clear();
  posted.length = 0;
  let threw = false;
  try { window.musicBridge.requestQueueSnapshot(); } catch (_) { threw = true; }
  check(!threw && posted.filter((p) => p.event === "queueSnapshot").length === 0, "requestQueueSnapshot with no queue anywhere: no throw, no snapshot");
}

// ---- Case 17: queuePlayItem identity sources ------------------------------
{
  elements.clear(); lists.clear();
  const clicked = [];
  const mk = (props, id) => ({ ...props, querySelector: () => ({ click: () => clicked.push(id) }) });
  lists.set("ytmusic-player-queue-item", [
    mk({ queueItem: renderer("qi", "QI", "A") }, "qi"),
    mk({ item: { videoId: "it" } }, "it"),
    mk({ __data: { data: wrap("dd", "DD", "A") } }, "dd"),
  ]);
  check(window.musicBridge.queuePlayItem("qi") && clicked.at(-1) === "qi", "identity via row.queueItem");
  check(window.musicBridge.queuePlayItem("it") && clicked.at(-1) === "it", "identity via row.item (flat videoId)");
  check(window.musicBridge.queuePlayItem("dd") && clicked.at(-1) === "dd", "identity via row.__data.data (wrapper renderer)");
  // Row whose only link has no v= param → unidentifiable → never clicked.
  lists.set("ytmusic-player-queue-item", [{ querySelector: (sel) => sel.startsWith("a[") ? { href: "https://music.youtube.com/playlist?list=PL1" } : { click: () => clicked.push("BAD") } }]);
  check(window.musicBridge.queuePlayItem("PL1") === false && clicked.at(-1) !== "BAD", "a row with no identifiable videoId is never clicked");
  // Duplicate rows → the first identity match is clicked.
  lists.set("ytmusic-player-queue-item", [mk({ data: renderer("dup", "D", "A") }, "first"), mk({ data: renderer("dup", "D", "A") }, "second")]);
  check(window.musicBridge.queuePlayItem("dup") && clicked.at(-1) === "first", "duplicate ids: first rendered row wins");
  // No play button inside the row → the row itself is clicked.
  let rowClicked = false;
  lists.set("ytmusic-player-queue-item", [{ data: renderer("bare", "B", "A"), querySelector: () => null, click: () => { rowClicked = true; } }]);
  check(window.musicBridge.queuePlayItem("bare") === true && rowClicked, "no play button → the row element itself is clicked");
  // A row whose data getter throws is skipped, later rows still match.
  lists.set("ytmusic-player-queue-item", [{ get data() { throw new Error("getter"); }, querySelector: () => null }, mk({ data: renderer("after", "A", "A") }, "after")]);
  check(window.musicBridge.queuePlayItem("after") && clicked.at(-1) === "after", "a throwing row getter is skipped; later rows still identity-match");
}

// ---- Case 18: queueRemoveViaPage — every removeViaRowMenu branch -------------
{
  const run = async (id) => { posted.length = 0; window.__riffQueueSig = undefined; window.musicBridge.queueRemoveViaPage(id); await settle(); return posted.filter((p) => p.event === "queueRemoveResult")[0]; };
  const snapsAfter = () => posted.filter((p) => p.event === "queueSnapshot").length;
  // (a) in store, but no row rendered → menu:no-row, queue untouched, no re-emit.
  elements.clear(); lists.clear();
  const dispatched = [];
  const st = { queue: { items: [renderer("a", "A", "A", true), renderer("b", "B", "A")] } };
  elements.set("ytmusic-app", storeOf(st, dispatched));
  lists.set("ytmusic-player-queue-item", []);
  let res = await run("b");
  check(res?.ok === false && res.via === "menu:no-row" && st.queue.items.length === 2 && snapsAfter() === 0, "row not rendered → ok=false menu:no-row; nothing re-emitted");
  // (b) row rendered without a menu button.
  lists.set("ytmusic-player-queue-item", [rowWith("b", { button: false })]);
  res = await run("b");
  check(res?.ok === false && res.via === "menu:no-button", "row without a ⋯ button → menu:no-button");
  // (c) remove item present but the page did not remove → menu:still-present.
  lists.set("ytmusic-player-queue-item", [rowWith("b")]);
  lists.set(MENU_SEL, [{ textContent: "Remove from queue", querySelector: () => null, click: () => {} }]);
  res = await run("b");
  check(res?.ok === false && res.via === "menu:still-present" && st.queue.items.length === 2 && snapsAfter() === 0, "menu clicked but row still in store → ok=false menu:still-present, no re-emit");
  // (d) case-insensitive label match + inner anchor preferred over the item.
  let anchorClicked = false, itemClicked = false;
  lists.set(MENU_SEL, [{ textContent: "  REMOVE FROM QUEUE  ", querySelector: () => ({ click: () => { anchorClicked = true; st.queue.items = st.queue.items.filter((r) => r.playlistPanelVideoRenderer.videoId !== "b"); } }), click: () => { itemClicked = true; } }]);
  res = await run("b");
  check(res?.ok === true && res.via === "menu:removed" && anchorClicked && !itemClicked, "label match is case/whitespace-insensitive; the inner anchor is clicked, not the item");
  check(snapsAfter() === 1 && !posted.find((p) => p.event === "queueSnapshot").items.some((r) => r.videoId === "b"), "success re-emits the mirror without the removed row");
  // (e) no remove item → the menu is closed via body click.
  st.queue.items.push(renderer("c", "C", "A"));
  lists.set("ytmusic-player-queue-item", [rowWith("c")]);
  lists.set(MENU_SEL, [{ textContent: "Save to playlist", querySelector: () => null, click: () => {} }]);
  let bodyClicked = false;
  document.body = { click: () => { bodyClicked = true; } };
  res = await run("c");
  check(res?.ok === false && res.via === "menu:no-remove-item" && bodyClicked, "no 'Remove from queue' entry → menu closed via body.click(), honest failure");
  delete document.body;
  // (f) a menu candidate whose textContent throws → menu:threw (never a crash, never a wrong click).
  lists.set(MENU_SEL, [{ get textContent() { throw new Error("x"); } }]);
  res = await run("c");
  check(res?.ok === false && res.via === "menu:threw", "throwing menu DOM → ok=false menu:threw");
  check(dispatched.length === 0, "no branch ever dispatched to the store");
  check(window.__riffQueueApiReported === true, "queueApi one-shot probe fired during removals");
  // (g) the queueApi diagnostic is one-shot across calls.
  posted.length = 0; window.__riffQueueApiReported = false;
  window.musicBridge.queueRemoveViaPage("c"); await settle();
  window.musicBridge.queueRemoveViaPage("c"); await settle();
  check(posted.filter((p) => p.event === "diagnostic" && p.msg.startsWith("queueApi:")).length === 1, "queueApi: diagnostic emitted exactly once per page");
  // (h) return value is always true (fire-and-forget contract).
  check(window.musicBridge.queueRemoveViaPage("whatever") === true, "queueRemoveViaPage returns true synchronously");
}

// ---- Case 19: queueAddViaPage disabled → no network, no dispatch ------------
{
  elements.clear(); lists.clear();
  window.__riffStoreDispatchEnabled = undefined;
  let fetched = false;
  elements.set("ytmusic-app", { store: { getState: () => ({ queue: { items: [renderer("d1", "D1", "A", true)] } }), dispatch: () => { throw new Error("must not dispatch"); } }, networkManager: { fetch: async () => { fetched = true; return {}; } } });
  posted.length = 0;
  const ret = window.musicBridge.queueAddViaPage("z9", "end");
  await settle();
  const r = posted.filter((p) => p.event === "queueAddResult");
  check(ret === true && r.length === 1 && r[0].ok === false && r[0].via === "store-dispatch-disabled" && !fetched, "dispatch disabled: no get_queue fetch is made, result is store-dispatch-disabled");
  check(r[0].videoId === "z9" && r[0].position === "end", "result echoes videoId and position for Swift's per-id bookkeeping");
  check(posted.filter((p) => p.event === "queueSnapshot").length === 0, "a refused add never re-emits the mirror");
}

// ---- Case 20: setPendingNextURL + navigate primitives -----------------------
{
  window.musicBridge.setPendingNextURL("https://music.youtube.com/watch?v=n1&list=RDAMVMn1");
  check(window.__riffPendingNextUrl === "https://music.youtube.com/watch?v=n1&list=RDAMVMn1", "pending URL stored verbatim");
  window.musicBridge.setPendingNextURL("");
  check(window.__riffPendingNextUrl === null, "empty pending URL clears to null (YT autoplay takes over)");
  window.musicBridge.setPendingNextURL(undefined);
  check(window.__riffPendingNextUrl === null, "undefined pending URL clears to null");
  const before = location.href;
  window.musicBridge.navigate("https://music.youtube.com/watch?v=nav1");
  check(location.href === "https://music.youtube.com/watch?v=nav1", "navigate() sets location.href");
  location.href = before;
}

// ---- Case 21: onStateChange(0) drains the pending URL (fresh bridge instance) --
// Re-evaluate the bridge with a playerApi present so setup() subscribes
// synchronously; capture the listeners and drive them.
{
  const listeners = {};
  elements.clear(); lists.clear();
  elements.set("ytmusic-player", { playerApi: { addEventListener: (n, fn) => { listeners[n] = fn; }, getVideoData: () => ({ video_id: "cur", title: "Cur", author: "Au" }) } });
  elements.set("ytmusic-player-bar", {});
  posted.length = 0;
  let ok = true;
  try { (0, eval)(src); } catch (e) { ok = false; console.log("re-eval threw: " + e.message); }
  check(ok && typeof listeners.onStateChange === "function" && typeof listeners.videodatachange === "function", "bridge subscribes to onStateChange + videodatachange when playerApi is present at load");
  check(posted.some((p) => p.event === "ready"), "ready posted after subscription");
  check(posted.some((p) => p.event === "trackChanged" && p.videoId === "cur" && p.title === "Cur"), "initial forced trackChanged carries the loaded video");
  if (typeof listeners.onStateChange === "function") {
    // No pending URL → ended only.
    posted.length = 0; window.__riffPendingNextUrl = null;
    const href0 = location.href;
    listeners.onStateChange(0);
    check(posted.some((p) => p.event === "ended") && !posted.some((p) => p.event === "riffNavigatedTo") && location.href === href0, "state 0 without a pending URL: 'ended' only, no navigation");
    check(posted.some((p) => p.event === "stateChanged" && p.isPlaying === false), "state 0 also reports isPlaying=false");
    // Pending URL → navigate once, then cleared.
    posted.length = 0; window.__riffPendingNextUrl = "https://music.youtube.com/watch?v=p1&list=RDAMVMp1";
    listeners.onStateChange(0);
    check(location.href.endsWith("v=p1&list=RDAMVMp1") && posted.some((p) => p.event === "riffNavigatedTo" && p.via === "onStateChange"), "state 0 with a pending URL navigates and reports riffNavigatedTo");
    check(window.__riffPendingNextUrl === null, "pending URL is consumed exactly once");
    posted.length = 0; listeners.onStateChange(0);
    check(!posted.some((p) => p.event === "riffNavigatedTo"), "a second ended does not re-navigate");
    // State 1 / 2 map to isPlaying; 3 (buffering) is silent.
    posted.length = 0; listeners.onStateChange(1);
    check(posted.some((p) => p.event === "stateChanged" && p.isPlaying === true), "state 1 → isPlaying=true");
    posted.length = 0; listeners.onStateChange(3);
    check(posted.length === 0, "state 3 (buffering) emits nothing");
    // The pending-URL navigation above changed location (list=RDAMVMp1); a
    // same-videoId emit under a NEW playlist id is a deliberate re-emit (C4).
    posted.length = 0; listeners.videodatachange("dataupdated", {});
    check(posted.some((p) => p.event === "trackChanged" && p.videoId === "cur" && p.playlistId === "RDAMVMp1"), "same videoId under a new list= re-emits with the new playlistId (C4 dedup key)");
    // videodatachange dedup: same id + title + list → no re-emit; new id → emit.
    posted.length = 0; listeners.videodatachange("dataupdated", {});
    check(!posted.some((p) => p.event === "trackChanged"), "same videoId with a title already emitted is deduped");
    elements.get("ytmusic-player").playerApi.getVideoData = () => ({ video_id: "nxt", title: "", author: "" });
    posted.length = 0; listeners.videodatachange("dataloaded", {});
    check(posted.some((p) => p.event === "trackChanged" && p.videoId === "nxt" && p.title === ""), "new videoId emits even with empty metadata");
    elements.get("ytmusic-player").playerApi.getVideoData = () => ({ video_id: "nxt", title: "Landed", author: "Au" });
    posted.length = 0; listeners.videodatachange("dataupdated", {});
    check(posted.some((p) => p.event === "trackChanged" && p.title === "Landed"), "late-arriving title re-emits the same videoId once");
    posted.length = 0; listeners.videodatachange("dataupdated", {});
    check(!posted.some((p) => p.event === "trackChanged"), "…and only once");
  }
}

console.log(`\nJS RESULT: ${passes} passed, ${failures} failed`);
process.exit(failures === 0 ? 1 - 1 : 1);
