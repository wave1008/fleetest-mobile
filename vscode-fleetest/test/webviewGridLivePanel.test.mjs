// グリッドビューの操作パネル(gridLivePanel.js)の DOM テスト。harness は webviewGridLiveControls.test.mjs と同じ
// (実 HTML + 実バンドルを jsdom で動かす)。
//
// 契約: 1台選択のとき要素一覧・入力するテキスト・操作記録のパネルが .lane-pair の中の操作カラムの右隣に入る。
// **選択しただけでは観測しない**ので、一覧はライブ操作がそのデバイスにつながっている(devices.selectedId が一致する)
// ときの snapshot だけで描く。操作記録は deviceId を持つ行だけ・デバイスごと。枠は画面を変える操作の直接の結果では描かない。

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
function createWebview(initialState) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const posts = [];
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posts.push(m), setState: (s) => { window.__state = s; }, getState: () => initialState });
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
function pointerEvent(window, type, { x, y, pointerId = 1, button = 0, altKey = false, shiftKey = false }) {
  const event = new window.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button, altKey, shiftKey });
  Object.defineProperty(event, "pointerId", { value: pointerId });
  return event;
}


const live = (window, message) => send(window, { type: "live", message });
const panelOf = (document) => document.getElementById("grid-live-panel");
const rowsOf = (document) => [...document.querySelectorAll("#grid-live-elements-list .element-row")];
const boxRects = (document) => [...document.querySelectorAll(".grid-live-boxes-overlay rect:not(.hot)")];
/** 拡大表示の絵が描き替わった(一枚絵の読み込み完了。jsdom は画像を読まないので load を起こす) */
const imageLoaded = (window, document) =>
  document.querySelector("#preview-grid .lane-preview img.lane-preview-media").dispatchEvent(new window.Event("load"));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const imageRedrawn = async (window, document) => { imageLoaded(window, document); };

const ELEMENTS = [
  { ref: "e1", frame: { x: 0, y: 0, width: 400, height: 800 }, frameText: "0,0 400x800", line: "Window" },
  { ref: "e2", frame: { x: 0, y: 0, width: 100, height: 100 }, frameText: "0,0 100x100", line: "Button A" },
];
const snapshot = (elements = ELEMENTS) => ({
  type: "snapshot", platform: "ios", screen: { width: 400, height: 800 }, image: "QUJD", elements, notes: [],
});

/** 1台選択 + ライブ操作が d0 につながっている状態 */
function setupConnected(t) {
  const ctx = createWebview();
  t.after(() => ctx.window.close());
  sendDevices(ctx.window, 1);
  const media = selectOneWithPicture(ctx.window, ctx.document, 0);
  live(ctx.window, { type: "devices", devices: [], selectedId: "d0" });
  return { ...ctx, media };
}

function toggleBoxes(window, document, on) {
  const toggle = document.getElementById("grid-live-show-boxes");
  toggle.checked = on;
  toggle.dispatchEvent(new window.Event("change", { bubbles: true }));
}

test("パネルは1台選択のとき .lane-pair の中の操作カラムの右隣に入り、2台に増やすと置き場へ戻る", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  assert.equal(panelOf(document).parentElement.id, "grid-live-parking", "選択0台では出さない");

  clickTile(document, 0);
  const panel = panelOf(document);
  assert.ok(panel.parentElement.classList.contains("lane-pair"), "1台なら .lane-pair の中");
  assert.equal(panel.previousElementSibling.id, "grid-live-controls", "操作カラムの右隣");
  assert.ok(panel.previousElementSibling.previousElementSibling.classList.contains("lane-preview"), "並びは 拡大表示 | 操作 | パネル");
  assert.equal(panel.nextElementSibling, null, "パネルが右端(実行ログの複製・区切りは置かない)");
  // インストール・レコーディング・アプリを起動は置かない
  assert.equal(panel.querySelector("#live-btn-install, #live-btn-record, #live-btn-launch"), null);
  assert.ok(panel.querySelector("#grid-live-elements-list.elements-list"));
  assert.ok(panel.querySelector("#grid-live-oplog-list.oplog-list .oplog-head"), "操作記録の見出し行");

  clickTile(document, 1);
  assert.equal(panelOf(document).parentElement.id, "grid-live-parking", "2台では置き場へ戻る");
});

