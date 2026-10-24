// グリッドビューのライブ操作(gridLiveControls.js)の DOM テスト。harness は webviewLanePreview.test.mjs と同じ
// (実 HTML + 実バンドルを jsdom で動かす)。
//
// 契約: **1台だけ選択したとき**だけ拡大表示の下にツールバー(ホーム・タスク切替・拡大・縮小・軌跡の表示灯・
// 修飾キーの案内)を出し、操作は gridLiveAction で host へ送る。絵の上のクリックはタップ・素のドラッグはスワイプ・
// 500ms 以上のホールドは長押しで、
// **絵の上のダブルクリックは選択の切り替えにしない**(切り替えは絵の外側のダブルクリック)。

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
  const gridActions = () =>
    posts.filter((p) => p.type === "gridLiveAction").map((p) => JSON.parse(JSON.stringify(p)));
  return { window, document: window.document, gridActions, posts };
}

const send = (window, data) => window.dispatchEvent(new window.MessageEvent("message", { data }));

function sendDevices(window, count, machine, foldable) {
  const devices = Array.from({ length: count }, (_, i) => ({
    id: `d${i}`, name: `Dev ${i}`, platform: "ios", state: "connected",
    detail: "", kind: "virtual", udid: `UDID-${i}`, recording: false, registered: true,
    ...(machine ? { machine } : {}),
    ...(foldable !== undefined ? { foldable: foldable(i) } : {}),
  }));
  send(window, { type: "devices", devices });
}

function layoutTilesForHit(document) {
  const stub = (el, left, top, width, height) => {
    el.getBoundingClientRect = () => ({
      left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
    });
  };
  [...document.querySelectorAll("#grid .tile")].forEach((tile, i) => {
    stub(tile, i * 110, 0, 100, 200);
    stub(tile.querySelector(".frame-wrap"), i * 110 + 10, 30, 80, 140);
  });
}

function clickTile(document, index) {
  layoutTilesForHit(document);
  const frame = document.querySelectorAll("#grid .tile .frame-wrap")[index];
  frame.dispatchEvent(new document.defaultView.MouseEvent("click", {
    bubbles: true, clientX: index * 110 + 50, clientY: 100,
  }));
}

/** 1台を選び、絵(mjpeg)を出して、拡大表示の絵の矩形を (left=100, top=50, 200×400) に固定する */
function selectOneWithPicture(window, document, index = 0) {
  clickTile(document, index);
  send(window, { type: "frame", device: `d${index}`, jpegBase64: "QUJD", stream: true });
  const media = document.querySelector("#preview-grid .lane-preview .lane-preview-media");
  assert.ok(media, "拡大表示に絵がある");
  media.getBoundingClientRect = () => ({ left: 100, top: 50, width: 200, height: 400, right: 300, bottom: 450, x: 100, y: 50 });
  return media;
}

/** PointerEvent は jsdom に無いため MouseEvent に pointerId を後付けして代用する。 */
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false, shiftKey = false, metaKey = false }) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button, altKey, shiftKey, metaKey });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}

const controlsHost = (document) => document.getElementById("grid-live-controls").parentElement;
/** 1台表示の操作カラム = .lane-pair の中で拡大表示の右隣 */
const inSingleView = (document) => {
  const controls = document.getElementById("grid-live-controls");
  return controls.parentElement.classList.contains("lane-pair")
    && !!controls.previousElementSibling?.classList.contains("lane-preview");
};

test("ツールバーは1台選択のときだけ拡大表示の右隣のカラムに出し、2台に増やすと置き場へ戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  assert.equal(controlsHost(document).id, "grid-live-parking", "選択0台では出さない");

  clickTile(document, 0);
  assert.ok(inSingleView(document), "1台なら拡大表示の右隣のカラム");
  // 「戻る」は矢印だけのアイコンボタン = 名前は aria-label
  const labels = [...document.querySelectorAll("#grid-live-controls button")].filter((b) => !b.hidden)
    .map((b) => b.getAttribute("aria-label") || b.textContent);
  assert.deepEqual(labels, ["戻る", "ホーム", "タスク切替", "拡大", "縮小"]);
  const back = document.getElementById("grid-live-btn-back");
  assert.equal(back.textContent.trim(), "", "文字は出さない(矢印だけ)");
  assert.ok(back.querySelector("svg"), "矢印のアイコン");
  assert.ok(back.title, "説明はツールチップ");
  assert.equal(document.getElementById("grid-live-trace-indicator").textContent, "軌跡");
  const doubleTap = document.getElementById("grid-live-doubletap-indicator");
  assert.equal(doubleTap.textContent, "ダブルタップ");
  assert.equal(doubleTap.dataset.hoverTip, "Command(⌘)を押しながらクリックするとダブルタップします", "説明は自前のツールチップ");
  assert.equal(document.querySelector("#grid-live-controls .screenshot-hint"), null, "修飾キーの案内の文字は出さない");

  clickTile(document, 1);
  assert.equal(controlsHost(document).id, "grid-live-parking", "2台では出さない");
});

