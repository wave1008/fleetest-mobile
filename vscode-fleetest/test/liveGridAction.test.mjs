// グリッドビューのライブ操作(gridLiveAction)の host 側。webview 側の挙動は webviewGridLiveControls.test.mjs。
// MonitorLiveController はスタブで作れないので、handleGridAction の配線はソース走査で守る
// (monitorLiveControllerTracePoints.test.mjs と同じ方針)。

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { isGridLiveAction } from "../src/liveModel";
import { isMonitorFromWebviewMessage } from "../src/monitorWebviewMessages";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

test("isGridLiveAction: ツールバー・画面の操作・入力・更新の11種だけを通す", () => {
  assert.equal(isGridLiveAction({ type: "home" }), true);
  assert.equal(isGridLiveAction({ type: "appSwitcher" }), true);
  assert.equal(isGridLiveAction({ type: "pinch", zoomIn: false }), true);
  assert.equal(isGridLiveAction({ type: "fold", state: "fold" }), true);
  assert.equal(isGridLiveAction({ type: "fold", state: "half" }), false, "開閉の向きは2つだけ");
  assert.equal(isGridLiveAction({ type: "doubleTapPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }), true);
  assert.equal(isGridLiveAction({ type: "tracePoints", points: [{ x: 0, y: 0, t: 0 }], displayWidth: 3, displayHeight: 4 }), true);
  assert.equal(isGridLiveAction({ type: "tapPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }), true);
  assert.equal(isGridLiveAction({
    type: "dragPoints", fromX: 0, fromY: 0, toX: 1, toY: 1, displayWidth: 3, displayHeight: 4, pressMs: 0, dragMs: 1,
  }), true);
  assert.equal(isGridLiveAction({ type: "pressPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4, holdMs: 600 }), true);
  assert.equal(isGridLiveAction({ type: "typeText", text: "abc" }), true);
  assert.equal(isGridLiveAction({ type: "refreshSnapshot" }), true);
  // 中身の検査(欠けた欄は通さない)
  assert.equal(isGridLiveAction({ type: "pressPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }), false);
  assert.equal(isGridLiveAction({ type: "typeText" }), false);
  // グリッドビューからは撃たないもの(デバイスの切り替え・インストール・アプリ起動・録画)
  assert.equal(isGridLiveAction({ type: "selectDevice", id: "ios:A" }), false);
  assert.equal(isGridLiveAction({ type: "installApp", appProfile: "p" }), false);
  assert.equal(isGridLiveAction({ type: "launchApp", appProfile: "p" }), false);
  assert.equal(isGridLiveAction({ type: "startRecord", appProfile: "p", autoInstall: true }), false);
  assert.equal(isGridLiveAction({ type: "stopRecord" }), false);
  assert.equal(isGridLiveAction({ type: "pinch", zoomIn: "yes" }), false, "中身の型も検査する");
});

test("isMonitorFromWebviewMessage: gridLiveAction は id・操作・remote を検査する", () => {
  const remote = { machine: "M1Ultra", name: "iPhone", platform: "ios", state: "connected", kind: "virtual" };
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "ios:iPhone", action: { type: "home" } }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "home" }, remote }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "", action: { type: "home" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "refreshSnapshot" } }), true);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "stopRecord" } }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x" }), false);
  assert.equal(isMonitorFromWebviewMessage({ type: "gridLiveAction", id: "x", action: { type: "home" }, remote: { ...remote, machine: "" } }), false);
});

function handleGridActionBody() {
  const source = fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8");
  const start = source.indexOf("async handleGridAction(");
  assert.notEqual(start, -1, "handleGridAction が見つからない");
  const end = source.indexOf("private async openDevice(", start);
  assert.notEqual(end, -1);
  return source.slice(start, end);
}

test("handleGridAction: 別のデバイスへは openDevice で選び直してから撃つ(処理中は断る)", () => {
  const body = handleGridActionBody();
  const busy = body.indexOf("if (this.busy) {");
  const open = body.indexOf("await this.openDevice(id)");
  assert.ok(busy !== -1 && open !== -1 && busy < open, "処理中は切り替えず断ってから選び直す");
  assert.match(body, /if \(this\.selectedDeviceId !== id\) \{\s*this\.post\(\{ type: "gridActionError"/,
    "選び直せなかったら黙らずにグリッドビューへ言う");
  // 撃つのは1経路(座標変換・操作記録を2つ持たない)
  assert.match(body, /this\.runGridAction\(action\);\s*\}\s*$/);
  assert.ok(!body.includes("isRecordingInProgress"), "記録の仕組みは持たない");
});

test("handleGridAction: 座標の操作は画面サイズ(lastScreen)が揃うまで観測を待つ", () => {
  const body = handleGridActionBody();
  assert.match(body, /action\.type === "tapPoint" \|\| action\.type === "doubleTapPoint" \|\| action\.type === "tracePoints"\s*\|\| action\.type === "dragPoints" \|\| action\.type === "pressPoint"\) && !this\.lastScreen/);
  assert.match(body, /await this\.waitForIdle\(SERVE_REQUEST_TIMEOUT_MS\);\s*if \(!this\.lastScreen\) \{\s*await this\.refreshSnapshot\(\);/);
});

test("handleGridAction: 切り替えの中で観測が済んでいれば「更新」を二重に撃たない(切り替えなかったときは撃つ)", () => {
  const body = handleGridActionBody();
  assert.match(body, /const switching = this\.selectedDeviceId !== id;/);
  assert.match(body, /if \(switching && action\.type === "refreshSnapshot" && this\.lastScreen\) \{\s*return;\s*\}/);
  // 早期 return は座標操作の待ちより前・実際に撃つ手前
  assert.ok(body.indexOf('action.type === "refreshSnapshot" && this.lastScreen') < body.indexOf("this.runGridAction(action)"));
});

test("handleGridAction: 撃つ直前(切り替え・待ちの後)に gridActionStarted を送る —— webview が操作前の観測を直接の結果と取り違えない", () => {
  const body = handleGridActionBody();
  assert.match(body, /this\.post\(\{ type: "gridActionStarted", id \}\);\s*this\.runGridAction\(action\);\s*\}\s*$/,
    "合図と撃つ処理の間に何も挟まない(挟むと別の観測が割り込める)");
  assert.ok(body.lastIndexOf("await this.waitForIdle(") < body.indexOf('type: "gridActionStarted"'), "待ちの後");
  assert.ok(body.indexOf("await this.openDevice(id)") < body.indexOf('type: "gridActionStarted"'), "切り替えの後");
});

test("runAction: 操作記録に撃ったデバイスの id を付ける", () => {
  const source = fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8");
  const start = source.indexOf("private async runAction(");
  const run = source.slice(start, source.indexOf("private async runTapAtPoint(", start));
  assert.match(run, /const loggedDeviceId = this\.selectedDeviceId;/);
  assert.equal((run.match(/this\.postOperationLog\(options\.logLabel, (true|false), mcp, loggedDeviceId\)/g) ?? []).length, 2,
    "成功と失敗の両方の行にデバイスを付ける");
  assert.ok(!source.includes("injectTestStep"), "デバイスの分からない行は流さない");
  assert.match(source, /\.\.\.\(deviceId !== undefined \? \{ deviceId \} : \{\}\)/);
});

test("観測(画面の撮り直し・一覧の取り直し)は busy.observing を立て、その最中に届いた画面の操作は観測の終わりを待って撃つ", () => {
  const source = fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8");
  const body = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
  assert.match(body("private async refreshSnapshot(", "// ---- tap/type/drag/press"), /this\.setBusy\(true, true\);/,
    "画面の撮り直しは観測");
  assert.match(body("private async runAction(", "private async runTapAtPoint("), /this\.setBusy\(true\);/,
    "操作は観測ではない(画面が変わる最中は受け付けない)");
  const handle = body("private runGridAction(message: GridLiveAction): void {", "switch (message.type) {");
  assert.match(handle, /if \(this\.busy && this\.busyObserving && OBSERVATION_DEFERRABLE_ACTIONS\.has\(message\.type\)\) \{\s*void this\.waitForIdle\(SERVE_REQUEST_TIMEOUT_MS\)\.then\(\(\) => this\.runGridAction\(message\)\);\s*return;/,
    "観測の最中の画面の操作は断らずに待って撃つ");
  const set = body("const OBSERVATION_DEFERRABLE_ACTIONS", "]);");
  for (const type of ["tapPoint", "doubleTapPoint", "pressPoint", "dragPoints", "tracePoints", "typeText", "home"]) {
    assert.ok(set.includes(`"${type}"`), `${type} は観測の終わりを待って撃つ`);
  }
  assert.ok(!set.includes('"refreshSnapshot"'), "更新は従来どおり busy で何もしない");
});

test("applyDevices: 頼まれたデバイスが一覧に無ければ未選択にする(先頭や fallback に serve を立てない)", () => {
  const source = fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8");
  const start = source.indexOf("private applyDevices(");
  assert.notEqual(start, -1);
  const body = source.slice(start, source.indexOf("private applyFallback(", start));
  assert.match(body, /this\.selectedDeviceId = preferred \?\? \(stillExists \? this\.selectedDeviceId : undefined\);/);
  assert.ok(!/options\[0\]/.test(body), "先頭へ倒すと、頼まれていないデバイスでブリッジの自動起動まで撃つ");
});

test("handleServeEvent: 軌跡(gesture)の操作の応答が届いた時点で gestureActionDone を送る(続く観測を待たない)", () => {
  const source = fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8");
  const start = source.indexOf("private handleServeEvent(");
  assert.notEqual(start, -1);
  const body = source.slice(start, source.indexOf("this.settlePendingServeRequest(", start));
  assert.match(body, /if \(event\.kind === "actionResult"\) \{\s*pending\.action = event\.result;\s*if \(pending\.cmd === "gesture"\) \{\s*this\.post\(\{ type: "gestureActionDone", ok: event\.result\.ok \}\);/);
  assert.match(source, /expectsAction: command\.cmd !== "refresh",\s*cmd: command\.cmd,/, "送ったコマンドの cmd を控える");
});