test("snapshot は live の selectedId が1台表示のデバイスと一致するときだけ一覧に描く", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const empty = document.getElementById("grid-live-elements-empty");
  assert.notEqual(empty.style.display, "none", "未取得なら案内を出す");

  live(window, { type: "devices", devices: [], selectedId: "other" });
  live(window, snapshot());
  assert.equal(rowsOf(document).length, 0, "別のデバイスにつながっている間の木は採らない");
  assert.notEqual(empty.style.display, "none");

  live(window, { type: "devices", devices: [], selectedId: "d0" });
  live(window, snapshot());
  assert.deepEqual(rowsOf(document).map((r) => r.querySelector(".element-cell-main").textContent), ["Window", "Button A"]);
  assert.equal(rowsOf(document)[1].querySelector(".element-cell-frame").textContent, "0,0 100x100");
  assert.equal(empty.style.display, "none");

  live(window, { type: "clearSnapshot" });
  assert.equal(rowsOf(document).length, 0, "clearSnapshot で捨てる");
  assert.notEqual(empty.style.display, "none");

  live(window, snapshot());
  live(window, { type: "devices", devices: [], selectedId: "other" });
  assert.equal(rowsOf(document).length, 0, "つなぎ替わったら前の木を持ち越さない");
});

test("選択しただけでは観測(refreshSnapshot)を撃たず、「更新」を押したときだけ撃つ", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  assert.equal(gridActions().length, 0);
  document.getElementById("grid-live-btn-refresh-snapshot").click();
  assert.deepEqual(gridActions().map((m) => [m.id, m.action]), [["d0", { type: "refreshSnapshot" }]]);

  live(window, { type: "busy", busy: true });
  assert.equal(document.getElementById("grid-live-btn-refresh-snapshot").disabled, true, "処理中は止める");
  live(window, { type: "busy", busy: false });
  assert.equal(document.getElementById("grid-live-btn-refresh-snapshot").disabled, false);
});

function enter(window, input, init = {}) {
  const event = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...init });
  if (init.keyCode !== undefined) { Object.defineProperty(event, "keyCode", { value: init.keyCode }); }
  input.dispatchEvent(event);
  return event;
}

test("入力欄は Enter で typeText を送って空にし、IME 変換中・処理中は送らない", (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const input = document.getElementById("grid-live-type-text");
  assert.equal(input.placeholder, "入力するテキスト(Enterで送信)");

  input.value = "hello";
  enter(window, input, { key: "a" });
  assert.equal(gridActions().length, 0, "Enter 以外では送らない");
  enter(window, input, { isComposing: true });
  enter(window, input, { keyCode: 229 });
  assert.equal(gridActions().length, 0, "IME 変換中の Enter は送らない");
  assert.equal(input.value, "hello");

  live(window, { type: "busy", busy: true });
  enter(window, input);
  assert.equal(gridActions().length, 0, "処理中は送らない");
  assert.equal(input.value, "hello", "送らなかったら消さない");
  live(window, { type: "busy", busy: false });

  const event = enter(window, input);
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(gridActions().map((m) => m.action), [{ type: "typeText", text: "hello" }]);
  assert.equal(input.value, "", "送ったら空にする");
});

test("focusTypeInput は live が1台表示のデバイスにつながっているときだけ入力欄へ移す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  const input = document.getElementById("grid-live-type-text");
  live(window, { type: "devices", devices: [], selectedId: "other" });
  live(window, { type: "focusTypeInput" });
  assert.notEqual(document.activeElement, input);
  live(window, { type: "devices", devices: [], selectedId: "d0" });
  live(window, { type: "focusTypeInput" });
  assert.equal(document.activeElement, input);
});

test("操作記録は deviceId が1台表示のデバイスの行だけ出し、デバイスごとに控えて、クリアはそのデバイスのぶんだけ", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  clickTile(document, 0);
  const labels = () => [...document.querySelectorAll("#grid-live-oplog-list .oplog-row .oplog-label")].map((e) => e.textContent);

  live(window, { type: "operationLog", label: "ホーム", ok: true, dsl: "home()", deviceId: "d0" });
  live(window, { type: "operationLog", label: "別のデバイス", ok: true, deviceId: "d1" });
  live(window, { type: "operationLog", label: "テスト実行の行", ok: true });
  live(window, { type: "operationLog", label: "失敗", ok: false, deviceId: "d0" });
  assert.deepEqual(labels(), ["ホーム", "✗ 失敗"], "deviceId の無い行・別デバイスの行は出さない");
  const dsl = document.querySelector("#grid-live-oplog-list .oplog-row .oplog-dsl");
  assert.equal(dsl.textContent, "home()");

  // 別のデバイスを1台表示にすると、そのデバイスの控えへ差し替わる
  clickTile(document, 0);
  clickTile(document, 1);
  assert.deepEqual(labels(), ["別のデバイス"]);
  document.getElementById("grid-live-btn-oplog-clear").click();
  assert.deepEqual(labels(), []);

  clickTile(document, 1);
  clickTile(document, 0);
  assert.deepEqual(labels(), ["ホーム", "✗ 失敗"], "クリアは表示中のデバイスのぶんだけ");
});

