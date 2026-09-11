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
// Intervals are RECORDED (fn + ms), never auto-run: cadence tests
// invoke a tick by hand via intervals.get(id).fn(). Ids start at 1 —
// the bridge treats a falsy id as "no poll", and real browsers never
// return 0 either.
const intervals = new Map();
let intervalSeq = 0;
global.setInterval = (fn, ms) => { intervalSeq += 1; intervals.set(intervalSeq, { fn, ms }); return intervalSeq; };
global.clearInterval = (id) => { intervals.delete(id); };
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
  check(rd.length === 1 && rd[0].ok === false && rd[0].via === "no-page-command", "default: no store dispatch; no page command resolver → ok=false no-page-command (Swift keeps its path)");

  // 11b — the page's command resolver performs the add (store + player).
  elements.clear(); lists.clear();
  const state = { queue: { items: [renderer("d1", "D1", "A", true), renderer("d3", "D3", "A")] } };
  const commands = [];
  elements.set("ytmusic-app", { store: { getState: () => state, dispatch: () => { throw new Error("must not dispatch"); } } });
  elements.set("ytmusic-player-bar", {
    resolveCommand: (cmd, el) => {
      commands.push(cmd);
      const v = cmd.queueAddEndpoint.queueTarget.videoId;
      const pos = cmd.queueAddEndpoint.queueInsertPosition;
      setTimeout(() => {   // the page fetches the renderer first
        if (pos === "INSERT_AFTER_CURRENT_VIDEO") state.queue.items.splice(1, 0, renderer(v, v, "A"));
        else state.queue.items.push(renderer(v, v, "A"));
      }, 200);
    },
  });
  posted.length = 0; window.__riffQueueSig = undefined;
  window.musicBridge.queueAddViaPage("d2", "next");
  await settle(); await settle();
  const rb = posted.filter((p) => p.event === "queueAddResult");
  check(rb.length === 1 && rb[0].ok === true && rb[0].via === "endpoint:resolveCommand@ytmusic-player-bar", "page command add verified → ok=true endpoint:resolveCommand (got " + JSON.stringify(rb) + ")");
  check(commands.length === 1 && commands[0].queueAddEndpoint.queueTarget.videoId === "d2" && commands[0].queueAddEndpoint.queueInsertPosition === "INSERT_AFTER_CURRENT_VIDEO", "queueAddEndpoint carries the video and INSERT_AFTER_CURRENT_VIDEO for Play next");
  check(state.queue.items[1].playlistPanelVideoRenderer.videoId === "d2", "row landed after the selected row");
  check(posted.some((p) => p.event === "queueSnapshot" && p.items.some((r) => r.videoId === "d2")), "mirror re-emitted with the page-owned row");

  // 11c — "end" maps to INSERT_AT_END.
  posted.length = 0; commands.length = 0;
  window.musicBridge.queueAddViaPage("d4", "end");
  await settle(); await settle();
  check(commands[0]?.queueAddEndpoint.queueInsertPosition === "INSERT_AT_END" && state.queue.items[state.queue.items.length - 1].playlistPanelVideoRenderer.videoId === "d4", "Add to queue → INSERT_AT_END, row at the end");

  // 11d — resolver runs but nothing lands → honest failure (Swift keeps its copy).
  elements.set("ytmusic-player-bar", { resolveCommand: () => {} });
  posted.length = 0;
  window.musicBridge.queueAddViaPage("d5", "next");
  await settle(); await settle();
  const rdd = posted.filter((p) => p.event === "queueAddResult");
  check(rdd.length === 1 && rdd[0].ok === false && rdd[0].via === "endpoint:resolveCommand:unverified", "command with no effect → ok=false unverified");
}

