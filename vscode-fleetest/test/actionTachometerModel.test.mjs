// actionTachometerModel.test.mjs
// run ボードの「アクション/秒」メーターの純粋ロジック(src/actionTachometerModel.ts)。
// 時刻は引数で渡すので、秒を ms に直して時計を自分で進める。

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ACTIONS_PER_SECOND_PER_SEGMENT, ActionTachometer, METER_WINDOW_MS, METER_TIME_CONSTANT_MS, easeToward, segmentLevel, segmentCount, litSegments, METER_SEGMENTS, segmentTier,
} from "../src/actionTachometerModel";

const S = 1000;
const ev = (actions, extra = {}) => ({
  observed: true,
  runs: [{ pid: 1, runID: "r1", actions }],
  ...extra,
});

// 値は直近 3 秒(METER_WINDOW_MS)に増えた数 ÷ 3。窓の前端より古いサンプルが無ければ最古のサンプルを前端に使う
test("初めて見た run はそのときの actions を基準にし、増分だけ数える", () => {
  const t = new ActionTachometer();
  t.apply(ev(500), 0);
  assert.equal(t.snapshot(0).meterPerSecond, 0, "開く前の 500 は数えない");
  t.apply(ev(530), 1 * S);
  assert.equal(t.snapshot(1 * S).meterPerSecond, 10, "30 / 3");
});

test("終わった run(一覧から消えた)の寄与は残り、窓を抜ければ 0 になる(合計は減らない)", () => {
  const t = new ActionTachometer();
  t.apply(ev(0), 0);
  t.apply(ev(30), 1 * S);
  t.apply({ observed: true, runs: [] }, 2 * S);
  assert.equal(t.snapshot(2 * S).meterPerSecond, 10, "消えても寄与は残る");
  t.tick(6 * S);
  assert.equal(t.snapshot(6 * S).meterPerSecond, 0, "増えなければ窓を抜けて 0");
});

test("観測切れで凍結し、再観測では途切れていた間の増分を数えない", () => {
  const t = new ActionTachometer();
  t.apply(ev(0, { machine: "M1" }), 0);
  t.apply(ev(9, { machine: "M1" }), 1 * S);
  t.apply({ machine: "M1", observed: false, runs: [] }, 2 * S);
  assert.deepEqual(t.snapshot(2 * S).unobservedMachines, ["M1"]);
  assert.equal(t.snapshot(2 * S).meterPerSecond, 3, "凍結(9 / 3)");
  t.apply(ev(1000, { machine: "M1" }), 3 * S);
  assert.equal(t.snapshot(3 * S).meterPerSecond, 3, "間の 991 は数えない(基準の取り直し)");
  assert.deepEqual(t.snapshot(3 * S).unobservedMachines, []);
  t.apply(ev(1006, { machine: "M1" }), 4 * S);
  assert.equal(t.snapshot(4 * S).meterPerSecond, 2, "取り直した基準からの 6 だけ(1 秒目の 9 は窓の外)");
});

test("値は直近 3 秒に増えた数だけ(窓の外の分は引く)", () => {
  const t = new ActionTachometer();
  t.apply(ev(0), 0);
  t.apply(ev(30), 1 * S);
  t.apply(ev(36), 10 * S);
  assert.equal(t.snapshot(10 * S).meterPerSecond, 2, "1 秒目の 30 は窓の外 = 6 / 3");
});

test("機械別の内訳は同じ計算で、手元(空文字)が先頭", () => {
  const t = new ActionTachometer();
  t.apply(ev(0), 0);
  t.apply(ev(0, { machine: "M1Max" }), 0);
  t.apply(ev(6), 2 * S);
  t.apply(ev(69, { machine: "M1Max" }), 2 * S);
  const s = t.snapshot(2 * S);
  assert.equal(s.meterPerSecond, 25);
  assert.deepEqual(s.byMachine, [{ machine: "", meterPerSecond: 2 }, { machine: "M1Max", meterPerSecond: 23 }]);
});