test("操作記録は1デバイスあたり200行までで、古い行から捨てる", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  for (let i = 0; i < 201; i++) {
    live(window, { type: "operationLog", label: `op${i}`, ok: true, deviceId: "d0" });
  }
  const rows = () => [...document.querySelectorAll("#grid-live-oplog-list .oplog-row .oplog-label")].map((e) => e.textContent);
  assert.equal(rows().length, 200);
  assert.equal(rows()[0], "op1");
  // 控えも同じ上限(表示し直しても増えない)
  clickTile(document, 0);
  clickTile(document, 0);
  assert.equal(rows().length, 200);
  assert.equal(rows()[0], "op1");
});

test("枠: 操作を送った直後の snapshot では描かず、次の snapshot で描く(一覧は消さない)", async (t) => {
  const { window, document, media } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2, "操作の前の木はそのまま描く");

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  assert.equal(boxRects(document).length, 0, "操作を送った時点で枠を消す");
  assert.equal(rowsOf(document).length, 2, "要素一覧は消さない");

  live(window, { type: "gridActionStarted", id: "d0" }); // host が撃つ直前の合図
  live(window, snapshot([ELEMENTS[1]]));
  assert.equal(boxRects(document).length, 0, "操作の直接の結果では描かない");
  assert.equal(rowsOf(document).length, 1, "一覧は入れ替わる");
  await imageRedrawn(window, document);

  live(window, snapshot());
  assert.equal(boxRects(document).length, 2, "次(整定後)の木で描く");
  const rect = boxRects(document)[1];
  // 表示 200x400 / 画面 400x800: frame 100x100 → 50x50
  assert.deepEqual(["x", "y", "width", "height"].map((a) => rect.getAttribute(a)), ["0", "0", "50", "50"]);
});

test("枠: 次の snapshot が来なくても、直接の結果から BOXES_SETTLE_CAP_MS(2800ms)で最新の木を描く", async (t) => {
  const { window, document, media } = setupConnected(t);
  const timers = [];
  const realSetTimeout = window.setTimeout.bind(window);
  window.setTimeout = (fn, delay, ...rest) => {
    if (delay === 2800) { timers.push(fn); return 0; }
    return realSetTimeout(fn, delay, ...rest);
  };
  toggleBoxes(window, document, true);
  live(window, snapshot());

  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot());
  assert.equal(boxRects(document).length, 0);
  assert.equal(timers.length, 1, "直接の結果を受けた時点で上限のタイマーを張る");
  await imageRedrawn(window, document);
  timers[0]();
  assert.equal(boxRects(document).length, 2, "上限で最新の木を描く");
});

// 操作の直接の結果の次の「整定後の木」は、グリッド自身が SETTLE_REFRESH_MS(700ms)後の撮り直しで取る
// (host はタブ時代のような自動の撮り直しを撃たない)。
const tapOnce = (window, media) => {
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
};
const refreshCount = (gridActions) => gridActions().filter((m) => m.action.type === "refreshSnapshot").length;

test("枠: 操作の直接の結果を受けたら 700ms 後に自分で refreshSnapshot を撃ち、届いた整定後の木で描く", async (t) => {
  const { window, document, media, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  const before = refreshCount(gridActions);
  tapOnce(window, media);
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot([ELEMENTS[1]])); // 直接の結果(遷移の途中)
  await imageRedrawn(window, document);
  assert.equal(refreshCount(gridActions), before, "直接の結果の時点では撃たない");
  await sleep(400);
  assert.equal(refreshCount(gridActions), before, "700ms 経つまでは撃たない");
  await sleep(450);
  assert.equal(refreshCount(gridActions), before + 1, "700ms 後に撮り直しを撃つ");
  assert.equal(boxRects(document).length, 0, "撮り直しの結果が届くまでは描かない");
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2, "撮り直しの木は非操作の snapshot として採り、枠を描く");
  await sleep(900);
  assert.equal(refreshCount(gridActions), before + 1, "撮り直しは1回だけ(撮り直しが撮り直しを呼ばない)");
});

test("枠: 整定の撮り直しの予約は、拡大表示の絵が描き替わるたびに先送りする(絵が止まってから撮る)", async (t) => {
  const { window, document, media, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  const before = refreshCount(gridActions);
  tapOnce(window, media);
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot([ELEMENTS[1]]));
  await imageRedrawn(window, document); // 自分が出した一枚絵の読み込み(先送りの対象ではない)
  await sleep(450);
  imageLoaded(window, document); // 遷移の途中の描き替わり
  await sleep(450); // 直接の結果から 900ms・最後の描き替わりから 450ms
  assert.equal(refreshCount(gridActions), before, "絵が動いた直後なので先送りされている");
  await sleep(350);
  assert.equal(refreshCount(gridActions), before + 1, "最後の描き替わりから 700ms 後に撃つ");
});

