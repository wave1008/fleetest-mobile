// monitorRunLog(他者の run のログ)の検証・owner 照合・レーンへの積み込み・laneHydrate の復元。
import assert from "node:assert/strict";
import { test } from "node:test";
import { isMonitorEvent } from "../src/monitorDeviceModel";
import { reduceMonitorRunLog } from "../src/monitorRunLogModel";
import { createRunLaneState, snapshotRunLaneState } from "../src/runLaneModel";
import { streamOwnerValue, childEnv, STREAM_OWNER_ENV } from "../src/childEnv";

const ev = (over) => ({ kind: "monitorRunLog", device: "ios:Sim 1", pid: 42, lines: ["✅ 1. tap \"#a\""], ...over });

test("owner 無しの行は device のレーンへ積まれる(リモートの machine 付き id も)", () => {
  const state = createRunLaneState();
  const a = reduceMonitorRunLog(state, ev({ lines: ["l1", "l2"] }), streamOwnerValue());
  assert.deepEqual(a, [
    { type: "line", laneId: "ios:Sim 1", text: "l1" },
    { type: "line", laneId: "ios:Sim 1", text: "l2" },
  ]);
  const b = reduceMonitorRunLog(state, ev({ device: "android:M1Ultra/Pixel-01", machine: "M1Ultra", owner: "other:1" }), streamOwnerValue());
  assert.equal(b[0].laneId, "android:M1Ultra/Pixel-01");
});

test("owner が自分の値の行は捨てる・別の値は出る", () => {
  const state = createRunLaneState();
  assert.deepEqual(reduceMonitorRunLog(state, ev({ owner: streamOwnerValue() }), streamOwnerValue()), []);
  assert.equal(reduceMonitorRunLog(state, ev({ owner: "x:1" }), streamOwnerValue()).length, 1);
  assert.equal(snapshotRunLaneState(state).linesByLane["ios:Sim 1"].length, 1);
});

test("laneState に積まれ laneHydrate のスナップショットで戻る", () => {
  const state = createRunLaneState();
  reduceMonitorRunLog(state, ev({ lines: ["a", "b"] }), streamOwnerValue());
  assert.deepEqual(snapshotRunLaneState(state).linesByLane["ios:Sim 1"], ["a", "b"]);
});

test("streamOwnerValue は childEnv が子へ渡す値と同じ", () => {
  assert.equal(childEnv()[STREAM_OWNER_ENV], streamOwnerValue());
});

test("検証関数は壊れた形を弾く・null の任意欄は正規化する", () => {
  assert.equal(isMonitorEvent(ev({})), true);
  assert.equal(isMonitorEvent({ kind: "monitorRunLog", device: "d", pid: 1 }), false);
  assert.equal(isMonitorEvent(ev({ lines: "x" })), false);
  assert.equal(isMonitorEvent(ev({ lines: ["a", 1] })), false);
  assert.equal(isMonitorEvent(ev({ pid: "1" })), false);
  assert.equal(isMonitorEvent(ev({ device: 1 })), false);
  const v = ev({ machine: null, owner: null, runID: null });
  assert.equal(isMonitorEvent(v), true);
  assert.equal(v.owner, undefined);
});