test("ボタンはその台への gridLiveAction を送る(他の機械のデバイスは remote を運ぶ)", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1, "M1Ultra");
  clickTile(document, 0);
  document.getElementById("grid-live-btn-home").click();
  document.getElementById("grid-live-btn-app-switcher").click();
  document.getElementById("grid-live-btn-zoom-in").click();
  document.getElementById("grid-live-btn-zoom-out").click();
  const actions = gridActions();
  assert.deepEqual(actions.map((m) => m.action), [
    { type: "home" }, { type: "appSwitcher" }, { type: "pinch", zoomIn: true }, { type: "pinch", zoomIn: false },
  ]);
  assert.ok(actions.every((m) => m.id === "d0"));
  assert.deepEqual(actions[0].remote, {
    machine: "M1Ultra", name: "Dev 0", platform: "ios", state: "connected", kind: "virtual", udid: "UDID-0",
  });
});

test("クリックはタップ・Command+クリックはダブルタップを送り、絵の上のダブルクリックは選択を変えない", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  // 2台選択 → 拡大表示のダブルクリックで「このデバイスのみ選択」(もう一度押すと2台へ戻る状態)
  clickTile(document, 1);
  clickTile(document, 0);
  document.querySelectorAll("#preview-grid .lane-preview")[0]
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(inSingleView(document), true, "1台表示になった");
  send(window, { type: "frame", device: "d0", jpegBase64: "QUJD", stream: true });
  const media = document.querySelector("#preview-grid .lane-preview .lane-preview-media");
  media.getBoundingClientRect = () => ({ left: 100, top: 50, width: 200, height: 400, right: 300, bottom: 450, x: 100, y: 50 });

  const plainDown = pointerEvent(window, "pointerdown", { x: 150, y: 150 });
  media.dispatchEvent(plainDown);
  assert.equal(plainDown.defaultPrevented, true, "絵の上の押下は操作として受ける(テキスト選択を始めない)");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  assert.deepEqual(gridActions().map((m) => m.action), [
    { type: "tapPoint", clickX: 50, clickY: 100, displayWidth: 200, displayHeight: 400 },
  ]);
  // クリックを続けて押したときに来る dblclick は2回のタップで、選択の切り替えにしない
  media.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(inSingleView(document), true, "1台表示のまま");

  // 素のドラッグはスワイプ(dragPoints)として送る
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 250 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 250 }));
  assert.equal(gridActions().length, 2, "素のドラッグもデバイスへ送る");
  const drag = gridActions()[1].action;
  assert.equal(drag.type, "dragPoints");
  assert.deepEqual([drag.fromX, drag.fromY, drag.toX, drag.toY, drag.displayWidth, drag.displayHeight], [50, 100, 100, 200, 200, 400]);
  assert.ok(drag.pressMs >= 0 && drag.dragMs >= 1, "押してから動かすまで・動かしてから離すまでの時間");

  const down = pointerEvent(window, "pointerdown", { x: 150, y: 150, metaKey: true });
  media.dispatchEvent(down);
  assert.equal(down.defaultPrevented, true);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 151, y: 151, metaKey: true }));
  assert.deepEqual(gridActions().map((m) => m.action).slice(2), [
    { type: "doubleTapPoint", clickX: 51, clickY: 101, displayWidth: 200, displayHeight: 400 },
  ]);

  media.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true, metaKey: true }));
  assert.equal(inSingleView(document), true, "1台表示のまま");

  // 絵の外側(デバイス名の段)のダブルクリックは従来どおり選択の切り替え(直前の2台へ戻る)
  document.querySelector("#preview-grid .lane-preview .lane-preview-header")
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(controlsHost(document).id, "grid-live-parking", "2台選択へ戻った");
});