test("枠: 整定の撮り直しは処理中(busy)なら終わってから撃つ", async (t) => {
  const { window, document, media, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  const before = refreshCount(gridActions);
  tapOnce(window, media);
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot([ELEMENTS[1]]));
  await imageRedrawn(window, document);
  live(window, { type: "busy", busy: true, observing: false }); // 別の処理が走っている
  await sleep(900);
  assert.equal(refreshCount(gridActions), before, "busy の間は撃たない");
  live(window, { type: "busy", busy: false, observing: false });
  await sleep(800);
  assert.equal(refreshCount(gridActions), before + 1, "終わってから撃つ");
});

test("枠: 次の操作を送ると、前の操作の整定の撮り直しの予約は捨てる", async (t) => {
  const { window, document, media, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  const before = refreshCount(gridActions);
  tapOnce(window, media);
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot([ELEMENTS[1]]));
  await imageRedrawn(window, document);
  tapOnce(window, media); // 次の操作(まだ合図は来ていない)
  await sleep(900);
  assert.equal(refreshCount(gridActions), before, "前の操作の予約で撮り直さない(次の操作の結果が撮る)");
});

test("枠: 木が無いまま ON にすると撮り直しを撃ち、届いた木で描く。OFF なら描かない", (t) => {
  const { window, document, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  assert.deepEqual(gridActions().map((m) => m.action), [{ type: "refreshSnapshot" }]);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2);

  toggleBoxes(window, document, false);
  assert.equal(boxRects(document).length, 0);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 0, "OFF では描かない");
  assert.equal(rowsOf(document).length, 2, "一覧は出る");
});

test("ホバー: 絵の上の点の最小の要素を一覧の行と枠で対に光らせ、枠 OFF でも行は光る", (t) => {
  const { window, document, media } = setupConnected(t);
  live(window, snapshot());
  const move = (x, y) => media.dispatchEvent(new window.MouseEvent("pointermove", { bubbles: true, clientX: x, clientY: y }));
  const hotRows = () => rowsOf(document).filter((r) => r.classList.contains("hot")).map((r) => r.querySelector(".element-cell-main").textContent);

  move(110, 60); // 表示 (10,10) → 画面 (20,20): Window と Button A の重なり → 面積最小の Button A
  assert.deepEqual(hotRows(), ["Button A"]);
  assert.equal(document.querySelector(".grid-live-boxes-overlay rect.hot"), null, "枠 OFF では赤枠を出さない");
  move(250, 300); // 画面 (300,500): Window だけ
  assert.deepEqual(hotRows(), ["Window"]);

  toggleBoxes(window, document, true);
  move(110, 60);
  const hot = document.querySelector(".grid-live-boxes-overlay rect.hot");
  assert.ok(hot, "枠 ON なら hot の枠を最前面に重ねる");
  assert.equal(hot.getAttribute("width"), "50");
  assert.ok(document.getElementById("grid-live-elements-list").classList.contains("boxes-on"));
  assert.equal(hot, document.querySelector(".grid-live-boxes-overlay").lastElementChild, "最前面 = 最後の子");
});

test("ホバー: 枠 OFF で一覧の行に載せると単一ホバー枠を絵の矩形に重ねて出す", (t) => {
  const { window, document } = setupConnected(t);
  live(window, snapshot());
  const hover = () => document.querySelector(".grid-live-hover-box");
  rowsOf(document)[1].dispatchEvent(new window.MouseEvent("mouseenter", { bubbles: true }));
  assert.equal(hover().style.display, "block");
  assert.deepEqual([hover().style.width, hover().style.height], ["50px", "50px"]);
  rowsOf(document)[1].dispatchEvent(new window.MouseEvent("mouseleave", { bubbles: true }));
  assert.equal(hover().style.display, "none");
});

test("1台表示を外れると状態を全部捨てる(枠・一覧・案内)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  const media = selectOneWithPicture(window, document, 0);
  live(window, { type: "devices", devices: [], selectedId: "d0" });
  toggleBoxes(window, document, true);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2);
  void media;

  clickTile(document, 1); // 2台
  assert.equal(rowsOf(document).length, 0);
  assert.equal(boxRects(document).length, 0);
  assert.equal(document.querySelector(".grid-live-boxes-overlay"), null, "オーバーレイは拡大表示から外す");
});

