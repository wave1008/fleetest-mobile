// テスト実行中のデバイスの操作(グリッドビュー・ライブ操作タブ)の DOM テスト。harness は webviewGridLivePanel.test.mjs と
// 同じ(実 HTML + 実バンドルを jsdom で動かす)。
//
// 契約(ユーザー決定: 介入は利用者の自己責任): デバイスがシナリオを回している間(workerRunning)も、操作は**止めない**
// (トグルも確認も無い)。人の操作は serve が台帳へ残し、そのシナリオの結果に載る(Swift 側 HumanOperationLedger)。
// 止めるのは**整定のための自動の撮り直し**だけ(XCUITest ブリッジはシナリオの操作と口を取り合う)。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import path from "node:path";
import { before, test } from "node:test";
import * as esbuild from "esbuild";
import { JSDOM } from "jsdom";

const require2 = createRequire(import.meta.url);

let panelHtml;
let webviewBundle;

before(async () => {
  const htmlBuild = await esbuild.build({
    entryPoints: [path.resolve("src/monitorHtml.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node18",
    write: false,
    external: ["vscode"],
    logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  const webviewStub = { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" };
  panelHtml = mod.exports.renderHtml(webviewStub, { path: "" });

  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "es2022",
    write: false,
    logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});


/** window.close() を忘れると main.js の setInterval が残ってプロセスが終わらない */
function createWebview() {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posts.push(m), setState: () => {}, getState: () => undefined });
  window.HTMLElement.prototype.scrollIntoView = () => {};
  window.eval(webviewBundle);
  // jsdom レルムのオブジェクトは Object.prototype が異なり deepEqual が落ちるため JSON で正規化する
  const norm = (list) => list.map((p) => JSON.parse(JSON.stringify(p)));
  const gridActions = () => norm(posts.filter((p) => p.type === "gridLiveAction"));
  const liveMessages = () => norm(posts.filter((p) => p.type === "live").map((p) => p.message));
  return { window, document: window.document, gridActions, liveMessages, posts };
}

const send = (window, data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
const live = (window, message) => send(window, { type: "live", message });
/** host の lane メッセージの形(main.js の runEvent → laneLog.applyLaneAction) */
const workerRunning = (window, workerId, running) =>
  send(window, { type: "runEvent", action: { type: "workerRunning", workerId, running } });

function sendDevices(window, count) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "connected",
    detail: "", kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
  }));
  send(window, { type: "devices", devices });
}

function clickTile(document, index) {
  const stub = (el, left, top, width, height) => {
    el.getBoundingClientRect = () => ({
      left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
    });
  };
  [...document.querySelectorAll("#grid .tile")].forEach((tile, i) => {
    stub(tile, i * 110, 0, 100, 200);
    stub(tile.querySelector(".frame-wrap"), i * 110 + 10, 30, 80, 140);
  });
  const frame = document.querySelectorAll("#grid .tile .frame-wrap")[index];
  frame.dispatchEvent(new document.defaultView.MouseEvent("click", {
    bubbles: true, clientX: index * 110 + 50, clientY: 100,
  }));
}

function selectOneWithPicture(window, document, index = 0) {
  clickTile(document, index);
  send(window, { type: "frame", device: `d${index}`, jpegBase64: "QUJD", stream: true });
  const media = document.querySelector("#preview-grid .lane-preview .lane-preview-media");
  assert.ok(media, "拡大表示に絵がある");
  media.getBoundingClientRect = () => ({ left: 100, top: 50, width: 200, height: 400, right: 300, bottom: 450, x: 100, y: 50 });
  return media;
}

function pointerEvent(window, type, { x, y, pointerId = 1 }) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

const tap = (window, media) => {
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
};

function setupGrid(t) {
  const ctx = createWebview();
  t.after(() => ctx.window.close());
  sendDevices(ctx.window, 1);
  const media = selectOneWithPicture(ctx.window, ctx.document, 0);
  live(ctx.window, { type: "devices", devices: [], selectedId: "d0" });
  return { ...ctx, media };
}


const LIVE_ID = "ios:Dev A";
function setupLiveTab(t) {
  const ctx = createWebview();
  t.after(() => ctx.window.close());
  const { window, document } = ctx;
  document.getElementById("tab-live").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
  const screenshot = document.getElementById("live-screenshot");
  screenshot.getBoundingClientRect = () => ({ left: 0, top: 0, right: 400, bottom: 800, width: 400, height: 800, x: 0, y: 0 });
  live(window, {
    type: "devices", selectedId: LIVE_ID,
    devices: [{ id: LIVE_ID, name: "Dev A", platform: "ios", state: "connected", detail: "", kind: "virtual", udid: "U" }],
  });
  live(window, { type: "snapshot", platform: "ios", screen: { width: 400, height: 800 }, image: "aW1n", elements: [] });
  return { ...ctx, screenshot };
}

