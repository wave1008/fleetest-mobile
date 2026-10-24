// monitorLiveController.ts の bridgeStarting(LiveBridgeAutoStarter が自動起動を進行中かどうか。
// 契約: Sources/fleetest/ApiLiveCommand.swift 冒頭)配線のソース走査。
// MonitorLiveController は vscode.ExtensionContext 等が要りスタブでは作れないため、
// monitorLiveControllerTracePoints.test.mjs と同じ方針で走査して守る:
//   ①applySnapshotResult は bridgeStarting 中の失敗を postActionError(エラー表示)へ回さないこと
//   ②runAction の action 失敗は bridgeStarting 中だけ中立の案内(live.bridgeStartingActionNotice)を
//     neutral:true で出し、撃ち直さないこと
//   ③postActionError(neutral) が neutral のときも connectionBannerShown を立てること
//     (serve 復帰[handleConnectionOk]で自動的に消えるようにするため)

import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function codeOnly(source) {
  return source
    .split("\n")
    .filter((line) => !line.trim().startsWith("//") && !line.trim().startsWith("*") && !line.trim().startsWith("/*"))
    .join("\n");
}

function controllerSource() {
  return codeOnly(fs.readFileSync(path.join(root, "src/monitorLiveController.ts"), "utf8"));
}

function methodBody(source, methodStartNeedle, nextMethodNeedle) {
  const start = source.indexOf(methodStartNeedle);
  assert.notEqual(start, -1, `${methodStartNeedle} が見つからない`);
  const end = source.indexOf(nextMethodNeedle, start);
  assert.notEqual(end, -1, `${nextMethodNeedle} が見つからない(終端の切り出しに失敗)`);
  return source.slice(start, end);
}

test("applySnapshotResult: bridgeStarting 中の失敗は postActionError へ回さない", () => {
  const body = methodBody(
    controllerSource(),
    "private applySnapshotResult(result: LiveSnapshot | LiveErrorResult): void {",
    "private async fetchSnapshot(): Promise<void> {",
  );
  const notOkRange = body.indexOf("if (!result.ok) {");
  assert.notEqual(notOkRange, -1, "!result.ok の分岐が見当たらない");
  const notOkBody = body.slice(notOkRange, body.indexOf("this.handleConnectionOk();"));
  assert.match(notOkBody, /if \(result\.bridgeStarting\) \{\s*\n\s*return;/,
    "起動中の失敗はここで return し、postActionError を撃たないこと");
});

test("runAction: action の失敗は bridgeStarting のときだけ中立の案内(neutral:true)を出す", () => {
  const body = methodBody(
    controllerSource(),
    "private async runAction(",
    "private async runTapAtPoint(",
  );
  assert.match(
    body,
    /if \(action\.bridgeStarting\) \{\s*\n\s*this\.postActionError\(t\("live\.bridgeStartingActionNotice"\), true\)/,
    "action.bridgeStarting のときは live.bridgeStartingActionNotice を neutral:true で出すこと",
  );
  assert.match(body, /\} else \{\s*\n\s*this\.postActionError\(action\.error\);/,
    "bridgeStarting でない通常の失敗は従来どおり action.error を出すこと");
});

test("postActionError: neutral のときも connectionBannerShown を立てる(serve 復帰で自動的に消えるように)", () => {
  const body = methodBody(
    controllerSource(),
    "private postActionError(message: string, neutral = false): void {",
    "private handleConnectionOk(",
  );
  assert.match(body, /this\.connectionBannerShown = neutral \|\| isConnectionClassMessage\(message\)/,
    "neutral のときも connectionBannerShown を立てること");
  assert.match(body, /neutral \? \{ neutral: true \} : \{\}/,
    "neutral:true は webview へ送る actionError メッセージにも載せること");
});