test("点灯段数と段の色帯", () => {
  assert.equal(ACTIONS_PER_SECOND_PER_SEGMENT, 1, "1目盛り = 1アクション/秒");
  assert.equal(METER_SEGMENTS, 40);
  assert.equal(litSegments(0), 0);
  assert.equal(litSegments(0.4), 0);
  assert.equal(litSegments(1), 1);
  assert.equal(litSegments(15.3), 15);
  assert.equal(litSegments(40), METER_SEGMENTS);
  assert.equal(litSegments(55), 55, "40段を超えても数える(右へ延ばす)");
  assert.deepEqual([0, 23, 24, 33, 34, 39].map(segmentTier), ["low", "low", "mid", "mid", "high", "high"]);
});

test("メーターは直近 3 秒に増えた数を 3 で割った 1 秒あたり(60 秒窓の数値とは別)", () => {
  assert.equal(METER_WINDOW_MS, 3_000);
  const m = new ActionTachometer();
  const ev = (actions) => ({ observed: true, runs: [{ pid: 1, runID: "r", actions }] });
  m.apply(ev(0), 0);
  m.apply(ev(30), 10_000);
  m.apply(ev(60), 20_000);
  m.apply(ev(72), 21_000);
  // 3 秒前(18s)以前で最新は 10s の 30 → 72 - 30 = 42 / 3 = 14 /秒
  assert.equal(m.snapshot(21_000).meterPerSecond, 14);
  // 増えなければ 3 秒後に 0
  m.tick(30_000);
  assert.equal(m.snapshot(30_000).meterPerSecond, 0);
});

test("バーは目標へ慣性で追いつき、途中の段は割合だけ点く", () => {
  assert.equal(METER_TIME_CONSTANT_MS, 1_000);
  assert.equal(easeToward(0, 10, 0), 0, "時間が進まなければ動かない");
  const one = easeToward(0, 10, 1_000);
  assert.ok(Math.abs(one - 10 * (1 - Math.exp(-1))) < 1e-9, "時定数ぶんで約 63%");
  assert.ok(easeToward(0, 10, 2_000) > 8.6, "2 秒(元の更新の周期)で約 86% 追いつく");
  assert.ok(easeToward(10, 0, 500) < 10 && easeToward(10, 0, 500) > 0, "下がるときも連続的");
  assert.equal(segmentLevel(3.25, 0), 1);
  assert.equal(segmentLevel(3.25, 2), 1);
  assert.equal(segmentLevel(3.25, 3), 0.25, "途中の段は割合");
  assert.equal(segmentLevel(3.25, 4), 0);
});

test("機械別にもメーターと同じ窓の 1 秒あたりが付く", () => {
  const m = new ActionTachometer();
  m.apply({ observed: true, runs: [{ pid: 1, runID: "a", actions: 0 }] }, 0);
  m.apply({ machine: "M1Ultra", observed: true, runs: [{ pid: 2, runID: "b", actions: 0 }] }, 0);
  m.apply({ observed: true, runs: [{ pid: 1, runID: "a", actions: 6 }] }, 10_000);
  m.apply({ machine: "M1Ultra", observed: true, runs: [{ pid: 2, runID: "b", actions: 9 }] }, 10_000);
  const s = m.snapshot(11_000);
  // 3 秒前(8s)以前で最新は 0s の 0 → 手元 6 / 3 = 2・M1Ultra 9 / 3 = 3
  assert.deepEqual(s.byMachine.map((x) => [x.machine, x.meterPerSecond]), [["", 2], ["M1Ultra", 3]]);
  assert.equal(s.meterPerSecond, 5, "合計もバーと同じ窓");
});

test("40段に収まらない値では段を右へ足し、下がれば 40段に戻る", () => {
  assert.equal(segmentCount(0), METER_SEGMENTS);
  assert.equal(segmentCount(39.2), METER_SEGMENTS);
  assert.equal(segmentCount(40), METER_SEGMENTS);
  assert.equal(segmentCount(40.3), 41, "途中の段まで含めて足す");
  assert.equal(segmentCount(57), 57);
  assert.equal(segmentTier(45), "high", "足した段は高の色");
});