test("i18n: 操作パネルの文言(見出し・更新・トグル・入力欄・操作記録)", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  const text = (selector) => panelOf(document).querySelector(selector).textContent.trim();
  assert.equal(text(".elements-header > span"), "要素一覧");
  assert.equal(text("#grid-live-btn-refresh-snapshot"), "更新");
  // トグルはグリッドビューの見出し行(台数の右)に居る
  assert.equal(document.querySelector("#grid-view-header .grid-view-boxes-toggle").textContent.trim(), "バウンディングボックスを表示");
  assert.equal(text(".oplog-header > span"), "操作記録");
  assert.equal(text("#grid-live-btn-oplog-clear"), "クリア");
  assert.equal(document.getElementById("grid-live-type-text").placeholder, "入力するテキスト(Enterで送信)");
  assert.match(document.getElementById("grid-live-elements-empty").textContent, /更新/);
});

test("枠のトグルは既定 OFF で、前回の ON を覚えていても OFF から始める", (t) => {
  const { window, document } = createWebview({ gridLiveShowBoxes: true });
  t.after(() => window.close());
  assert.equal(document.getElementById("grid-live-show-boxes").checked, false);
  const toggle = document.getElementById("grid-live-show-boxes");
  toggle.checked = true;
  toggle.dispatchEvent(new window.Event("change", { bubbles: true }));
  assert.equal(window.__state?.gridLiveShowBoxes, undefined, "切り替えても状態に書かない");
});

test("枠のトグルが ON のまま1台表示を開くと、木を1回取りに行き、届いたら枠を描く(OFF なら取りに行かない)", async (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  const toggle = document.getElementById("grid-live-show-boxes");
  toggle.checked = true;
  toggle.dispatchEvent(new window.Event("change", { bubbles: true }));
  // 2台選択 → 絵の外側のダブルクリックで「このデバイスのみ選択」(報告された経路)
  clickTile(document, 1);
  clickTile(document, 0);
  document.querySelectorAll("#preview-grid .lane-preview")[0]
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  await Promise.resolve(); // 送りは次のマイクロタスク
  const refreshes = gridActions().filter((m) => m.action.type === "refreshSnapshot");
  assert.equal(refreshes.length, 1, "開いた時点で1回だけ取りに行く");
  assert.equal(refreshes[0].id, "d0");

  send(window, { type: "frame", device: "d0", jpegBase64: "QUJD", stream: true });
  const media = document.querySelector("#preview-grid .lane-preview .lane-preview-media");
  media.getBoundingClientRect = () => ({ left: 100, top: 50, width: 200, height: 400, right: 300, bottom: 450, x: 100, y: 50 });
  live(window, { type: "devices", devices: [], selectedId: "d0" });
  live(window, snapshot());
  assert.equal(boxRects(document).length, ELEMENTS.length, "届いた木で枠を描く");
});

test("枠のトグルが OFF なら1台表示を開いても木を取りに行かない", async (t) => {
  const { window, document, gridActions } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 1);
  clickTile(document, 0);
  await Promise.resolve();
  assert.equal(gridActions().length, 0, "選択しただけでは撮らない");
});

test("「バウンディングボックスを表示」はグリッドビューの見出しの台数の右に居て、1台表示のときだけ出し、押しても見出しの開閉に波及しない", (t) => {
  const { window, document, gridActions, posts } = createWebview();
  t.after(() => window.close());
  const label = document.getElementById("grid-live-show-boxes").closest("label");
  assert.equal(label.parentElement.id, "grid-view-header", "グリッドビューの見出し行");
  assert.equal(label.previousElementSibling.id, "lanes-selection-status", "台数の右");
  assert.equal(document.querySelector("#grid-live-panel #grid-live-show-boxes"), null, "操作パネルには置かない");

  sendDevices(window, 2);
  assert.equal(label.hidden, true, "選択0台では出さない");
  clickTile(document, 0);
  assert.equal(label.hidden, false, "1台表示で出す");

  // label のクリックは label と input の2回 click が来るので、見出しへ伝わると開閉が2回走って見かけの状態は戻る ——
  // 状態ではなく「開閉の要求を1回も出さない」で見る
  const toggleRequests = () => posts.filter((p) => p.type === "setGridViewVisible").length;
  const before = toggleRequests();
  label.click(); // label 経由で input も切り替わる
  assert.equal(document.getElementById("grid-live-show-boxes").checked, true, "トグルは切り替わる");
  assert.equal(toggleRequests(), before, "グリッドビューの開閉は走らない");
  assert.ok(gridActions().some((m) => m.action.type === "refreshSnapshot"), "ON で木を取りに行く(従来どおり)");

  clickTile(document, 1);
  assert.equal(label.hidden, true, "2台では出さない");
});