const selectedTileCount = (document) => document.querySelectorAll("#grid .tile.selected").length;

test("「戻る」は「このデバイスのみ選択」の直前の選択へ戻し、控えが無ければ選択を解除する", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 3);
  // 2台選択 → 絵の外側のダブルクリックで1台だけ → 戻るで2台へ
  clickTile(document, 1);
  clickTile(document, 0);
  document.querySelectorAll("#preview-grid .lane-preview")[0]
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.equal(selectedTileCount(document), 1);
  document.getElementById("grid-live-btn-back").click();
  assert.equal(selectedTileCount(document), 2, "直前の2台へ戻った");
  assert.equal(controlsHost(document).id, "grid-live-parking", "1台表示を抜けた");

  // タイルを1枚だけ選んだ(控えが無い)ときは選択を解除する
  clickTile(document, 0);
  clickTile(document, 1);
  assert.equal(selectedTileCount(document), 0);
  clickTile(document, 2);
  assert.equal(selectedTileCount(document), 1);
  document.getElementById("grid-live-btn-back").click();
  assert.equal(selectedTileCount(document), 0, "選択を解除した");
  assert.equal(controlsHost(document).id, "grid-live-parking");
  assert.equal(gridActions().length, 0, "デバイスへは何も送らない");
});

test("Option+ドラッグは軌跡(tracePoints)を送り、Option だけのクリックはタップ", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150, altKey: true }));
  assert.equal(gridActions().length, 1);
  assert.equal(gridActions()[0].action.type, "tapPoint", "動かさなければタップ");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 400, y: 600, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 400, y: 600, altKey: true }));
  const message = gridActions()[1];
  assert.equal(message.action.type, "tracePoints");
  assert.equal(message.action.displayWidth, 200);
  assert.deepEqual(message.action.points[0], { x: 10, y: 10, t: 0 });
  const last = message.action.points[message.action.points.length - 1];
  assert.deepEqual([last.x, last.y], [200, 400], "絵の外で離しても絵の範囲に収める");
});

test("失敗はその台のものだけ出し、処理中はボタンを止める", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const error = document.getElementById("grid-live-error");

  send(window, { type: "live", message: { type: "devices", devices: [], selectedId: "other" } });
  send(window, { type: "live", message: { type: "actionError", message: "boom" } });
  assert.equal(error.textContent, "", "ライブ操作が別のデバイスにつないでいる間の失敗は出さない");

  send(window, { type: "live", message: { type: "gridActionError", id: "d0", message: "refused" } });
  assert.equal(error.textContent, "refused");

  send(window, { type: "live", message: { type: "devices", devices: [], selectedId: "d0" } });
  send(window, { type: "live", message: { type: "actionError", message: "tap failed" } });
  assert.equal(error.textContent, "tap failed");
  send(window, { type: "live", message: { type: "actionError", message: "" } });
  assert.equal(error.textContent, "");

  // 「戻る」は選択を変えるだけ(デバイスを触らない)なので処理中も押せる
  const deviceButtons = () => [...document.querySelectorAll("#grid-live-controls button")].filter((b) => b.id !== "grid-live-btn-back");
  send(window, { type: "live", message: { type: "busy", busy: true } });
  assert.ok(deviceButtons().length > 0 && deviceButtons().every((b) => b.disabled));
  assert.equal(document.getElementById("grid-live-btn-back").disabled, false);
  send(window, { type: "live", message: { type: "busy", busy: false } });
  assert.ok(deviceButtons().every((b) => !b.disabled));
});

