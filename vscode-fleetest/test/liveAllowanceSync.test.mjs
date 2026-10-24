// ライブ操作の要求上限に足す猶予(fold)が、Swift 側の内側の上限と一致することを確認する。
// Swift の真実は Sources/FTCore/DefaultWait.swift の `DefaultWait.seconds`
// (serve 側の command watchdog も `ApiLiveServeCommand.watchdogAllowanceSeconds` で同じ値を使う)。
// 片方だけ変えると、拡張が serve を張り直す時刻と serve 自身の猶予がずれる。
// process.cwd() は npm test 実行時に vscode-fleetest ルート(protocolVersion.test.mjs と同じ前提)。

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { serveCommandAllowanceMs } from "../src/liveModel";

const swiftSource = readFileSync(path.join(process.cwd(), "..", "Sources", "FTCore", "DefaultWait.swift"), "utf8");

test("fold の猶予は DefaultWait.seconds と一致する", () => {
  const match = swiftSource.match(/static let seconds: Double = (\d+)/);
  assert.ok(match, "DefaultWait.swift から seconds を抽出できませんでした");
  assert.equal(serveCommandAllowanceMs({ cmd: "fold", state: "fold" }), Number(match[1]) * 1000);
});
