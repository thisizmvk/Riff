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

// ---- Case 11: queueAddViaPage happy path (dispatch + verify) --------------
{
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

// ---- Case 13: queueRemoveViaPage (dispatch + verify) ----------------------
{
  elements.clear();
  const dispatched = [];
  const state = { queue: { items: [renderer("r1", "R1", "A", true), renderer("r2", "R2", "A"), renderer("r3", "R3", "A")] } };
  elements.set("ytmusic-app", {
    store: {
      getState: () => state,
      dispatch: (a) => {
        dispatched.push(a);
        if (a.type === "REMOVE_ITEM") state.queue.items.splice(a.payload, 1);
      },
    },
  });
  posted.length = 0;
  window.__riffQueueSig = undefined;
  window.musicBridge.queueRemoveViaPage("r2");
  await settle();
  const r = posted.filter((p) => p.event === "queueRemoveResult");
  check(r.length === 1 && r[0].ok === true, "verified remove reports ok=true");
  check(dispatched.some((a) => a.type === "REMOVE_ITEM" && a.payload === 1), "REMOVE_ITEM dispatched with the row's index");
  check(posted.some((p) => p.event === "queueSnapshot" && !p.items.some((row) => row.videoId === "r2")), "mirror re-emitted without the removed row");

  // Unknown id → not-in-items failure, no dispatch.
  posted.length = 0;
  window.musicBridge.queueRemoveViaPage("nope");
  await settle();
  const r2 = posted.filter((p) => p.event === "queueRemoveResult");
  check(r2.length === 1 && r2[0].ok === false && r2[0].via === "not-in-items", "unknown id → ok=false not-in-items");
}

// ---- Case 13b: queueRemoveViaPage — automix rows (store index, then menu) --
{
  // (a) Reducer honours the combined items∪automix index.
  elements.clear(); lists.clear();
  const state = { queue: { items: [renderer("r1", "R1", "A", true)], automixItems: [renderer("a1", "A1", "A"), renderer("a2", "A2", "A")] } };
  elements.set("ytmusic-app", {
    store: {
      getState: () => state,
      dispatch: (a) => {
        if (a.type !== "REMOVE_ITEM") return;
        const n = state.queue.items.length;
        if (a.payload < n) state.queue.items.splice(a.payload, 1);
        else state.queue.automixItems.splice(a.payload - n, 1);
      },
    },
  });
  posted.length = 0;
  window.__riffQueueSig = undefined;
  window.musicBridge.queueRemoveViaPage("a2");
  await settle();
  const ra = posted.filter((p) => p.event === "queueRemoveResult");
  check(ra.length === 1 && ra[0].ok === true && /automix/.test(ra[0].via), "automix row removed via store with the combined index");
  check(state.queue.items.length === 1 && state.queue.automixItems.length === 1 && state.queue.automixItems[0].playlistPanelVideoRenderer.videoId === "a1", "only the target row left the automix tail");

  // (b) Reducer ignores automix indexes → fall back to the row's own menu.
  elements.clear(); lists.clear();
  const state2 = { queue: { items: [renderer("r1", "R1", "A", true)], automixItems: [renderer("m1", "M1", "A"), renderer("m2", "M2", "A")] } };
  elements.set("ytmusic-app", {
    store: {
      getState: () => state2,
      dispatch: (a) => { if (a.type === "REMOVE_ITEM" && a.payload < state2.queue.items.length) state2.queue.items.splice(a.payload, 1); },
    },
  });
  const opened = [];
  const mkRow = (id) => ({
    data: renderer(id, id, "A"),
    querySelector: (sel) => sel.startsWith("a[") ? { href: "https://music.youtube.com/watch?v=" + id }
      : { click: () => opened.push(id) },
  });
  lists.set("ytmusic-player-queue-item", [mkRow("m1"), mkRow("m2")]);
  const menuItem = { textContent: " Remove from queue ", querySelector: () => null,
    click: () => { state2.queue.automixItems = state2.queue.automixItems.filter((r) => r.playlistPanelVideoRenderer.videoId !== "m2"); } };
  lists.set("ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, tp-yt-paper-listbox ytmusic-menu-service-item-renderer",
    [{ textContent: "Save to playlist", querySelector: () => null, click: () => {} }, menuItem]);
  posted.length = 0;
  window.__riffQueueSig = undefined;
  window.musicBridge.queueRemoveViaPage("m2");
  await settle();
  const rb = posted.filter((p) => p.event === "queueRemoveResult");
  check(opened.length === 1 && opened[0] === "m2", "row menu opened on the identity-matched row only");
  check(rb.length === 1 && rb[0].ok === true && rb[0].via === "menu:removed", "automix row removed via the row menu when the store ignores it");
  check(state2.queue.automixItems.length === 1 && state2.queue.automixItems[0].playlistPanelVideoRenderer.videoId === "m1", "menu path removed only the target");

  // (c) Nothing works → ok=false, reported honestly (Swift restores the row).
  state2.queue.automixItems.push(renderer("m3", "M3", "A"));
  lists.set("ytmusic-player-queue-item", [mkRow("m1"), mkRow("m3")]);
  lists.set("ytmusic-menu-popup-renderer ytmusic-menu-navigation-item-renderer, ytmusic-menu-popup-renderer ytmusic-menu-service-item-renderer, tp-yt-paper-listbox ytmusic-menu-service-item-renderer", []);
  posted.length = 0;
  window.musicBridge.queueRemoveViaPage("m3");
  await settle();
  const rc = posted.filter((p) => p.event === "queueRemoveResult");
  check(rc.length === 1 && rc[0].ok === false && rc[0].via === "menu:no-remove-item", "no store effect + no menu item → ok=false menu:no-remove-item");
  check(state2.queue.automixItems.length === 2, "failed removal leaves the queue untouched");
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

console.log(`\nJS RESULT: ${passes} passed, ${failures} failed`);
process.exit(failures === 0 ? 1 - 1 : 1);