test("グリッド: 実行中のデバイスも、トグル無しでそのまま操作を送る(ボタン・入力欄・更新も止めない)", (t) => {
  const { window, document, media, gridActions } = setupGrid(t);
  workerRunning(window, "d0", true);
  assert.equal(document.getElementById("grid-live-run-gate"), null, "介入の門の表示は無い");
  assert.equal(document.getElementById("grid-live-intervene"), null, "介入するトグルは無い");
  tap(window, media);
  document.getElementById("grid-live-btn-home").click();
  assert.deepEqual(gridActions().map((m) => m.action.type), ["tapPoint", "home"], "実行中でも送る");
  assert.equal(document.getElementById("grid-live-btn-home").disabled, false);
  assert.equal(document.getElementById("grid-live-type-text").disabled, false);
  assert.equal(document.getElementById("grid-live-btn-refresh-snapshot").disabled, false);
  assert.equal(document.getElementById("grid-live-error").textContent, "", "止める文言は出さない");
});

test("ライブ操作タブ: 実行中のデバイスも、トグル無しで画面操作・ボタン・入力・録画/インストール/起動を止めない", (t) => {
  const { window, document, screenshot, liveMessages } = setupLiveTab(t);
  workerRunning(window, LIVE_ID, true);
  assert.equal(document.getElementById("live-run-gate"), null, "介入の門の表示は無い");
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 10, y: 10 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 10, y: 10 }));
  document.getElementById("live-btn-home").click();
  const sent = liveMessages().map((m) => m.type);
  assert.ok(sent.includes("tapPoint"), "画面のタップを送る");
  assert.ok(sent.includes("home"), "ツールバーの操作を送る");
  assert.equal(document.getElementById("live-type-text").disabled, false);
  assert.equal(document.getElementById("live-action-error-text").textContent, "");
});

test("ライブ操作タブ: 実行中は整定のための自動の撮り直しを撃たない(人の「更新」は撃つ)", async (t) => {
  const { window, document, liveMessages } = setupLiveTab(t);
  const refreshes = () => liveMessages().filter((m) => m.type === "refreshSnapshot").length;
  workerRunning(window, LIVE_ID, true);
  const before = refreshes();
  live(window, { type: "snapshot", platform: "ios", screen: { width: 400, height: 800 }, image: "aW1n", elements: [] });
  await new Promise((resolve) => setTimeout(resolve, 1100));
  assert.equal(refreshes(), before, "整定後の撮り直しを撃たない");
  document.getElementById("live-btn-refresh-snapshot").click();
  assert.equal(refreshes(), before + 1, "人が押した「更新」は撃つ");
});

test("ライブ操作タブ: 実行中でなければ従来どおり整定後に撮り直す(陰性対照)", async (t) => {
  const { window, liveMessages } = setupLiveTab(t);
  const refreshes = () => liveMessages().filter((m) => m.type === "refreshSnapshot").length;
  const before = refreshes();
  live(window, { type: "snapshot", platform: "ios", screen: { width: 400, height: 800 }, image: "aW1n", elements: [] });
  await new Promise((resolve) => setTimeout(resolve, 1100));
  assert.equal(refreshes(), before + 1);
});

test("ライブ操作タブ: 実行中でも画面サイズが無ければ最初の1回は撮る(撮らないと画面の操作が黙って無視される)", (t) => {
  const { window, liveMessages } = setupLiveTab(t);
  const refreshes = () => liveMessages().filter((m) => m.type === "refreshSnapshot").length;
  workerRunning(window, LIVE_ID, true);
  live(window, { type: "clearSnapshot" }); // 画面サイズ(lastScreen)が無い状態
  const before = refreshes();
  live(window, { type: "frame", image: "aW1n" });
  assert.equal(refreshes(), before + 1, "配信の絵が来たら1回撮る");
  live(window, { type: "frame", image: "aW1n" });
  assert.equal(refreshes(), before + 1, "1回だけ(届くまで重ねて撃たない)");
});