test("グリッドビューの絵のカーソルは --touch-cursor の1箇所の定義を使う", async () => {
  const fs = await import("node:fs");
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  assert.match(css, /:root \{\s*--touch-cursor: url\('data:image\/svg\+xml/, "定義は1箇所");
  assert.match(css, /\.lanes-grid\.single-device \.lane-preview-media \{ cursor: var\(--touch-cursor\); \}/);
  assert.equal((css.match(/radialGradient/g) || []).length, 2, "カーソルの SVG を写して2つ持たない(開き・閉じタグの2回だけ)");
});

const visibleFoldLabels = (document, selector) =>
  [...document.querySelectorAll(selector)].filter((b) => b.dataset.fold && !b.hidden).map((b) => b.textContent);
// 開閉ボタンの出し分けは devices サイクルの後の microtask で掛かる(foldButtons.js の登録の注記)
const flushMicrotasks = () => new Promise((resolve) => setTimeout(resolve, 0));

test("開閉ボタンはモニターが折りたためると答えたデバイスだけに出し、押すと fold を送る", async (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  await flushMicrotasks();
  // d0 = 折りたためる / d1 = 折りたためない / d2 = まだ分からない(null)
  sendDevices(window, 3, undefined, (i) => [true, false, null][i]);
  clickTile(document, 0);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), ["折りたたむ", "開く"]);
  document.getElementById("grid-live-btn-fold").click();
  document.getElementById("grid-live-btn-unfold").click();
  assert.deepEqual(gridActions().map((m) => m.action), [
    { type: "fold", state: "fold" }, { type: "fold", state: "unfold" },
  ]);

  clickTile(document, 0);
  clickTile(document, 1);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), [], "折りたためない端末には出さない");
  clickTile(document, 1);
  clickTile(document, 2);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), [], "分からない間は出さない");

  // 後の devices サイクルで折りたためると分かったら出す
  sendDevices(window, 3, undefined, (i) => [true, false, true][i]);
  assert.deepEqual(visibleFoldLabels(document, "#grid-live-controls button"), ["折りたたむ", "開く"]);
});

function fakeClock(window) {
  let now = 1000;
  window.performance.now = () => now;
  return (ms) => { now += ms; };
}

test("動かさずに押し続けた時間が LONG_PRESS_MS(500ms)未満ならタップ・以上なら長押し(pressPoint)", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const advance = fakeClock(window);

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  advance(499);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  assert.equal(gridActions().at(-1).action.type, "tapPoint", "499ms はタップ");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  advance(500);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  assert.deepEqual(gridActions().at(-1).action,
    { type: "pressPoint", clickX: 50, clickY: 100, displayWidth: 200, displayHeight: 400, holdMs: 500 }, "500ms は長押し");

  // Command 押下はホールドしてもダブルタップ
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150, metaKey: true }));
  advance(900);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150, metaKey: true }));
  assert.equal(gridActions().at(-1).action.type, "doubleTapPoint");
});

test("素のドラッグの最中は始点から現在位置への直線を描き、Option ドラッグは軌跡の線に切り替える", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const overlay = document.querySelector(".grid-live-drag-overlay");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 250 }));
  const line = overlay.querySelector("line");
  assert.ok(overlay.classList.contains("visible"));
  assert.equal(overlay.classList.contains("trace"), false);
  assert.deepEqual(["x1", "y1", "x2", "y2"].map((a) => line.getAttribute(a)), ["50", "100", "100", "200"]);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 250 }));
  assert.equal(overlay.classList.contains("visible"), false, "離したら消える");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150, altKey: true }));
  assert.equal(overlay.classList.contains("trace"), true);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150, altKey: true }));
});

test("操作のカラムは拡大表示の右隣・パネルの左隣に並び、devices の周期で並べ替えない(ツールチップが点滅しない)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const pair = document.querySelector("#preview-grid .lane-pair");
  assert.deepEqual([...pair.children].map((el) => el.id || el.className.split(" ")[0]),
    ["lane-preview", "grid-live-controls", "grid-live-panel", "grid-live-panel-splitter", "lane"], "拡大表示 | 操作 | 操作パネル | 区切り | 実行ログ");
  assert.equal(document.querySelector("#preview-grid .lane-preview #grid-live-controls"), null, "絵の下には置かない");

  let moved = 0;
  const observer = new window.MutationObserver((records) => {
    moved += records.filter((r) => r.type === "childList").length;
  });
  observer.observe(pair, { childList: true });
  sendDevices(window, 1); // 約2秒ごとの devices サイクルと同じ経路
  sendDevices(window, 1);
  await new Promise((resolve) => setTimeout(resolve, 0));
  observer.disconnect();
  assert.equal(moved, 0, "周期のたびに並びを組み直さない");
});