test("入力するテキストは拡大表示の絵のすぐ下に置き、中のダブルクリックで選択を変えず、2台で置き場へ戻す", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  sendDevices(window, 2);
  const row = document.getElementById("grid-live-type-row");
  assert.equal(row.parentElement.id, "grid-live-parking", "選択0台では出さない");
  // 2台選択 → 絵の外側のダブルクリックで1台へ(この直後の拡大表示のダブルクリックは「直前の2台へ戻す」になる =
  // 入力欄のダブルクリックが伝わると選択が変わる状態で確かめる)
  clickTile(document, 1);
  clickTile(document, 0);
  document.querySelectorAll("#preview-grid .lane-preview")[0]
    .dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.ok(row.parentElement.classList.contains("lane-preview"), "拡大表示の中");
  assert.ok(row.previousElementSibling.classList.contains("lane-preview-frame"), "絵のすぐ下");
  assert.equal(document.querySelector("#grid-live-panel #grid-live-type-text"), null, "操作パネルには置かない");

  // 単語を選ぶダブルクリックは選択の切り替え(拡大表示のダブルクリック)にしない
  const input = document.getElementById("grid-live-type-text");
  input.dispatchEvent(new window.MouseEvent("dblclick", { bubbles: true, cancelable: true }));
  assert.ok(row.parentElement.classList.contains("lane-preview"), "1台表示のまま");
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 1);

  clickTile(document, 1);
  assert.equal(document.querySelectorAll("#grid .tile.selected").length, 2);
  assert.equal(row.parentElement.id, "grid-live-parking", "2台では置き場へ戻す");
});

test("枠: 合図(gridActionStarted)より前に届いた snapshot は操作前の画面 —— 直接の結果と取り違えず、本物の結果の次で描く", async (t) => {
  // 実際の順序: 撃つ前に host が直前の処理(整定の撮り直し)を待つ / 開いたときの観測を挟む
  const { window, document, media } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));

  live(window, snapshot()); // 合図より前 = 操作前の画面
  assert.equal(boxRects(document).length, 0, "操作前の画面の木では描かない");
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot([ELEMENTS[1]])); // 本物の直接の結果(遷移の途中)
  assert.equal(boxRects(document).length, 0, "直接の結果では描かない(取り違えると、ここで途中の位置に描いていた)");
  await imageRedrawn(window, document);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2, "整定後の木で描く");
});

test("枠: 操作の途中でデバイスを切り替えても(clearSnapshot → 開いたときの観測)、合図の後の結果まで描かない", async (t) => {
  const { window, document, media } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, { type: "devices", devices: [], selectedId: "other" }); // ライブ操作は別のデバイスにつないでいる
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  // host: openDevice → 選択の切り替え → clearSnapshot → 開いたときの観測
  live(window, { type: "devices", devices: [], selectedId: "d0" });
  live(window, { type: "clearSnapshot" });
  live(window, snapshot());
  assert.equal(boxRects(document).length, 0, "開いたときの観測(操作前の画面)では描かない");
  assert.equal(rowsOf(document).length, 2, "一覧は出す");
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, snapshot([ELEMENTS[1]]));
  assert.equal(boxRects(document).length, 0, "直接の結果では描かない");
  await imageRedrawn(window, document);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2);
});

test("枠: 撃つ前に断られた操作(gridActionError)は画面を変えていないので、手元の木で描き直す", (t) => {
  const { window, document, media } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  assert.equal(boxRects(document).length, 0);
  live(window, { type: "gridActionError", id: "d0", message: "busy" });
  assert.equal(boxRects(document).length, 2, "断られたら元の木で描く");
});

test("枠: 操作を挟まない観測(「更新」・トグル ON)は絵の描き替わりを待たない(画面は変わっていない)", (t) => {
  const { window, document } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2, "その場で描く");
  document.getElementById("grid-live-btn-refresh-snapshot").click();
  live(window, snapshot([ELEMENTS[1]]));
  assert.equal(boxRects(document).length, 1, "「更新」の結果もその場で描く");
});

test("拡大表示の絵は devices の周期で同じ src を入れ直さない(入れ直すと load が鳴り、古い絵で「描き替わった」と読む)", async (t) => {
  const { window, document } = setupConnected(t);
  const img = document.querySelector("#preview-grid .lane-preview img.lane-preview-media");
  let sets = 0;
  const observer = new window.MutationObserver((records) => { sets += records.filter((r) => r.attributeName === "src").length; });
  observer.observe(img, { attributes: true });
  sendDevices(window, 1);
  sendDevices(window, 1);
  await new Promise((resolve) => setTimeout(resolve, 0));
  observer.disconnect();
  assert.equal(sets, 0, "同じ絵なら src に触らない");
  send(window, { type: "frame", device: "d0", jpegBase64: "WFla", stream: true });
  assert.match(img.getAttribute("src"), /WFla$/, "新しい絵は入れる");
});