test("グリッド: 実行中は自動の撮り直しが無いので、操作の結果の枠は打ち切りで手元の木で描く", async (t) => {
  const { window, document, media } = setupGrid(t);
  const timers = [];
  const realSetTimeout = window.setTimeout.bind(window);
  window.setTimeout = (fn, delay, ...rest) => {
    if (delay === 2800) { timers.push(fn); return 0; }
    return realSetTimeout(fn, delay, ...rest);
  };
  const snap = {
    type: "snapshot", platform: "ios", screen: { width: 400, height: 800 }, image: "QUJD", notes: [],
    elements: [{ ref: "e1", frame: { x: 0, y: 0, width: 100, height: 100 }, frameText: "0,0 100x100", line: "Button A" }],
  };
  const box = document.getElementById("grid-live-show-boxes");
  box.checked = true;
  box.dispatchEvent(new window.Event("change", { bubbles: true }));
  live(window, snap);
  workerRunning(window, "d0", true);
  tap(window, media);
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snap); // 直接の結果(次の整定後の木は来ない)
  document.querySelector("#preview-grid .lane-preview img.lane-preview-media").dispatchEvent(new window.Event("load")); // 絵が描き替わった
  const rects = () => document.querySelectorAll(".grid-live-boxes-overlay rect:not(.hot)").length;
  assert.equal(rects(), 0);
  assert.equal(timers.length, 1);
  timers[0]();
  assert.equal(rects(), 1, "打ち切りで描く");
});

// ---- 観測(画面を変えない busy)の最中の操作 ----------------------------------------------------------
// 撮り直しは操作の結果のたびに走るので、その窓に押したタップを捨てると「止まった画面へのタップが空振り」になる(実地)。
// 観測の最中は送り(host が観測の終わりを待って撃つ)、操作の最中は従来どおり受け付けない。

test("グリッド: 観測の最中(busy.observing)はタップを送り、操作の最中は送らない", (t) => {
  const { window, media, gridActions } = setupGrid(t);
  live(window, { type: "busy", busy: true, observing: true });
  tap(window, media);
  assert.equal(gridActions().length, 1, "観測の最中のタップは送る");
  live(window, { type: "busy", busy: true, observing: false });
  tap(window, media);
  assert.equal(gridActions().length, 1, "操作の最中のタップは送らない");
  live(window, { type: "busy", busy: false, observing: false });
  tap(window, media);
  assert.equal(gridActions().length, 2);
});

test("ライブ操作タブ: 観測の最中(busy.observing)はタップを送り、操作の最中は送らない。「更新」は観測中も重ねない", (t) => {
  const { window, document, screenshot, liveMessages } = setupLiveTab(t);
  const taps = () => liveMessages().filter((m) => m.type === "tapPoint").length;
  live(window, { type: "busy", busy: true, observing: true });
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 10, y: 10 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 10, y: 10 }));
  assert.equal(taps(), 1, "観測の最中のタップは送る");
  assert.equal(document.getElementById("live-btn-home").disabled, false, "デバイスを操作するボタンも押せる");
  assert.equal(document.getElementById("live-btn-refresh-snapshot").disabled, true, "観測そのもの(更新)は重ねない");
  live(window, { type: "busy", busy: true, observing: false });
  screenshot.dispatchEvent(pointerEvent(window, "pointerdown", { x: 10, y: 10 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 10, y: 10 }));
  assert.equal(taps(), 1, "操作の最中のタップは送らない");
  assert.equal(document.getElementById("live-btn-home").disabled, true);
});

test("ライブ操作タブ: 軌跡は離した後も、デバイスがなぞり終えるまで線を残す", (t) => {
  const { window, document, screenshot } = setupLiveTab(t);
  window.Element.prototype.setPointerCapture = () => {};
  window.Element.prototype.releasePointerCapture = () => {};
  const overlay = document.getElementById("live-drag-overlay");
  const shift = (type, x, y) => {
    const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, shiftKey: true });
    Object.defineProperty(event, "pointerId", { value: 1 });
    return event;
  };
  screenshot.dispatchEvent(shift("pointerdown", 10, 10));
  window.dispatchEvent(shift("pointermove", 100, 100));
  window.dispatchEvent(shift("pointerup", 100, 100));
  assert.ok(overlay.classList.contains("visible"), "離した後も線を残す");
  live(window, { type: "busy", busy: true, observing: false });
  assert.ok(overlay.classList.contains("visible"), "なぞっている間は残す");
  live(window, { type: "busy", busy: false, observing: false });
  assert.equal(overlay.classList.contains("visible"), false, "なぞり終えたら消す");
});