test("操作のカラムは 上=戻る / 中=デバイス操作のグループ / 下=失敗の文言 の3段で、グループは上下中央(上下の段が同じ 1fr)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const controls = document.getElementById("grid-live-controls");
  assert.deepEqual([...controls.children].map((el) => el.className),
    ["grid-live-top", "screenshot-actions grid-live-device-group", "grid-live-bottom"]);
  const group = controls.querySelector(".grid-live-device-group");
  assert.equal(group.querySelector("#grid-live-btn-back"), null, "戻るはグループの外");
  assert.ok(controls.querySelector(".grid-live-top #grid-live-btn-back"), "戻るは上の段");
  assert.deepEqual(
    [...group.children].map((el) => el.id || el.className),
    ["grid-live-btn-home", "grid-live-btn-app-switcher", "grid-live-btn-zoom-in", "grid-live-btn-zoom-out",
      "grid-live-btn-fold", "grid-live-btn-unfold", "grid-live-doubletap-indicator", "grid-live-trace-indicator"],
    "ホーム〜修飾キーの案内(開閉ボタンを含む)を1つのグループに");
  assert.ok(controls.querySelector(".grid-live-bottom #grid-live-error"), "失敗の文言は下の段");

  const fs = await import("node:fs");
  const css = fs.readFileSync(path.resolve("src/webview/monitor/style.css"), "utf8");
  const rule = css.match(/\.grid-live-controls\s*\{([^}]*)\}/)[1];
  const rows = rule.match(/grid-template-rows:\s*([^;]+);/)[1].trim();
  const parts = rows.match(/minmax\([^)]*\)|\S+/g);
  assert.equal(parts.length, 3, rows);
  assert.equal(parts[0], parts[2], "上と下の段が同じ伸び方 = 中の段が上下中央");
  assert.match(parts[0], /1fr/);
  assert.equal(parts[1], "auto");
});

test("軌跡は離した後も、デバイスがなぞり終えるまで線を残す(その操作の busy が立って解けたら消す)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const overlay = () => document.querySelector(".grid-live-drag-overlay");
  const live = (message) => send(window, { type: "live", message });
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 200, altKey: true }));
  assert.ok(overlay().classList.contains("visible"), "離した後も線を残す");
  assert.ok(overlay().classList.contains("trace"), "軌跡の線のまま");
  assert.match(overlay().querySelector("polyline").getAttribute("points"), /^10,10 /, "描いた軌跡そのもの");
  live({ type: "busy", busy: true, observing: true });
  live({ type: "busy", busy: false, observing: false });
  assert.ok(overlay().classList.contains("visible"), "観測の busy の終わりでは消さない(まだなぞっていない)");
  live({ type: "busy", busy: true, observing: false });
  assert.ok(overlay().classList.contains("visible"), "なぞっている間は残す");
  live({ type: "busy", busy: false, observing: false });
  assert.equal(overlay().classList.contains("visible"), false, "なぞり終えたら消す");
});

test("軌跡の線は、撃つ前に断られたら(gridActionError)消し、素のドラッグの線は離したら消す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const overlay = () => document.querySelector(".grid-live-drag-overlay");
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 200, altKey: true }));
  send(window, { type: "live", message: { type: "gridActionError", id: "d0", message: "refused" } });
  assert.equal(overlay().classList.contains("visible"), false, "断られたら消す");
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 200 }));
  assert.equal(overlay().classList.contains("visible"), false, "素のドラッグ(スワイプ)は従来どおり離したら消す");
});

test("修飾キーの表示灯: Command(⌘)を押している間は「ダブルタップ」、Option(⌥)の間は「軌跡」を点け、離すか窓を外れたら消す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const doubleTap = document.getElementById("grid-live-doubletap-indicator");
  const trace = document.getElementById("grid-live-trace-indicator");
  const key = (type, k) => window.dispatchEvent(new window.KeyboardEvent(type, { key: k }));
  key("keydown", "Meta");
  assert.ok(doubleTap.classList.contains("active"));
  assert.ok(!trace.classList.contains("active"), "Command では軌跡を点けない");
  key("keyup", "Meta");
  assert.ok(!doubleTap.classList.contains("active"));
  key("keydown", "Alt");
  assert.ok(trace.classList.contains("active"));
  assert.ok(!doubleTap.classList.contains("active"), "Option ではダブルタップを点けない");
  key("keydown", "Meta");
  window.dispatchEvent(new window.Event("blur"));
  assert.ok(!doubleTap.classList.contains("active") && !trace.classList.contains("active"), "窓を外れたら両方消す");
});

