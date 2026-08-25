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
global.window = global;
global.location = { href: "https://music.youtube.com/watch?v=abc", hash: "", origin: "https://music.youtube.com" };
global.document = {
  readyState: "complete",
  querySelector: (sel) => elements.get(sel) || null,
  getElementById: () => null,
  addEventListener: () => {},
  documentElement: {},
};
global.URL = URL;
global.MutationObserver = class { observe() {} disconnect() {} };
global.webkit = { messageHandlers: { bridge: { postMessage: (p) => posted.push(p) } } };
global.window.webkit = global.webkit;
// setup() will retry via setTimeout — neuter timers so the harness exits.
global.setInterval = () => 0;
global.clearInterval = () => {};
global.setTimeout = () => 0;

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

console.log(`\nJS RESULT: ${passes} passed, ${failures} failed`);
process.exit(failures === 0 ? 1 - 1 : 1);
