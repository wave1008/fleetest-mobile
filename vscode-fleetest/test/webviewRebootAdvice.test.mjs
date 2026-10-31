// モニター上部の「マシンの再起動のおすすめ」(deviceTiles.js の renderRebootAdvice)を実 HTML+実バンドルで動かす DOM テスト(jsdom)。
// 文面・本文の省略・省略したときのホバーを見る。方式は webviewMachineHealth.test.mjs と同じ。

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
    bundle: true, platform: "node", format: "cjs", target: "node18",
    write: false, external: ["vscode"], logLevel: "silent",
  });
  const vscodeStub = { Uri: { joinPath: (_base, ...segs) => ({ path: `/${segs.join("/")}` }) } };
  const patchedRequire = (id) => (id === "vscode" ? vscodeStub : require2(id));
  const mod = { exports: {} };
  new Function("module", "exports", "require", htmlBuild.outputFiles[0].text)(mod, mod.exports, patchedRequire);
  panelHtml = mod.exports.renderHtml(
    { asWebviewUri: (uri) => `https://localhost${uri.path}`, cspSource: "https://localhost" },
    { path: "" },
  );
  const mainBuild = await esbuild.build({
    entryPoints: [path.resolve("src/webview/monitor/main.js")],
    bundle: true, platform: "browser", format: "iife", target: "es2022",
    write: false, logLevel: "silent",
  });
  webviewBundle = mainBuild.outputFiles[0].text;
});

function createWebview(posted = [], persisted = undefined) {
  const dom = new JSDOM(panelHtml, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://localhost/" });
  const { window } = dom;
  const noop = () => {};
  window.HTMLCanvasElement.prototype.getContext = () => ({
    setTransform: noop, clearRect: noop, beginPath: noop, moveTo: noop, lineTo: noop,
    closePath: noop, fillRect: noop, stroke: noop, fill: noop, globalAlpha: 1, fillStyle: "", strokeStyle: "",
    lineWidth: 0, lineJoin: "", lineCap: "",
  });
  window.acquireVsCodeApi = () => ({ postMessage: (m) => posted.push(m), setState: noop, getState: () => persisted });
  window.HTMLElement.prototype.scrollIntoView = noop;
  window.Element.prototype.setPointerCapture = noop;
  window.Element.prototype.releasePointerCapture = noop;
  window.eval(webviewBundle);
  window.document.getElementById("tab-dashboard").click();
  const send = (data) => window.dispatchEvent(new window.MessageEvent("message", { data }));
  return { window, document: window.document, send };
}

const tipOf = (element) => element.getAttribute("data-hover-tip") || "";

test("再起動しても戻らないデバイスの案内は、どの台かを本文に出す(無ければ行を出さない)", (t) => {
  const { window, document, send } = createWebview();
  t.after(() => window.close());
  const device = (name, spec) => ({ id: name, name, platform: "android", state: "connected", detail: "",
    kind: "virtual", recording: false, registered: true, frozen: false, screenState: null, rebootAdvised: false, ...spec });
  const advice = document.getElementById("reboot-advice");
  send({ type: "devices", devices: [device("Pixel 9-05", { rebootAdvised: true }), device("Pixel 9-06", {}),
    device("Pixel 9-07", { machine: "M1Max", rebootAdvised: true })] });
  assert.ok(advice.classList.contains("visible"));
  assert.equal(advice.textContent, "⚠️ デバイスを再起動しても画面の描画が回復しませんでした: Pixel 9-05、Pixel 9-07 (M1Max)。"
    + "マシンの再起動をおすすめします(対象マシン: ローカル、M1Max)");
  assert.equal(tipOf(advice), "", "省略が無ければホバーは本文の繰り返しなので出さない");
  assert.doesNotMatch(advice.textContent, /Pixel 9-06/);
  // 1マシンの全台が落ちても上部の1行を伸ばさない
  send({ type: "devices", devices: ["a", "b", "c", "d", "e"].map((name) => device(name, { machine: "M1Max", rebootAdvised: true })) });
  assert.equal(advice.textContent, "⚠️ デバイスを再起動しても画面の描画が回復しませんでした: a (M1Max)、b (M1Max)、c (M1Max)、ほか2台。"
    + "マシンの再起動をおすすめします(対象マシン: M1Max)");
  assert.equal(tipOf(advice), "a (M1Max)\nb (M1Max)\nc (M1Max)\nd (M1Max)\ne (M1Max)", "全台はホバーで見る");
  send({ type: "devices", devices: [device("Pixel 9-05", {})] });
  assert.ok(!advice.classList.contains("visible"));
});