const heldTipText = (document) => [...document.querySelectorAll(".hover-tip.held-tip")]
  .filter((el) => el.style.display === "block").map((el) => el.textContent);

test("修飾キーを押し続けると 0.8 秒後に表示灯の説明をツールチップで出す(1台表示のときだけ・入力欄やショートカットでは出さない)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  // 0.8 秒の待ちだけを手で進める(他の setTimeout はそのまま)
  const realSetTimeout = window.setTimeout.bind(window);
  let pending = [];
  window.setTimeout = (fn, ms, ...rest) => {
    if (ms !== 800) { return realSetTimeout(fn, ms, ...rest); }
    const entry = { fn, cancelled: false };
    pending.push(entry);
    return entry;
  };
  const realClearTimeout = window.clearTimeout.bind(window);
  window.clearTimeout = (id) => { if (id && typeof id === "object") { id.cancelled = true; } else { realClearTimeout(id); } };
  const elapse800 = () => { const due = pending; pending = []; for (const e of due) { if (!e.cancelled) { e.fn(); } } };
  const key = (type, k, target = window) =>
    target.dispatchEvent(new window.KeyboardEvent(type, { key: k, bubbles: true }));
  sendDevices(window, 1);
  key("keydown", "Meta");
  elapse800();
  assert.deepEqual(heldTipText(document), [], "1台表示でなければ出さない");
  key("keyup", "Meta");

  clickTile(document, 0);
  assert.ok(inSingleView(document));
  key("keydown", "Meta");
  assert.ok(document.getElementById("grid-live-doubletap-indicator").classList.contains("active"), "表示灯は押した瞬間に点ける");
  assert.deepEqual(heldTipText(document), [], "押した瞬間には出さない");
  elapse800();
  assert.deepEqual(heldTipText(document), ["Command(⌘)を押しながらクリックするとダブルタップします"], "0.8 秒後に出す");
  key("keyup", "Meta");
  assert.deepEqual(heldTipText(document), [], "離したら消す");

  key("keydown", "Meta");
  key("keyup", "Meta");
  elapse800();
  assert.deepEqual(heldTipText(document), [], "0.8 秒より前に離したら出さない");

  key("keydown", "Meta");
  key("keydown", "c"); // ⌘C
  elapse800();
  assert.deepEqual(heldTipText(document), [], "他のキーと一緒に押したら(ショートカット)出さない");
  key("keyup", "Meta");

  key("keydown", "Alt");
  elapse800();
  assert.deepEqual(heldTipText(document), ["Option(⌥)を押しながらドラッグすると、指の軌跡どおりに再生します"]);
  window.dispatchEvent(new window.Event("blur"));
  assert.deepEqual(heldTipText(document), [], "窓を外れたら消す");

  key("keydown", "Meta", document.getElementById("grid-live-type-text"));
  elapse800();
  assert.ok(document.getElementById("grid-live-doubletap-indicator").classList.contains("active"), "表示灯は点ける");
  assert.deepEqual(heldTipText(document), [], "入力欄で押した Command(⌘V 等)では出さない");
  key("keyup", "Meta");

  key("keydown", "Meta");
  elapse800();
  clickTile(document, 0); // 選択を外す = 1台表示をやめる
  assert.ok(!inSingleView(document));
  assert.deepEqual(heldTipText(document), [], "1台表示をやめたら残さない");
});