test("枠: 観測の一枚絵を拡大表示に出し、その絵の読み込みが終わってから描く(ポーリングが遅い経路でも枠と絵が揃う)", (t) => {
  const { window, document } = setupConnected(t);
  toggleBoxes(window, document, true);
  const img = () => document.querySelector("#preview-grid .lane-preview img.lane-preview-media");
  live(window, { ...snapshot(), image: "TkVX" }); // 拡大表示に出ている絵(QUJD)とは違う瞬間の絵
  assert.match(img().getAttribute("src"), /TkVX$/, "観測の絵を拡大表示に出す");
  assert.equal(boxRects(document).length, 0, "その絵が出る(読み込みが終わる)までは描かない");
  rowsOf(document)[1].dispatchEvent(new window.MouseEvent("mouseenter", { bubbles: true }));
  assert.equal(document.querySelector(".grid-live-hover-box").style.display, "none", "ホバー枠も待つ");
  imageLoaded(window, document);
  assert.equal(boxRects(document).length, 2, "絵が出たら描く");
});

test("枠: 観測の絵が既に拡大表示に出ているなら待たずに描く", (t) => {
  const { window, document } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot()); // 拡大表示の絵(QUJD)と同じ
  assert.equal(boxRects(document).length, 2);
});

test("枠: 一枚絵の load / error が鳴らなくても保険の上限(1000ms)で描く", (t) => {
  const { window, document } = setupConnected(t);
  const caps = [];
  const realSetTimeout = window.setTimeout.bind(window);
  window.setTimeout = (fn, delay, ...rest) => {
    if (delay === 1000) { caps.push(fn); return 0; }
    return realSetTimeout(fn, delay, ...rest);
  };
  toggleBoxes(window, document, true);
  live(window, { ...snapshot(), image: "TkVX" });
  assert.equal(boxRects(document).length, 0);
  assert.equal(caps.length, 1, "一枚絵を入れた時点で上限を張る");
  caps[0]();
  assert.equal(boxRects(document).length, 2);
});

test("枠: 操作の結果の流れでも、整定後の木の絵が出てから描く(直接の結果の絵も先に出す)", (t) => {
  const { window, document, media } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  media.dispatchEvent(pointerEvent(window, "pointerdown", { x: 150, y: 150 }));
  window.dispatchEvent(pointerEvent(window, "pointerup", { x: 150, y: 150 }));
  const img = () => document.querySelector("#preview-grid .lane-preview img.lane-preview-media");
  live(window, { type: "gridActionStarted", id: "d0" });
  live(window, { ...snapshot([ELEMENTS[1]]), image: "TUlE" }); // 直接の結果(遷移の途中の絵)
  assert.match(img().getAttribute("src"), /TUlE$/, "直接の結果の絵も出す(遅い経路でも絵が先に変わる)");
  imageLoaded(window, document);
  live(window, { ...snapshot(), image: "RU5E" }); // 整定後の木と絵
  assert.equal(boxRects(document).length, 0, "整定後の絵が出るまで描かない");
  imageLoaded(window, document);
  assert.equal(boxRects(document).length, 2, "整定後の絵が出たら描く");
});

test("一枚絵を出した後は、それより前に撮られたポーリングの絵を捨てる(古い絵に戻らない)。後に撮られた絵と配信のフレームは入れる", (t) => {
  const { window, document } = setupConnected(t);
  toggleBoxes(window, document, true);
  const img = () => document.querySelector("#preview-grid .lane-preview img.lane-preview-media");
  live(window, { ...snapshot(), image: "TkVX", capturedAtMs: 2000 });
  assert.match(img().getAttribute("src"), /TkVX$/);
  send(window, { type: "frame", device: "d0", jpegBase64: "T0xE", width: 1, height: 1, capturedAtMs: 1500 });
  assert.match(img().getAttribute("src"), /TkVX$/, "一枚絵より前に撮られたポーリングの絵は捨てる");
  send(window, { type: "frame", device: "d0", jpegBase64: "TkVXRVI=", width: 1, height: 1, capturedAtMs: 2500 });
  assert.match(img().getAttribute("src"), /TkVXRVI=$/, "後に撮られた絵は入れる");
  live(window, { ...snapshot(), image: "U0VDT05E", capturedAtMs: 3000 });
  send(window, { type: "frame", device: "d0", jpegBase64: "U1RSRUFN", stream: true });
  assert.match(img().getAttribute("src"), /U1RSRUFN$/, "配信のフレーム(時刻を持たない = 届いた順が撮った順)は入れる");
});