// ---- Case 11e-11l: a queue add is verified by a CHANGE, not presence -------
// Play next on a row the page already holds (or on the playing track) is
// present BEFORE the command runs; presence alone reported ok for a no-op
// and Swift dropped its enforced copy. Every case builds a FRESH fixture
// (11b-11d share one).
{
  window.__riffStoreDispatchEnabled = undefined;
  const ids = (st) => st.queue.items.map((row) => row.playlistPanelVideoRenderer.videoId).join(",");
  // `resolver(state, videoId, insertPosition)` plays the page: mutates the
  // fixture (synchronously — the harness runs short timers inline) or not.
  const runAdd = async (items, videoId, position, resolver, automix) => {
    elements.clear(); lists.clear();
    const state = { queue: { items: items, automixItems: automix || [] } };
    elements.set("ytmusic-app", { store: { getState: () => state, dispatch: () => { throw new Error("must not dispatch"); } } });
    elements.set("ytmusic-player-bar", {
      resolveCommand: (cmd) => {
        if (resolver) resolver(state, cmd.queueAddEndpoint.queueTarget.videoId, cmd.queueAddEndpoint.queueInsertPosition);
      },
    });
    posted.length = 0; window.__riffQueueSig = undefined;
    window.musicBridge.queueAddViaPage(videoId, position);
    await settle(); await settle();
    return { state: state, results: posted.filter((p) => p.event === "queueAddResult") };
  };
  const radio = () => [renderer("a", "A", "A", true), renderer("b", "B", "A"), renderer("c", "C", "A"), renderer("x", "X", "A")];

  // 11e — id already at row 3 (not next); the page ignores the command.
  let r = await runAdd(radio(), "x", "next", null);
  check(r.results.length === 1 && r.results[0].ok === false && r.results[0].via === "endpoint:resolveCommand:already-present-unchanged",
    "11e: Play next on a row already in the page queue + no-op command → ok=false (got " + JSON.stringify(r.results) + ")");
  check(!posted.some((p) => p.event === "queueSnapshot"), "11e: an unverified add never re-emits the mirror");

  // 11f — same row; the page inserts a copy after the playing row.
  r = await runAdd(radio(), "x", "next", (st, v) => st.queue.items.splice(1, 0, renderer(v, v, "A")));
  check(r.results.length === 1 && r.results[0].ok === true && r.results[0].via === "endpoint:resolveCommand@ytmusic-player-bar",
    "11f: page inserts a copy after the playing row → ok=true (got " + JSON.stringify(r.results) + ")");

  // 11g — id already right after the playing row: intent already satisfied.
  r = await runAdd([renderer("a", "A", "A", true), renderer("x", "X", "A"), renderer("b", "B", "A")], "x", "next", null);
  check(r.results.length === 1 && r.results[0].ok === true,
    "11g: id already next after the playing row + no-op command → ok=true (no legacy reload fallback)");

  // 11h — Play next on the PLAYING track itself (always present in items).
  r = await runAdd(radio(), "a", "next", null);
  check(r.results.length === 1 && r.results[0].ok === false, "11h: Play next on the playing track + no-op command → ok=false");
  r = await runAdd(radio(), "a", "next", (st, v) => st.queue.items.splice(1, 0, renderer(v, v, "A")));
  check(r.results.length === 1 && r.results[0].ok === true, "11h: Play next on the playing track, page inserts a copy → ok=true");

  // 11i — the page MOVES the existing row (occurrence count unchanged).
  r = await runAdd(radio(), "x", "next", (st, v) => {
    const i = st.queue.items.findIndex((row) => row.playlistPanelVideoRenderer.videoId === v);
    const moved = st.queue.items.splice(i, 1)[0];
    st.queue.items.splice(1, 0, moved);
  });
  check(r.results.length === 1 && r.results[0].ok === true && ids(r.state) === "a,x,b,c",
    "11i: page moves the row after the playing row → ok=true (positional check, not count)");

  // 11j — Add to queue ("end") on a row in the middle.
  r = await runAdd(radio(), "b", "end", null);
  check(r.results.length === 1 && r.results[0].ok === false && r.results[0].via === "endpoint:resolveCommand:already-present-unchanged",
    "11j: Add to queue on a mid-queue row + no-op command → ok=false");
  r = await runAdd(radio(), "b", "end", (st, v) => st.queue.items.push(renderer(v, v, "A")));
  check(r.results.length === 1 && r.results[0].ok === true, "11j: page appends a copy at the end → ok=true");
  r = await runAdd(radio(), "x", "end", null);
  check(r.results.length === 1 && r.results[0].ok === true, "11j: Add to queue on the last main row + no-op → ok=true (already at the end)");

  // 11j2 — an automix-tail row is present too; a no-op Play next is still a failure.
  r = await runAdd([renderer("a", "A", "A", true), renderer("b", "B", "A")], "m2", "next", null, [renderer("m1", "M1", "A"), renderer("m2", "M2", "A")]);
  check(r.results.length === 1 && r.results[0].ok === false, "11j2: Play next on an automix row + no-op command → ok=false");

  // 11k — the page's insert lands only on a LATER poll (it fetches the
  // renderer first): ok is posted only after it lands, never on the
  // first poll because the id was already somewhere in the queue.
  {
    elements.clear(); lists.clear();
    const state = { queue: { items: radio() } };
    let pendingReads = 0, inserted = false;
    elements.set("ytmusic-app", { store: {
      getState: () => {
        if (pendingReads > 0 && --pendingReads === 0) { state.queue.items.splice(1, 0, renderer("x", "X", "A")); inserted = true; }
        return state;
      },
      dispatch: () => { throw new Error("must not dispatch"); },
    } });
    elements.set("ytmusic-player-bar", { resolveCommand: () => { pendingReads = 4; } });
    const handler = window.webkit.messageHandlers.bridge;
    const origPost = handler.postMessage;
    let landedWhenPosted = null;
    handler.postMessage = (p) => { if (p.event === "queueAddResult") landedWhenPosted = inserted; origPost(p); };
    posted.length = 0; window.__riffQueueSig = undefined;
    window.musicBridge.queueAddViaPage("x", "next");
    await settle(); await settle();
    handler.postMessage = origPost;
    const res = posted.filter((p) => p.event === "queueAddResult");
    check(res.length === 1 && res[0].ok === true && landedWhenPosted === true,
      "11k: delayed page insert → ok=true posted only after the insert landed (got " + JSON.stringify(res) + ", landed=" + landedWhenPosted + ")");
  }

  // 11l — opt-in store-dispatch path gets the same change check.
  {
    window.__riffStoreDispatchEnabled = true;
    elements.clear(); lists.clear();
    const state = { queue: { items: radio() } };
    elements.set("ytmusic-app", {
      store: { getState: () => state, dispatch: () => {} },   // no-op reducer
      networkManager: { fetch: async (path, body) => ({ queueDatas: [{ content: renderer(body.videoIds[0], "Injected", "AI") }] }) },
    });
    posted.length = 0;
    window.musicBridge.queueAddViaPage("x", "next");
    await settle(); await settle();
    const res = posted.filter((p) => p.event === "queueAddResult");
    check(res.length === 1 && res[0].ok === false && res[0].via.endsWith("+unchanged"),
      "11l: store dispatch that changes nothing for an already-present id → ok=false (got " + JSON.stringify(res) + ")");
    window.__riffStoreDispatchEnabled = undefined;
  }
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

  // (c2) the page's queue controller removes it (preferred over the menu).
  elements.clear(); lists.clear();
  const state3 = { queue: { items: [renderer("r1", "R1", "A", true), renderer("k2", "K2", "A"), renderer("k3", "K3", "A")] } };
  const removed = [];
  elements.set("ytmusic-app", mkStore(state3, []));
  elements.set("ytmusic-player-bar", { queue: {
    getItems: () => state3.queue.items,
    removeItem: (i) => { removed.push(i); if (typeof i === "number") state3.queue.items.splice(i, 1); },
  } });
  const opened3 = [];
  lists.set("ytmusic-player-queue-item", [mkRow("k2", opened3), mkRow("k3", opened3)]);
  posted.length = 0; window.__riffQueueSig = undefined;
  window.musicBridge.queueRemoveViaPage("k3");
  await settle();
  const rk = posted.filter((p) => p.event === "queueRemoveResult");
  check(rk.length === 1 && rk[0].ok === true && rk[0].via === "ytmusic-player-bar.queue:removeItem(index)", "controller removeItem(index) verified → ok=true (got " + JSON.stringify(rk) + ")");
  check(removed.length === 1 && removed[0] === 2 && opened3.length === 0, "index looked up in the controller's own list; menu never opened");
  check(state3.queue.items.length === 2 && state3.queue.items[1].playlistPanelVideoRenderer.videoId === "k2", "only the target row left");

  // (c3) controller that ignores an index but accepts the item object.
  state3.queue.items.push(renderer("k4", "K4", "A"));
  elements.set("ytmusic-player-bar", { queue: {
    getItems: () => state3.queue.items,
    removeItem: (arg) => { if (typeof arg === "object" && arg) state3.queue.items = state3.queue.items.filter((r) => r !== arg); },
  } });
  posted.length = 0;
  window.musicBridge.queueRemoveViaPage("k4");
  await settle();
  const rk2 = posted.filter((p) => p.event === "queueRemoveResult");
  check(rk2.length === 1 && rk2[0].ok === true && rk2[0].via === "ytmusic-player-bar.queue:removeItem(item)", "falls back to removeItem(item) when the index form is a no-op");

  // (c4) controller with no effect → the row menu path runs.
  state3.queue.items.push(renderer("k5", "K5", "A"));
  elements.set("ytmusic-player-bar", { queue: { getItems: () => state3.queue.items, removeItem: () => {} } });
  lists.set("ytmusic-player-queue-item", [mkRow("k5", opened3)]);
  lists.set(MENU_ITEMS_SEL, [{ textContent: "Remove from queue", querySelector: () => null,
    click: () => { state3.queue.items = state3.queue.items.filter((r) => r.playlistPanelVideoRenderer.videoId !== "k5"); } }]);
  posted.length = 0;
  window.musicBridge.queueRemoveViaPage("k5");
  await settle();
  const rk3 = posted.filter((p) => p.event === "queueRemoveResult");
  check(rk3.length === 1 && rk3[0].ok === true && rk3[0].via === "menu:removed" && opened3.length === 1, "controller no-op → row menu path removes it");
  elements.set("ytmusic-app", mkStore(state2, dispatched2));
  lists.set("ytmusic-player-queue-item", [mkRow("m1", opened2), mkRow("m3", opened2)]);
  lists.set(MENU_ITEMS_SEL, []);
  elements.delete("ytmusic-player-bar");

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
  const probeLines = posted.filter((p) => p.event === "diagnostic" && p.msg.startsWith("queueApi:")).length;
  window.musicBridge.queueRemoveViaPage("c"); await settle();
  check(probeLines >= 1 && posted.filter((p) => p.event === "diagnostic" && p.msg.startsWith("queueApi:")).length === probeLines, "queueApi: probe is one-shot per page (several lines, emitted once)");
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
  check(ret === true && r.length === 1 && r[0].ok === false && r[0].via === "no-page-command" && !fetched, "dispatch disabled + no page command: no get_queue fetch is made, result is no-page-command");
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

// ---- Case 22: pageInfo handshake payload ----------------------------------
// Driven via __riffDebug.emitPageInfo: setup() cannot complete in the
// harness (its 500ms retry timer is stubbed out), so the debug hook is
// the sanctioned way to fire the handshake against the element map.
let firstPageInfoGeneration = null;
{
  check(typeof window.__riffDebug.emitPageInfo === "function", "__riffDebug.emitPageInfo exposed");
  // (a) bare page: no ytcfg, no elements → still posts, with empty
  // strings / false capabilities / zero rows; never throws.
  elements.clear(); lists.clear();
  delete window.yt; delete window.ytcfg;
  posted.length = 0;
  window.__riffDebug.emitPageInfo();
  let pi = posted.filter((p) => p.event === "pageInfo");
  check(pi.length === 1, "bare page still posts pageInfo (never blocks ready)");
  check(pi[0]?.schema === 1 && typeof pi[0]?.generation === "string" && pi[0].generation.length > 0, "schema=1 with a non-empty generation id");
  const y0 = pi[0]?.ytcfg ?? {};
  check(y0.clientVersion === "" && y0.sessionIndex === "" && y0.visitorData === "" && y0.hl === "" && y0.gl === "", "missing ytcfg → empty strings, never undefined");
  check(Object.values(pi[0]?.capabilities ?? {}).length === 5 && Object.values(pi[0]?.capabilities ?? {}).every((v) => v === false), "no elements → all five capabilities false");
  const s0 = pi[0]?.selectors ?? {};
  check(s0.next === false && s0.previous === false && s0.shuffle === false && s0.playerBar === false && s0.queueRows === 0, "no elements → selector health all absent, zero rows");
  firstPageInfoGeneration = pi[0]?.generation ?? null;

  // (b) populated page: ytcfg + player elements + selector targets.
  window.yt = { config_: { INNERTUBE_CLIENT_VERSION: "1.20260901.01.00", SESSION_INDEX: 2, VISITOR_DATA: "CgtWaXNpdG9yRGF0YQ", HL: "de", GL: "DE" } };
  elements.set("ytmusic-player", { playerApi: { getVideoData: () => ({}), addEventListener: () => {} } });
  elements.set("ytmusic-player-bar", { queue: { getItems: () => [] }, resolveCommand: () => {} });
  elements.set("ytmusic-app", { store: { getState: () => ({}), dispatch: () => {}, subscribe: () => {} } });
  elements.set(".next-button", { click: () => {} });
  elements.set("ytmusic-player-bar [aria-label*='huffle']", { click: () => {} });
  lists.set("ytmusic-player-queue-item", [{}, {}, {}]);
  posted.length = 0;
  window.__riffDebug.emitPageInfo();
  pi = posted.filter((p) => p.event === "pageInfo");
  check(pi.length === 1, "populated page posts pageInfo");
  const y = pi[0]?.ytcfg ?? {};
  check(y.clientVersion === "1.20260901.01.00" && y.hl === "de" && y.gl === "DE", "ytcfg clientVersion/hl/gl read from window.yt.config_");
  check(y.sessionIndex === "2", "numeric SESSION_INDEX is stringified");
  check(y.visitorData === "CgtWaXNpdG9yRGF0YQ", "visitorData carried verbatim (Swift decodes only its length)");
  const c = pi[0]?.capabilities ?? {};
  check(c.playerApi === true && c.queueController === true && c.commandResolver === true && c.storeDispatch === true && c.storeSubscribe === true, "capabilities detected via the same resolvers the queue actions use");
  const s = pi[0]?.selectors ?? {};
  check(s.next === true && s.previous === false && s.shuffle === true && s.playerBar === true && s.queueRows === 3, "selector health: per-selector flags + row count");
  check(pi[0]?.generation === firstPageInfoGeneration, "same document → same generation id");

  // (c) the window.ytcfg.data_ home is honored too; signed-out
  // SESSION_INDEX="" is carried as-is (Swift falls back to the header default).
  delete window.yt;
  window.ytcfg = { data_: { INNERTUBE_CLIENT_VERSION: "1.20260902.00.00", SESSION_INDEX: "" } };
  posted.length = 0;
  window.__riffDebug.emitPageInfo();
  pi = posted.filter((p) => p.event === "pageInfo");
  check(pi[0]?.ytcfg?.clientVersion === "1.20260902.00.00", "window.ytcfg.data_ home is read");
  check(pi[0]?.ytcfg?.sessionIndex === "", "signed-out SESSION_INDEX='' carried as-is");
  delete window.ytcfg;
  elements.clear(); lists.clear();
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
  // Handshake ordering: setup() posts pageInfo BEFORE ready, so the
  // Swift side installs the page's protocol overrides before ready's
  // queued-command flush; a fresh document re-rolls the generation id.
  const piIdx = posted.findIndex((p) => p.event === "pageInfo");
  const rdIdx = posted.findIndex((p) => p.event === "ready");
  check(piIdx >= 0 && rdIdx >= 0 && piIdx < rdIdx, "pageInfo posted BEFORE ready");
  check(typeof posted[piIdx]?.generation === "string" && posted[piIdx].generation.length > 0 && posted[piIdx].generation !== firstPageInfoGeneration, "a new document re-rolls the pageInfo generation id");
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

// ---- Case 23: queue-store subscription (energy upgrade path) ---------------
// The store subscription is an optimisation over the safety poll: a
// debounced emitQueueSnapshot on real queue changes, gated by an O(1)
// identity check so YT's dispatch bursts don't turn into walks.
{
  elements.clear(); lists.clear();
  const subs = [];
  let state = { queue: { items: [renderer("s1", "S1", "A", true), renderer("s2", "S2", "A")] } };
  const store = {
    getState: () => state,
    subscribe: (fn) => { subs.push(fn); return () => { const i = subs.indexOf(fn); if (i >= 0) subs.splice(i, 1); }; },
  };
  elements.set("ytmusic-app", { store });
  posted.length = 0; window.__riffQueueSig = undefined;
  check(typeof window.__riffDebug.subscribeQueueStore === "function", "__riffDebug.subscribeQueueStore exposed");
  check(window.__riffDebug.subscribeQueueStore() === true && subs.length === 1, "subscribeQueueStore registers exactly one store.subscribe listener");
  check(window.__riffQueueStoreSubscribed === true && store.__riffQueueSubscribed === true, "subscription flagged on window AND on the store object (survives a playerApi rebind)");
  check(posted.filter((p) => p.event === "diagnostic" && p.msg.includes("queue store subscribed via app.store")).length === 1, "one-shot subscribe diagnostic");
  check(window.__riffDebug.subscribeQueueStore() === true && subs.length === 1, "second subscribe call is a no-op (store already flagged)");
  // Dispatch with unchanged queue refs → identity check bails, no walk, no emit.
  posted.length = 0;
  subs[0]();
  check(posted.filter((p) => p.event === "queueSnapshot").length === 0, "dispatch with identical queue refs → no snapshot (O(1) identity check)");
  // Real change (new arrays, as redux reducers produce) → one debounced snapshot with the new rows.
  state = { queue: { items: [renderer("s1", "S1", "A"), renderer("s2", "S2", "A", true), renderer("s3", "S3", "A")] } };
  posted.length = 0;
  subs[0]();
  const snaps23 = posted.filter((p) => p.event === "queueSnapshot");
  check(snaps23.length === 1 && snaps23[0].items.map((i) => i.videoId).join() === "s1,s2,s3", "store change → exactly one debounced snapshot with the new rows (got " + JSON.stringify(snaps23.map((s) => s.items.map((i) => i.videoId))) + ")");
  // Identical re-invoke → nothing (refs unchanged; sig would dedup anyway).
  posted.length = 0;
  subs[0]();
  check(posted.filter((p) => p.event === "queueSnapshot").length === 0, "identical re-invoke → no snapshot");
  // A getState that throws inside dispatch must never propagate into the page.
  const badState = { get queue() { throw new Error("dispatch-time"); } };
  const stateRef = state;
  store.getState = () => badState;
  let threw = false;
  try { subs[0](); } catch (_) { threw = true; }
  check(threw === false, "a throwing store read inside dispatch never throws into the page");
  store.getState = () => stateRef;
}

// ---- Case 24: safety-poll rate policy (fresh bridge instance) --------------
// The 2 s poll is the behaviour; the rate adapts: paused → 10 s,
// playing → 2 s (10 s only under a live subscription, case 25). Rate
// changes are no-ops when unchanged, and while backgrounded they only
// record the desired rate — media-key pause/play fires onStateChange
// with the app inactive and must not restart the poll back there.
{
  const listeners = {};
  elements.clear(); lists.clear();
  window.__riffQueueStoreSubscribed = false;
  window.__riffSafetyPollPaused = false;
  window.__riffDebug.stopSafetyPoll();
  elements.set("ytmusic-player", { playerApi: { addEventListener: (n, fn) => { listeners[n] = fn; }, getVideoData: () => ({ video_id: "r1", title: "R1", author: "A" }) } });
  elements.set("ytmusic-player-bar", {});
  posted.length = 0;
  (0, eval)(src);   // fresh bridge: setup() subscribes + starts the poll
  let entry = intervals.get(window.__riffSafetyPollId);
  check(!!window.__riffSafetyPollId && entry?.ms === 2000, "setup starts the safety poll at the 2 s baseline");
  const idAt2s = window.__riffSafetyPollId;
  listeners.onStateChange(1);
  check(window.__riffSafetyPollId === idAt2s, "state 1 at an unchanged rate is a no-op (same interval, no churn)");
  listeners.onStateChange(2);
  check(intervals.get(window.__riffSafetyPollId)?.ms === 10000, "paused → poll slows to 10 s");
  listeners.onStateChange(2);
  const idAt10s = window.__riffSafetyPollId;
  check(window.__riffSafetyPollId === idAt10s, "repeated paused state → still no churn");
  listeners.onStateChange(1);
  check(intervals.get(window.__riffSafetyPollId)?.ms === 2000, "playing again → poll back to 2 s");
  // Backgrounded: the poll stops; state changes record the rate only.
  window.musicBridge.setBackgrounded(true);
  check(window.__riffSafetyPollId === null && window.__riffSafetyPollPaused === true, "backgrounding stops the poll");
  listeners.onStateChange(2);   // media-key pause while the app is inactive
  check(window.__riffSafetyPollId === null && window.__riffSafetyPollMs === 10000, "state change while backgrounded records the desired rate but starts nothing");
  window.musicBridge.setBackgrounded(false);
  check(intervals.get(window.__riffSafetyPollId)?.ms === 10000, "foregrounding resumes at the recorded rate");
  listeners.onStateChange(3);   // buffering: not a rate input
  check(intervals.get(window.__riffSafetyPollId)?.ms === 10000, "state 3 (buffering) leaves the poll rate alone");
  listeners.onStateChange(1);   // leave the bridge in the playing state for case 25
  check(intervals.get(window.__riffSafetyPollId)?.ms === 2000, "back to playing → 2 s");
}

// ---- Case 25: poll tick — subscribe-less fallback, upgrade, downgrade ------
{
  elements.clear(); lists.clear();
  window.__riffDebug.stopSafetyPoll();
  window.__riffQueueStoreSubscribed = false;
  window.__riffSafetyPollPaused = false;

  // (a) subscribe-less store: the poll path still emits the mirror.
  const stateA = { queue: { items: [renderer("f1", "F1", "A", true)] } };
  elements.set("ytmusic-app", { store: { getState: () => stateA } });
  posted.length = 0; window.__riffQueueSig = undefined;
  window.__riffDebug.startSafetyPoll(2000);
  check(intervals.get(window.__riffSafetyPollId)?.ms === 2000, "25a: poll started at 2 s");
  intervals.get(window.__riffSafetyPollId).fn();
  const snapsA = posted.filter((p) => p.event === "queueSnapshot");
  check(snapsA.length === 1 && snapsA[0].items[0].videoId === "f1", "25a: subscribe-less store → the poll path still emits the mirror");
  check(window.__riffQueueStoreSubscribed !== true && intervals.get(window.__riffSafetyPollId)?.ms === 2000, "25a: no subscribe surface → stays on the 2 s poll");

  // (b) store WITH subscribe appears later: the tick subscribes (retry-from-poll,
  // since setup gates only on playerApi + player-bar) and drops to the watchdog.
  const subs = []; let unsubbed = false;
  const stateB = { queue: { items: [renderer("w1", "W1", "A", true)] } };
  elements.set("ytmusic-app", { store: { getState: () => stateB, subscribe: (fn) => { subs.push(fn); return () => { unsubbed = true; }; } } });
  posted.length = 0; window.__riffQueueSig = undefined;
  intervals.get(window.__riffSafetyPollId).fn();
  check(subs.length === 1 && window.__riffQueueStoreSubscribed === true, "25b: a later poll tick subscribes once the store appears");
  check(intervals.get(window.__riffSafetyPollId)?.ms === 10000, "25b: subscribed → poll drops to the 10 s watchdog");
  check(posted.filter((p) => p.event === "queueSnapshot").length === 1, "25b: the subscribing tick still emits its snapshot (subscription never delays the mirror)");
  // A dispatch-driven change reaches the mirror with NO poll tick at all.
  stateB.queue = { items: [renderer("w1", "W1", "A"), renderer("w2", "W2", "A", true)] };
  posted.length = 0;
  subs[0]();
  const snapsB = posted.filter((p) => p.event === "queueSnapshot");
  check(snapsB.length === 1 && snapsB[0].items.map((i) => i.videoId).join() === "w1,w2", "25b: store dispatch → snapshot without waiting for a poll tick");

  // (c) in-place mutation the subscription cannot see: the watchdog tick still
  // emits it, then downgrades back to the 2 s poll — sticky, one diagnostic.
  stateB.queue.items.push(renderer("w3", "W3", "A"));
  posted.length = 0;
  intervals.get(window.__riffSafetyPollId).fn();
  const snapsC = posted.filter((p) => p.event === "queueSnapshot");
  check(snapsC.length === 1 && snapsC[0].items.length === 3, "25c: watchdog still emits the change the subscription missed");
  check(window.__riffQueueStoreSubscribed === false && unsubbed === true, "25c: missed change → subscription downgraded and unsubscribed");
  check(intervals.get(window.__riffSafetyPollId)?.ms === 2000, "25c: downgrade reverts to the 2 s poll");
  check(posted.filter((p) => p.event === "diagnostic" && p.msg.includes("downgraded")).length === 1, "25c: exactly one downgrade diagnostic");
  posted.length = 0;
  intervals.get(window.__riffSafetyPollId).fn();
  check(window.__riffQueueStoreSubscribed === false && subs.length === 1, "25c: a downgraded page never re-subscribes (no flip-flop)");
}

console.log(`\nJS RESULT: ${passes} passed, ${failures} failed`);
process.exit(failures === 0 ? 1 - 1 : 1);