test("軌跡を離して実行する間は、なぞった線を薄くし、実行の開始後に絵が初めて描き替わった時刻を起点に太い線を重ねる", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const advance = fakeClock(window);
  const overlay = () => document.querySelector(".grid-live-drag-overlay");
  const done = () => document.querySelector(".grid-live-drag-overlay polyline.done").getAttribute("points");
  const live = (message) => send(window, { type: "live", message });
  const nextFrame = () => new Promise((resolve) => window.requestAnimationFrame(resolve));
  const pictureChanged = () =>
    document.querySelector("#preview-grid .lane-preview img.lane-preview-media").dispatchEvent(new window.Event("load"));

  // 押して 100ms 止まってから動かす = 指が動き始めるのは t=100
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  assert.ok(!overlay().classList.contains("playing"), "なぞっている間は普通の線");
  advance(100);
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 111, y: 60, altKey: true })); // 動いたうちに入らない
  advance(100);
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true })); // t=200 で動き始め
  advance(100);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 300, y: 200, altKey: true })); // t=300
  assert.ok(overlay().classList.contains("playing"), "離したら薄い線にする");
  assert.equal(done(), "", "実行が始まるまでは太い線を出さない");

  pictureChanged();
  assert.equal(done(), "", "実行の開始前の描き替わりは起点にしない");
  live({ type: "busy", busy: true, observing: false }); // 実行の開始
  advance(500);
  await nextFrame();
  assert.equal(done(), "", "実行が始まっても、絵が描き替わるまでは出さない(配信の遅れの分だけ先走らない)");

  pictureChanged(); // 指が動き始めた点(t=200)が映った = 起点は今から 200ms 前
  assert.equal(done(), "10,10 11,10 100,150 100,150");
  advance(50);
  await nextFrame();
  assert.equal(done(), "10,10 11,10 100,150 150,150", "経過 250ms ぶん");
  advance(100);
  await nextFrame();
  assert.equal(done(), "10,10 11,10 100,150 200,150", "なぞった時間を過ぎたら全体");

  live({ type: "busy", busy: false, observing: false });
  assert.ok(!overlay().classList.contains("playing") && !overlay().classList.contains("visible"), "終わったら消す");
  assert.equal(done(), "");
});

test("軌跡の太い線の起点は、実行の開始より前へは戻さない(無関係な描き替わりを拾っても busy 起点より先走らない)", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const advance = fakeClock(window);
  const done = () => document.querySelector(".grid-live-drag-overlay polyline.done").getAttribute("points");
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  advance(300);
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true })); // 動き始め t=300
  advance(100);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 300, y: 200, altKey: true }));
  send(window, { type: "live", message: { type: "busy", busy: true, observing: false } });
  advance(10);
  document.querySelector("#preview-grid .lane-preview img.lane-preview-media").dispatchEvent(new window.Event("load"));
  // now - 300 は busy より前 → 起点は busy の時刻 = 経過 10ms
  assert.equal(done(), "10,10 13,14.666666666666668");
});

test("前の操作の実行中に押したクリックは送らず、黙らずにその旨を出し、実行が終わったら消す(後から届いた失敗の文言は残す)", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const live = (message) => send(window, { type: "live", message });
  const error = () => document.getElementById("grid-live-error");
  const click = () => {
    media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
    window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  };
  live({ type: "busy", busy: true, observing: false });
  click();
  assert.equal(gridActions().length, 0, "溜めて後で撃たない");
  assert.match(error().textContent, /前の操作を実行中/);
  assert.ok(error().classList.contains("neutral"), "エラー色にしない");
  live({ type: "busy", busy: false, observing: false });
  assert.equal(error().textContent, "", "実行が終わったら消す");

  live({ type: "busy", busy: true, observing: true });
  click();
  assert.equal(gridActions().length, 1, "観測の最中は送る(host が観測の終わりを待って撃つ)");
  assert.equal(error().textContent, "");

  live({ type: "busy", busy: true, observing: false });
  click();
  live({ type: "devices", devices: [], selectedId: "d0" });
  live({ type: "actionError", message: "tap failed" });
  live({ type: "busy", busy: false, observing: false });
  assert.equal(error().textContent, "tap failed", "前の操作の失敗の文言は消さない");
});