// ---- 操作と無関係に絵が変わったとき(OS のダイアログ等) ----------------------------------------------

const ALERT_ELEMENTS = [
  { ref: "a1", frame: { x: 40, y: 260, width: 320, height: 360 }, frameText: "40,260 320x360", line: "Alert" },
];
const refreshes = (gridActions) => gridActions().filter((m) => m.action.type === "refreshSnapshot").length;

test("操作と無関係に絵が変わったら、700ms 止まってから撮り直して新しい木(ダイアログ)の枠を描く(変わった時点では消さない)", async (t) => {
  const { window, document, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  assert.equal(boxRects(document).length, 2);
  const before = refreshes(gridActions);
  imageLoaded(window, document); // 配信・ポーリングで絵が変わった(遅れて出たダイアログ)
  assert.equal(boxRects(document).length, 2, "変わった時点では消さない(文字カーソルの点滅でも消える = 点滅になる)");
  await sleep(400);
  assert.equal(refreshes(gridActions), before, "まだ止まっていない");
  await sleep(400);
  assert.equal(refreshes(gridActions), before + 1, "止まったら撮り直す");
  live(window, snapshot(ALERT_ELEMENTS));
  assert.equal(boxRects(document).length, 1, "撮り直した木(ダイアログ)で描く");
});

test("絵が動き続けても、上限(BOXES_SETTLE_CAP_MS = 2800ms)で撮り直す", async (t) => {
  const { window, document, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  const before = refreshes(gridActions);
  const started = Date.now();
  while (Date.now() - started < 3200 && refreshes(gridActions) === before) {
    imageLoaded(window, document); // 300ms ごとに描き替わる(止まらない)
    await sleep(300);
  }
  assert.equal(refreshes(gridActions), before + 1, "止まらなくても上限で撮る");
  assert.ok(Date.now() - started >= 2700, "上限より前には撮らない");
});

test("自分が出した一枚絵の読み込みでは撮り直さない(撮り直しが撮り直しを呼ばない)", async (t) => {
  const { window, document, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, { ...snapshot(), image: "TkVX" }); // 一枚絵を出す(読み込み待ち)
  const before = refreshes(gridActions);
  imageLoaded(window, document); // その一枚絵の読み込み
  assert.equal(boxRects(document).length, 2);
  await sleep(800);
  assert.equal(refreshes(gridActions), before, "撮り直さない");
});

test("実行中は絵が変わると枠を消すが、撮り直さない", async (t) => {
  const { window, document, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  send(window, { type: "runEvent", action: { type: "workerRunning", workerId: "d0", running: true } });
  const before = refreshes(gridActions);
  imageLoaded(window, document);
  assert.equal(boxRects(document).length, 0, "古い木の枠は残さない");
  await sleep(800);
  assert.equal(refreshes(gridActions), before, "実行中は撮り直さない");
});

test("文字カーソルの点滅のように描き替わり続けても枠は消えず、打ち切りで撮った木が同じなら撮り直しを繰り返さない", async (t) => {
  const { window, document, gridActions } = setupConnected(t);
  toggleBoxes(window, document, true);
  live(window, snapshot());
  const before = refreshes(gridActions);
  let minBoxes = Infinity;
  let answered = false;
  const started = Date.now();
  // 9 秒 = 打ち切り(2.8 秒)で1回撮った後、止めなければ次の打ち切りが来る長さ(約 3 秒 + 2.8 秒)を含める
  while (Date.now() - started < 9000) {
    imageLoaded(window, document); // 0.5 秒ごとの点滅
    minBoxes = Math.min(minBoxes, boxRects(document).length);
    if (!answered && refreshes(gridActions) > before) {
      live(window, snapshot()); // 打ち切りで撮った木 = 前と同じ(点滅は木を変えない)
      answered = true;
    }
    await sleep(500);
    minBoxes = Math.min(minBoxes, boxRects(document).length);
  }
  assert.equal(minBoxes, 2, "点滅の間、枠は一度も消えない");
  assert.equal(refreshes(gridActions), before + 1, "打ち切りで1回撮り、木が同じならその後は点滅が続いても撮らない");
});

test("操作パネルと実行ログの間の区切りも、幅の割合の保存も無い", (t) => {
  const { window, document } = createWebview();
  t.after(() => window.close());
  assert.equal(document.getElementById("grid-live-panel-splitter"), null);
  sendDevices(window, 1);
  clickTile(document, 0);
  assert.equal(document.getElementById("grid-live-panel").style.flexGrow, "", "幅は CSS の flex に任せる");
  assert.equal(document.querySelector("#preview-grid .lane-log-mirror"), null);
});