test("なぞっている最中に座標 (0,0) のポインターイベントが混ざっても、軌跡に絵の左上の角を入れない(離した位置が (0,0) なら最後の位置)", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const advance = fakeClock(window);
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  advance(50);
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true }));
  advance(50);
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 0, y: 0, altKey: false })); // 混ざったイベント
  assert.ok(document.getElementById("grid-live-trace-indicator").classList.contains("active"),
    "混ざったイベントの修飾キーで表示灯を消さない");
  advance(50);
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 250, y: 300, altKey: true }));
  advance(50);
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 0, y: 0, altKey: true })); // 離した位置も (0,0)
  const sent = gridActions().at(-1).action;
  assert.equal(sent.type, "tracePoints");
  assert.deepEqual(sent.points.map((p) => [p.x, p.y]), [[10, 10], [100, 150], [150, 250], [150, 250]],
    "角 (0,0) を含まず、離した位置は最後に採った位置");
  assert.ok(!/(^| )0,0( |$)/.test(document.querySelector(".grid-live-drag-overlay polyline").getAttribute("points")),
    "描いた線にも角を入れない");
});

test("軌跡の操作の応答(gestureActionDone)で太い線を描き切り、実際の再生時間との比を覚えて次の軌跡の線の速さにする", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const advance = fakeClock(window);
  const done = () => document.querySelector(".grid-live-drag-overlay polyline.done").getAttribute("points");
  const live = (message) => send(window, { type: "live", message });
  const nextFrame = () => new Promise((resolve) => window.requestAnimationFrame(resolve));
  const pictureChanged = () =>
    document.querySelector("#preview-grid .lane-preview img.lane-preview-media").dispatchEvent(new window.Event("load"));
  // 0ms で押して即動かし(t=0 で動き始め)、100ms で (200,200)・200ms で (300,200) で離す
  const trace = () => {
    media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
    advance(100);
    window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true }));
    advance(100);
    window.dispatchEvent(pointerEvent(window, "pointerup", { x: 300, y: 200, altKey: true }));
  };

  // 指が動き始めるのは t=100(最初の move)。busy から 200ms 後に絵が描き替わる = 起点は t=100
  trace();
  live({ type: "busy", busy: true, observing: false });
  advance(200);
  pictureChanged();
  advance(50);
  await nextFrame();
  assert.equal(done(), "10,10 100,150 150,150", "初回はなぞった時間どおり(起点 t=100 から 50ms)");
  advance(250); // 起点から終わりまで実際は 300ms(なぞった残り 100ms の 3 倍)
  live({ type: "gestureActionDone", ok: true });
  assert.equal(done(), "10,10 100,150 200,150", "応答が届いたら描き切る");
  live({ type: "busy", busy: false, observing: false });

  trace();
  live({ type: "busy", busy: true, observing: false });
  advance(200);
  pictureChanged();
  advance(150);
  await nextFrame();
  assert.equal(done(), "10,10 100,150 150,150", "2回目は前回の比(3 倍)で遅く伸ばす = 起点から 150ms は t=150");
  live({ type: "gestureActionDone", ok: false });
  assert.equal(done(), "", "再生できなかったら線を消す(描き切らない)");
  assert.ok(!document.querySelector(".grid-live-drag-overlay").classList.contains("visible"));
});

test("押したまま動かさずに LONG_PRESS_MS(500ms)を過ぎたら始点に「長押し」の印を出し、先に動かせば出さない・離したら消す", async (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  const media = selectOneWithPicture(window, document, 0);
  const overlay = () => document.querySelector(".grid-live-drag-overlay");
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, altKey: true }));
  await wait(300);
  assert.ok(!overlay().classList.contains("long-press"), "まだ境目の前");
  await wait(300);
  assert.ok(overlay().classList.contains("long-press"), "動かさずに 500ms を過ぎた");
  assert.equal(overlay().querySelector(".long-press-label").textContent, "長押し");
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200, altKey: true }));
  assert.ok(overlay().classList.contains("long-press"), "その後に動かしても長押しからのドラッグのまま");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 200, altKey: true }));
  assert.ok(!overlay().classList.contains("long-press"), "離したら消す");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60 }));
  window.dispatchEvent(pointerEvent(window, "pointermove", { x: 200, y: 200 })); // すぐ動かす
  await wait(600);
  assert.ok(!overlay().classList.contains("long-press"), "先に動かせば出さない");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 200, y: 200 }));

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 110, y: 60, metaKey: true }));
  await wait(600);
  assert.ok(!overlay().classList.contains("long-press"), "Command(ダブルタップ)は押していた時間に関係なくダブルタップなので出さない");
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 110, y: 60, metaKey: true }));
});
