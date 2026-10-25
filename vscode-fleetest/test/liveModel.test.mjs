// liveModel.test.mjs
// liveModel.ts(list-devices の検証、live serve の NDJSON コマンド組み立て/イベント検証、
// 座標変換、要素行フォーマット、CLI引数組み立て、webviewメッセージプロトコル)のユニットテスト。
// node:test で実行する。esbuild が "../src/liveModel"(拡張子なし)を liveModel.ts に解決して
// バンドルする。
//
// 末尾に、test/fixtures/mock-live.mjs を実際に spawn して liveModel の解析関数に通す統合テストと、
// 実バイナリ(.build/debug/fleetest。存在すれば)を使った疎通確認テストを含む
// (profileModel.test.mjs / monitorModel.test.mjs と同じ方針)。

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import path from "node:path";
import { test } from "node:test";
import {
  buildDeviceArgs,
  buildFallbackDevice,
  devicesToOptions,
  fallbackDeviceOption,
  FALLBACK_DEVICE_ID,
  formatElementFrame,
  formatElementLine,
  frameToDisplayRect,
  gestureCapFor,
  gestureStepsFromPoints,
  isGridLiveAction,
  isListDevicesResult,
  parseLiveActionResult,
  parseLiveServeEvent,
  withDslSelector,
  parseLiveSnapshotResult,
  parseListDevicesResult,
  pointFromClick,
  remoteDeviceOption,
  sameLiveDeviceRef,
  serializeLiveServeCommand,
  serveCommandAllowanceMs,
  toSnapshotMessage,
} from "../src/liveModel";

// ---- isListDevicesResult / parseListDevicesResult ----

test("isListDevicesResult: 正常な値(iOS/Android混在)を true と判定する", () => {
  const value = {
    project: "SampleApp",
    devices: [
      { name: "シミュ1", platform: "ios", state: "connected", detail: "port 8127", port: 8127, serial: null, udid: "11111111-2222-3333-4444-555555555555", kind: "virtual" },
      { name: "エミュ1", platform: "android", state: "offline", detail: "", port: null, serial: null, udid: null, kind: "virtual" },
    ],
  };
  assert.equal(isListDevicesResult(value), true);
  assert.deepEqual(parseListDevicesResult(value), value);
});

test("isListDevicesResult: kind の欠落は false(CLI は常に送る)", () => {
  const value = {
    project: "SampleApp",
    devices: [{ name: "シミュ1", platform: "ios", state: "connected", detail: "", port: 8127, serial: null, udid: null }],
  };
  assert.equal(isListDevicesResult(value), false);
});

test("isListDevicesResult: kind=physical(実機)を保持する", () => {
  const value = {
    project: "SampleApp",
    devices: [
      { name: "iPhone 実機", platform: "ios", state: "connected", detail: "port 8140", port: 8140, serial: null, udid: "00008130-001819863E60001C", kind: "physical" },
      { name: "Pixel 実機", platform: "android", state: "connected", detail: "14141JEC204922", port: null, serial: "14141JEC204922", udid: null, kind: "physical" },
    ],
  };
  assert.equal(isListDevicesResult(value), true);
  assert.deepEqual(parseListDevicesResult(value).devices.map((d) => d.kind), ["physical", "physical"]);
});

test("isListDevicesResult: kind が未知の値なら false", () => {
  const value = {
    project: "SampleApp",
    devices: [
      { name: "シミュ1", platform: "ios", state: "connected", detail: "", port: 8127, serial: null, udid: null, kind: "emulator" },
    ],
  };
  assert.equal(isListDevicesResult(value), false);
});

test("isListDevicesResult: 接続済みAndroid(serial あり)も true", () => {
  const value = {
    project: "SampleApp",
    devices: [
      { name: "エミュ1", platform: "android", state: "connected", detail: "接続済み", port: null, serial: "emulator-5554", udid: null, kind: "virtual" },
    ],
  };
  assert.equal(isListDevicesResult(value), true);
});

test("isListDevicesResult: トップレベルのフィールド欠落/型不一致は false", () => {
  assert.equal(isListDevicesResult(null), false);
  assert.equal(isListDevicesResult("not an object"), false);
  assert.equal(isListDevicesResult({}), false);
  assert.equal(isListDevicesResult({ project: "P", devices: [] }), true); // machine は含まない
  assert.equal(isListDevicesResult({ devices: [] }), false); // project 欠落
  assert.equal(isListDevicesResult({ project: "P", devices: "not-array" }), false);
});

test("isListDevicesResult: devices 要素の platform/state が不正なら false", () => {
  const base = { name: "d", detail: "", port: null, serial: null, udid: null };
  assert.equal(
    isListDevicesResult({
      project: "P",
      devices: [{ ...base, platform: "windows", state: "connected" }],
    }),
    false,
  );
  assert.equal(
    isListDevicesResult({
      project: "P",
      devices: [{ ...base, platform: "ios", state: "notBooted" }],
    }),
    false,
    "state の語彙は connected/booted/offline の3値のみ(notBooted は実際の CLI 出力に存在しない)",
  );
});

test("isListDevicesResult: devices 要素の udid が欠落/数値なら false", () => {
  const base = { name: "d", platform: "ios", state: "connected", detail: "", port: null, serial: null };
  assert.equal(
    isListDevicesResult({ project: "P", devices: [base] }),
    false,
    "udid 欠落は不正",
  );
  assert.equal(
    isListDevicesResult({ project: "P", devices: [{ ...base, udid: 12345 }] }),
    false,
    "udid が数値は不正(string | null のみ許容)",
  );
});

test("parseListDevicesResult: 不正値は undefined を返す", () => {
  assert.equal(parseListDevicesResult({ foo: "bar" }), undefined);
});

// ---- parseLiveSnapshotResult ----

test("parseLiveSnapshotResult: 成功形(ok:true)をそのまま返す", () => {
  const value = {
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [
      { ref: 1, type: "Button", label: "ログイン", identifier: null, value: null, frame: { x: 0, y: 0, width: 10, height: 10 } },
    ],
    notes: [],
    bridgeStarting: false,
    capturedAtMs: 1761300000000,
  };
  assert.deepEqual(parseLiveSnapshotResult(value), value);
});

test("parseLiveSnapshotResult: 失敗形(ok:false)をそのまま返す", () => {
  const value = { ok: false, error: "接続できません", bridgeStarting: false };
  assert.deepEqual(parseLiveSnapshotResult(value), value);
});

test("parseLiveSnapshotResult: platform が ios/android 以外なら undefined", () => {
  const value = { ok: true, platform: "windows", screen: { width: 1, height: 1 }, image: "A", elements: [], notes: [], bridgeStarting: false };
  assert.equal(parseLiveSnapshotResult(value), undefined);
});

test("parseLiveSnapshotResult: elements の frame が欠落していれば undefined", () => {
  const value = {
    ok: true,
    platform: "ios",
    screen: { width: 1, height: 1 },
    image: "A",
    elements: [{ ref: 1, type: "Button", label: null, identifier: null, value: null }],
    notes: [],
    bridgeStarting: false,
  };
  assert.equal(parseLiveSnapshotResult(value), undefined);
});

test("parseLiveSnapshotResult: 何にも一致しない値は undefined", () => {
  assert.equal(parseLiveSnapshotResult({ foo: "bar" }), undefined);
  assert.equal(parseLiveSnapshotResult(null), undefined);
});

// ---- isLiveSnapshot: notes の検証(欄の新設。後方互換の読み替えを置かない方針) ----

test("parseLiveSnapshotResult: notes に鮮度警告の本文が入っていれば保持する", () => {
  const value = {
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [],
    notes: ["this screenshot may be stale: the element tree changed since the previous observation"],
    bridgeStarting: false,
    capturedAtMs: 1761300000000,
  };
  assert.deepEqual(parseLiveSnapshotResult(value), value);
});

test("parseLiveSnapshotResult: notes が欠落/null/要素が非文字列なら undefined", () => {
  const base = { ok: true, platform: "ios", screen: { width: 1, height: 1 }, image: "A", elements: [], bridgeStarting: false };
  assert.equal(parseLiveSnapshotResult(base), undefined, "notes 欠落");
  assert.equal(parseLiveSnapshotResult({ ...base, notes: null }), undefined, "notes が null");
  assert.equal(parseLiveSnapshotResult({ ...base, notes: "warning" }), undefined, "notes が配列でない");
  assert.equal(parseLiveSnapshotResult({ ...base, notes: [1] }), undefined, "notes の要素が非文字列");
});

// ---- isLiveSnapshot/isLiveErrorResult/isLiveOkResult: bridgeStarting の検証(欄の新設。
// 後方互換の読み替えを置かない方針) ----

test("parseLiveSnapshotResult: bridgeStarting が欠落/非boolean なら undefined", () => {
  const base = { ok: true, platform: "ios", screen: { width: 1, height: 1 }, image: "A", elements: [], notes: [] };
  assert.equal(parseLiveSnapshotResult(base), undefined, "bridgeStarting 欠落");
  assert.equal(parseLiveSnapshotResult({ ...base, bridgeStarting: "false" }), undefined, "bridgeStarting が文字列");
  assert.equal(parseLiveSnapshotResult({ ok: false, error: "x" }), undefined, "エラー形も bridgeStarting 欠落は undefined");
});

// ---- parseLiveActionResult ----

test("parseLiveActionResult: {ok:true} を { ok: true, bridgeStarting, dsl } に正規化する", () => {
  assert.deepEqual(parseLiveActionResult({ ok: true, bridgeStarting: false, dsl: null, dslSelector: null }), {
    ok: true, bridgeStarting: false, dsl: null, dslSelector: null,
  });
  assert.deepEqual(parseLiveActionResult({ ok: true, bridgeStarting: true, dsl: 'tap("#login")', dslSelector: null }), {
    ok: true, bridgeStarting: true, dsl: 'tap("#login")', dslSelector: null,
  });
});

test("parseLiveActionResult: {ok:false,error} をそのまま返す", () => {
  assert.deepEqual(parseLiveActionResult({ ok: false, error: "失敗しました", bridgeStarting: false, dsl: null, dslSelector: null }), {
    ok: false,
    error: "失敗しました",
    bridgeStarting: false,
    dsl: null, dslSelector: null,
  });
});

test("parseLiveActionResult: 失敗した操作でも dsl(撃つ前に組めた行)を落とさない", () => {
  assert.deepEqual(
    parseLiveActionResult({ ok: false, error: "x", bridgeStarting: false, dsl: "tap(x: 120, y: 340)", dslSelector: null }),
    { ok: false, error: "x", bridgeStarting: false, dsl: "tap(x: 120, y: 340)", dslSelector: null },
  );
});

test("parseLiveActionResult: dslSelector も必須(欠落・文字列でも null でもない値は undefined)・在れば落とさない", () => {
  assert.equal(parseLiveActionResult({ ok: true, bridgeStarting: false, dsl: null }), undefined, "dslSelector 欠落");
  assert.equal(parseLiveActionResult({ ok: true, bridgeStarting: false, dsl: null, dslSelector: 1 }), undefined, "数値");
  assert.equal(
    parseLiveActionResult({ ok: true, bridgeStarting: false, dsl: 'tap("#login")', dslSelector: "#login" })?.dslSelector,
    "#login");
});

test("withDslSelector: 操作の列にセレクタを添える。ラベルに同じ文字列があれば重ねない・無ければそのまま", () => {
  assert.equal(withDslSelector("タップ: Apple マップ", "#MapsSearchTextField"), 'タップ: Apple マップ("#MapsSearchTextField")');
  assert.equal(withDslSelector("ダブルタップ: #ChromeViewController.Viewport", "#ChromeViewController.Viewport"),
    "ダブルタップ: #ChromeViewController.Viewport");
  assert.equal(withDslSelector("タップ: (120, 340)", null), "タップ: (120, 340)");
  // 部分一致で「書かれている」と読まない(別の id の前方一致)
  assert.equal(withDslSelector("タップ: #okButton", "#ok"), 'タップ: #okButton("#ok")');
  // 要素名の末尾だけが一致しても同じと読まない
  assert.equal(withDslSelector("タップ: Not OK", "OK"), 'タップ: Not OK("OK")');
  assert.equal(withDslSelector("入力: abc", undefined), "入力: abc");
  // セレクタの中の引用符はそのまま貼れる形(JSON の文字列)で出す
  assert.equal(withDslSelector("タップ: OK", '"OK"'), 'タップ: OK("\\"OK\\"")');
});

test("parseLiveActionResult: dsl は必須(欠落・文字列でも null でもない値は undefined。後方互換の読み替えは置かない)", () => {
  assert.equal(parseLiveActionResult({ ok: true, bridgeStarting: false }), undefined, "dsl 欠落");
  assert.equal(parseLiveActionResult({ ok: false, error: "x", bridgeStarting: false }), undefined, "エラー形も dsl 欠落は undefined");
  assert.equal(parseLiveActionResult({ ok: true, bridgeStarting: false, dsl: 12 }), undefined, "dsl が数値");
  assert.equal(parseLiveActionResult({ ok: true, bridgeStarting: false, dsl: undefined }), undefined, "dsl が undefined");
});

test("parseLiveActionResult: ok が欠落/非boolean、error が非文字列、または bridgeStarting が欠落/非boolean なら undefined", () => {
  assert.equal(parseLiveActionResult({ dsl: null, dslSelector: null }), undefined);
  assert.equal(parseLiveActionResult({ ok: "true", dsl: null, dslSelector: null }), undefined);
  assert.equal(parseLiveActionResult({ ok: false, dsl: null, dslSelector: null }), undefined);
  assert.equal(parseLiveActionResult({ ok: false, error: 123, dsl: null, dslSelector: null }), undefined);
  assert.equal(parseLiveActionResult(null), undefined);
  assert.equal(parseLiveActionResult({ ok: true, dsl: null, dslSelector: null }), undefined, "bridgeStarting 欠落");
  assert.equal(parseLiveActionResult({ ok: true, bridgeStarting: "false", dsl: null, dslSelector: null }), undefined, "bridgeStarting が文字列");
  assert.equal(parseLiveActionResult({ ok: false, error: "x", dsl: null, dslSelector: null }), undefined, "エラー形も bridgeStarting 欠落は undefined");
});

// ---- serializeLiveServeCommand ----

test("serializeLiveServeCommand: JSON化して末尾に改行を付ける", () => {
  assert.equal(serializeLiveServeCommand({ cmd: "refresh" }), '{"cmd":"refresh"}\n');
  assert.equal(serializeLiveServeCommand({ cmd: "tap", ref: 3 }), '{"cmd":"tap","ref":3}\n');
  assert.equal(
    serializeLiveServeCommand({ cmd: "doubleTap", x: 10, y: 20 }),
    '{"cmd":"doubleTap","x":10,"y":20}\n',
  );
  assert.equal(
    serializeLiveServeCommand({ cmd: "pinch", scale: 2, duration: 0.5 }),
    '{"cmd":"pinch","scale":2,"duration":0.5}\n',
  );
  assert.equal(
    serializeLiveServeCommand({ cmd: "tap", x: 1.5, y: 2.5 }),
    '{"cmd":"tap","x":1.5,"y":2.5}\n',
  );
  assert.equal(
    serializeLiveServeCommand({ cmd: "type", text: "hello" }),
    '{"cmd":"type","text":"hello"}\n',
  );
  assert.equal(serializeLiveServeCommand({ cmd: "home" }), '{"cmd":"home"}\n');
  assert.equal(serializeLiveServeCommand({ cmd: "fold", state: "fold" }), '{"cmd":"fold","state":"fold"}\n');
});

// ---- parseLiveServeEvent ----

test("parseLiveServeEvent: kind=actionResult の成功/失敗を判別する", () => {
  assert.deepEqual(parseLiveServeEvent({ kind: "actionResult", ok: true, bridgeStarting: false, dsl: null, dslSelector: null }), {
    kind: "actionResult",
    result: { ok: true, bridgeStarting: false, dsl: null, dslSelector: null },
  });
  assert.deepEqual(
    parseLiveServeEvent({ kind: "actionResult", ok: false, error: "失敗しました", bridgeStarting: false, dsl: null, dslSelector: null }),
    {
      kind: "actionResult",
      result: { ok: false, error: "失敗しました", bridgeStarting: false, dsl: null, dslSelector: null },
    },
  );
});

test("parseLiveServeEvent: actionResult の bridgeStarting(自動起動が進行中か)を落とさない", () => {
  assert.deepEqual(parseLiveServeEvent({ kind: "actionResult", ok: false, error: "x", bridgeStarting: true, dsl: null, dslSelector: null }), {
    kind: "actionResult",
    result: { ok: false, error: "x", bridgeStarting: true, dsl: null, dslSelector: null },
  });
});

test("parseLiveServeEvent: actionResult の dsl(操作記録に出す DSL の1行)を落とさない・欠落は不正", () => {
  assert.deepEqual(
    parseLiveServeEvent({ kind: "actionResult", ok: true, bridgeStarting: false, dsl: 'tap("#login")', dslSelector: null }),
    { kind: "actionResult", result: { ok: true, bridgeStarting: false, dsl: 'tap("#login")', dslSelector: null } },
  );
  assert.equal(parseLiveServeEvent({ kind: "actionResult", ok: true, bridgeStarting: false }), undefined, "dsl 欠落");
});

test("parseLiveServeEvent: actionResult の app(操作を撃った先)を落とさない", () => {
  assert.deepEqual(
    parseLiveServeEvent({ kind: "actionResult", ok: true, app: "com.example.app", bridgeStarting: false, dsl: null, dslSelector: null }),
    {
      kind: "actionResult",
      result: { ok: true, bridgeStarting: false, dsl: null, dslSelector: null, app: "com.example.app" },
    },
  );
  assert.deepEqual(
    parseLiveServeEvent({
      kind: "actionResult", ok: false, error: "x", app: "com.apple.springboard", bridgeStarting: false, dsl: null, dslSelector: null,
    }),
    {
      kind: "actionResult",
      result: { ok: false, error: "x", bridgeStarting: false, dsl: null, dslSelector: null, app: "com.apple.springboard" },
    },
  );
  // app が文字列でない/無い形では欄自体を作らない(undefined の欄で deepEqual を割らない)
  assert.deepEqual(parseLiveServeEvent({ kind: "actionResult", ok: true, app: 12, bridgeStarting: false, dsl: null, dslSelector: null }), {
    kind: "actionResult",
    result: { ok: true, bridgeStarting: false, dsl: null, dslSelector: null },
  });
});

test("parseLiveServeEvent: kind=snapshot の成功/失敗を判別する", () => {
  const success = {
    kind: "snapshot",
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [],
    notes: [],
    bridgeStarting: false,
    capturedAtMs: 1761300000000,
  };
  assert.deepEqual(parseLiveServeEvent(success), {
    kind: "snapshot",
    result: {
      ok: true, platform: "ios", screen: { width: 402, height: 874 }, image: "AAAA", elements: [], notes: [],
      bridgeStarting: false, capturedAtMs: 1761300000000,
    },
  });
  assert.deepEqual(
    parseLiveServeEvent({ kind: "snapshot", ok: false, error: "接続できません", bridgeStarting: false }),
    {
      kind: "snapshot",
      result: { ok: false, error: "接続できません", bridgeStarting: false },
    },
  );
});

test("parseLiveServeEvent: kind=snapshot の bridgeStarting(自動起動が進行中か)を落とさない", () => {
  assert.deepEqual(
    parseLiveServeEvent({ kind: "snapshot", ok: false, error: "接続できません", bridgeStarting: true }),
    {
      kind: "snapshot",
      result: { ok: false, error: "接続できません", bridgeStarting: true },
    },
  );
});

test("parseLiveServeEvent: kind=snapshot は notes(鮮度警告)を落とさない", () => {
  const withNote = {
    kind: "snapshot",
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [],
    notes: ["this screenshot may be stale: the element tree changed since the previous observation"],
    bridgeStarting: false,
    capturedAtMs: 1761300000000,
  };
  assert.deepEqual(parseLiveServeEvent(withNote), {
    kind: "snapshot",
    result: {
      ok: true,
      platform: "ios",
      screen: { width: 402, height: 874 },
      image: "AAAA",
      elements: [],
      notes: ["this screenshot may be stale: the element tree changed since the previous observation"],
      bridgeStarting: false,
      capturedAtMs: 1761300000000,
    },
  });
});

test("parseLiveServeEvent: kind=snapshot は notes 欠落なら undefined(後方互換の読み替えを置かない)", () => {
  assert.equal(
    parseLiveServeEvent({
      kind: "snapshot",
      ok: true,
      platform: "ios",
      screen: { width: 402, height: 874 },
      image: "AAAA",
      elements: [],
      bridgeStarting: false,
    }),
    undefined,
  );
});

test("parseLiveServeEvent: kind=snapshot は capturedAtMs(撮影の時刻)欠落なら undefined(後方互換の読み替えを置かない)", () => {
  assert.equal(
    parseLiveServeEvent({
      kind: "snapshot", ok: true, platform: "ios", screen: { width: 402, height: 874 }, image: "AAAA",
      elements: [], notes: [], bridgeStarting: false,
    }),
    undefined,
  );
});

test("parseLiveServeEvent: kind=snapshot は bridgeStarting 欠落なら undefined(後方互換の読み替えを置かない)", () => {
  assert.equal(
    parseLiveServeEvent({
      kind: "snapshot",
      ok: true,
      platform: "ios",
      screen: { width: 402, height: 874 },
      image: "AAAA",
      elements: [],
      notes: [],
    }),
    undefined,
  );
});

test("parseLiveServeEvent: kind が無い/未知、または中身が不正なら undefined", () => {
  assert.equal(parseLiveServeEvent(null), undefined);
  assert.equal(parseLiveServeEvent({}), undefined);
  assert.equal(parseLiveServeEvent({ kind: "unknown", ok: true }), undefined);
  assert.equal(parseLiveServeEvent({ kind: "actionResult" }), undefined, "ok 欠落は actionResult として不正");
  assert.equal(
    parseLiveServeEvent({ kind: "snapshot", ok: true, platform: "windows" }),
    undefined,
    "platform 不正は snapshot として不正",
  );
});

// ---- sameLiveDeviceRef ----

test("sameLiveDeviceRef: platform/port/serial/udid が全て一致すれば true", () => {
  assert.equal(
    sameLiveDeviceRef(
      { platform: "ios", port: 8127, serial: null, udid: "AAAA" },
      { platform: "ios", port: 8127, serial: null, udid: "AAAA" },
    ),
    true,
  );
  assert.equal(
    sameLiveDeviceRef(
      { platform: "android", port: null, serial: "emulator-5554", udid: null },
      { platform: "android", port: null, serial: "emulator-5554", udid: null },
    ),
    true,
  );
});

test("sameLiveDeviceRef: platform/port/serial/udid のいずれかが異なれば false", () => {
  assert.equal(
    sameLiveDeviceRef(
      { platform: "ios", port: 8127, serial: null, udid: null },
      { platform: "android", port: 8127, serial: null, udid: null },
    ),
    false,
  );
  assert.equal(
    sameLiveDeviceRef(
      { platform: "ios", port: 8127, serial: null, udid: null },
      { platform: "ios", port: 8128, serial: null, udid: null },
    ),
    false,
  );
  assert.equal(
    sameLiveDeviceRef(
      { platform: "android", port: null, serial: "emulator-5554", udid: null },
      { platform: "android", port: null, serial: "emulator-5556", udid: null },
    ),
    false,
  );
  assert.equal(
    sameLiveDeviceRef(
      { platform: "ios", port: 8127, serial: null, udid: "AAAA" },
      { platform: "ios", port: 8127, serial: null, udid: "BBBB" },
    ),
    false,
    "udid のみが異なる場合も false(自動起動の再バインド判定に必要)",
  );
});

// ---- pointFromClick ----

test("pointFromClick: 表示pxの中央クリックはスクリーン中央のポイント座標になる", () => {
  const point = pointFromClick({ x: 201, y: 437 }, { width: 402, height: 874 }, { width: 402, height: 874 });
  assert.equal(point.x, 201);
  assert.equal(point.y, 437);
});

test("pointFromClick: 表示サイズがスクリーンより小さい場合も比例変換する", () => {
  // 表示200x434(実機の半分程度)でクリック(100,217) = 表示の中央 → スクリーン中央(201,437)相当
  const point = pointFromClick({ x: 100, y: 217 }, { width: 200, height: 434 }, { width: 402, height: 874 });
  assert.ok(Math.abs(point.x - 201) < 1);
  assert.ok(Math.abs(point.y - 437) < 1);
});

test("pointFromClick: 変換結果はスクリーン範囲にクランプする", () => {
  const point = pointFromClick({ x: 500, y: -10 }, { width: 402, height: 874 }, { width: 402, height: 874 });
  assert.equal(point.x, 402);
  assert.equal(point.y, 0);
});

test("pointFromClick: 表示サイズ/スクリーンサイズが0以下なら (0, 0) を返す", () => {
  assert.deepEqual(pointFromClick({ x: 10, y: 10 }, { width: 0, height: 100 }, { width: 100, height: 100 }), {
    x: 0,
    y: 0,
  });
  assert.deepEqual(pointFromClick({ x: 10, y: 10 }, { width: 100, height: 100 }, { width: 100, height: 0 }), {
    x: 0,
    y: 0,
  });
});

// ---- frameToDisplayRect ----

test("frameToDisplayRect: 表示サイズ=スクリーンサイズなら frame をそのまま返す", () => {
  const rect = frameToDisplayRect({ x: 20, y: 780, width: 362, height: 48 }, { width: 402, height: 874 }, { width: 402, height: 874 });
  assert.deepEqual(rect, { x: 20, y: 780, width: 362, height: 48 });
});

test("frameToDisplayRect: 表示サイズが半分ならスケールも半分になる", () => {
  const rect = frameToDisplayRect({ x: 20, y: 780, width: 362, height: 48 }, { width: 402, height: 874 }, { width: 201, height: 437 });
  assert.equal(rect.x, 10);
  assert.equal(rect.y, 390);
  assert.equal(rect.width, 181);
  assert.equal(rect.height, 24);
});

test("frameToDisplayRect: スクリーンサイズが0以下なら全て0の矩形を返す", () => {
  const rect = frameToDisplayRect({ x: 1, y: 1, width: 1, height: 1 }, { width: 0, height: 0 }, { width: 100, height: 100 });
  assert.deepEqual(rect, { x: 0, y: 0, width: 0, height: 0 });
});

// ---- formatElementLine ----

test("formatElementLine: label/identifier/value が全て揃っている場合", () => {
  const line = formatElementLine({
    ref: 3,
    type: "TextField",
    label: "ユーザー名",
    identifier: "username_field",
    value: "wave1008",
    frame: { x: 16, y: 120, width: 370, height: 44 },
  });
  // 矩形は別カラム(formatElementFrame)なので本文には含めない
  assert.equal(line, '[3] TextField "ユーザー名" id=username_field =wave1008');
});

test("formatElementLine: null/空文字のフィールドは省く", () => {
  const line = formatElementLine({
    ref: 1,
    type: "Button",
    label: "ログイン",
    identifier: null,
    value: "",
    frame: { x: 20, y: 780, width: 362, height: 48 },
  });
  assert.equal(line, '[1] Button "ログイン"');
});

test("formatElementLine: label/identifier/value 全て無ければ [ref] type だけ", () => {
  const line = formatElementLine({
    ref: 5,
    type: "Image",
    label: null,
    identifier: null,
    value: null,
    frame: { x: 0, y: 0, width: 402, height: 874 },
  });
  assert.equal(line, "[5] Image");
});

// ---- formatElementFrame ----

test("formatElementFrame: ft_snapshot と同じ (x,y WxH)", () => {
  assert.equal(formatElementFrame({ x: 20, y: 780, width: 362, height: 48 }), "(20,780 362x48)");
  assert.equal(formatElementFrame({ x: 0, y: 0, width: 402, height: 874 }), "(0,0 402x874)");
});

// Swift 側(SnapshotRendering.swift の Int(_:))と同じ切り捨て。負の座標(画面外へはみ出した
// 要素)も 0 方向へ切る
test("formatElementFrame: 小数は切り捨てる(負値も 0 方向へ)", () => {
  assert.equal(formatElementFrame({ x: -8.7, y: 100.9, width: 393.5, height: 640.2 }), "(-8,100 393x640)");
});

// NaN/Infinity(壊れた木)でも "NaNxNaN" のような行を出さない
test("formatElementFrame: 非有限値は 0 に倒す", () => {
  assert.equal(formatElementFrame({ x: Number.NaN, y: 0, width: Number.POSITIVE_INFINITY, height: 10 }), "(0,0 0x10)");
});

// ---- buildDeviceArgs ----

test("buildDeviceArgs: iOS + port あり", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "ios", port: 8127, serial: null }), [
    "--platform",
    "ios",
    "--port",
    "8127",
  ]);
});

test("buildDeviceArgs: iOS + port 無し(null/0以下)は --port を付けない", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "ios", port: null, serial: null }), ["--platform", "ios"]);
  assert.deepEqual(buildDeviceArgs({ platform: "ios", port: 0, serial: null }), ["--platform", "ios"]);
});

test("buildDeviceArgs: Android + serial あり", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "android", port: null, serial: "emulator-5554" }), [
    "--platform",
    "android",
    "--serial",
    "emulator-5554",
  ]);
});

test("buildDeviceArgs: Android + serial 無し(null/空文字)は --serial を付けない", () => {
  assert.deepEqual(buildDeviceArgs({ platform: "android", port: null, serial: null }), ["--platform", "android"]);
  assert.deepEqual(buildDeviceArgs({ platform: "android", port: null, serial: "  " }), ["--platform", "android"]);
});

// ---- buildFallbackDevice / fallbackDeviceOption ----

test("buildFallbackDevice: port=0/serial=\"\" は未指定(null)として扱う", () => {
  assert.deepEqual(buildFallbackDevice({ platform: "ios", port: 0, serial: "" }), {
    platform: "ios",
    port: null,
    serial: null,
    udid: null,
  });
});

test("buildFallbackDevice: port>0/serial非空はそのまま(trim済み)使う", () => {
  assert.deepEqual(buildFallbackDevice({ platform: "android", port: 0, serial: "  emulator-5554  " }), {
    platform: "android",
    port: null,
    serial: "emulator-5554",
    udid: null,
  });
});

test("fallbackDeviceOption: id=FALLBACK_DEVICE_ID・state=unknown で組み立てる", () => {
  const option = fallbackDeviceOption({ platform: "ios", port: 8100, serial: "" });
  assert.equal(option.id, FALLBACK_DEVICE_ID);
  assert.equal(option.name, "設定のデバイス");
  assert.equal(option.platform, "ios");
  assert.equal(option.state, "unknown");
  assert.equal(option.port, 8100);
  assert.equal(option.serial, null);
  assert.equal(option.udid, null, "フォールバックデバイスは udid を解決できないため常に null");
  assert.equal(option.kind, "virtual", "実体が分からないので従来どおり virtual(配信を試す側)");
});

// ---- devicesToOptions ----

test("devicesToOptions: platform:name の id を付けて変換する", () => {
  const options = devicesToOptions([
    { name: "シミュ1", platform: "ios", state: "connected", detail: "port 8127", port: 8127, serial: null, udid: "AAAA" },
    { name: "エミュ1", platform: "android", state: "offline", detail: "", port: null, serial: null, udid: null },
  ]);
  assert.equal(options.length, 2);
  assert.equal(options[0].id, "ios:シミュ1");
  assert.equal(options[0].state, "connected");
  assert.equal(options[0].udid, "AAAA");
  assert.equal(options[1].id, "android:エミュ1");
  assert.equal(options[1].state, "offline");
  assert.equal(options[1].udid, null);
});

// 映像の供給元の選択(iOS 実機は simstream を使わない)が kind を見るので、落とさず運ぶこと
test("devicesToOptions: kind をそのまま運ぶ", () => {
  const options = devicesToOptions([
    { name: "実機", platform: "ios", state: "booted", detail: "", port: null, serial: null, udid: "00008130-001819863E60001C", kind: "physical" },
    { name: "シミュ", platform: "ios", state: "connected", detail: "", port: 8127, serial: null, udid: "AAAA", kind: "virtual" },
  ]);
  assert.deepEqual(options.map((o) => o.kind), ["physical", "virtual"]);
});

// ---- toSnapshotMessage ----

test("toSnapshotMessage: elements に formatElementLine と同じ line フィールドを付与する", () => {
  const snapshot = {
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [
      {
        ref: 1,
        type: "Button",
        label: "ログイン",
        identifier: "login_button",
        value: null,
        frame: { x: 20, y: 780, width: 362, height: 48 },
      },
    ],
    notes: [],
    bridgeStarting: false,
  };
  const message = toSnapshotMessage(snapshot);
  assert.equal(message.type, "snapshot");
  assert.equal(message.platform, "ios");
  assert.deepEqual(message.screen, { width: 402, height: 874 });
  assert.equal(message.image, "AAAA");
  assert.equal(message.elements.length, 1);
  assert.equal(message.elements[0].line, formatElementLine(snapshot.elements[0]));
  assert.equal(message.elements[0].line, '[1] Button "ログイン" id=login_button');
  assert.equal(message.elements[0].frameText, "(20,780 362x48)");
  // 元の frame 情報も保持していること(ホバー枠オーバーレイに必要)
  assert.deepEqual(message.elements[0].frame, { x: 20, y: 780, width: 362, height: 48 });
  assert.deepEqual(message.notes, []);
});

test("toSnapshotMessage: notes(鮮度警告)をそのまま webview メッセージへ運ぶ", () => {
  const snapshot = {
    ok: true,
    platform: "ios",
    screen: { width: 402, height: 874 },
    image: "AAAA",
    elements: [],
    notes: ["this screenshot may be stale: the element tree changed since the previous observation"],
    bridgeStarting: false,
  };
  const message = toSnapshotMessage(snapshot);
  assert.deepEqual(message.notes, [
    "this screenshot may be stale: the element tree changed since the previous observation",
  ]);
});

// ---- isGridLiveAction ----

test("isGridLiveAction: 各メッセージ種別の正常な値を true と判定する", () => {
  assert.equal(isGridLiveAction({ type: "refreshSnapshot" }), true);
  assert.equal(
    isGridLiveAction({ type: "tapPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }),
    true,
  );
  assert.equal(
    isGridLiveAction({
      type: "pressPoint",
      clickX: 1,
      clickY: 2,
      displayWidth: 3,
      displayHeight: 4,
      holdMs: 500,
    }),
    true,
  );
  assert.equal(
    isGridLiveAction({
      type: "dragPoints",
      fromX: 1,
      fromY: 2,
      toX: 3,
      toY: 4,
      displayWidth: 5,
      displayHeight: 6,
      pressMs: 50,
      dragMs: 200,
    }),
    true,
  );
  assert.equal(isGridLiveAction({ type: "typeText", text: "hello", ref: null }), true);
  assert.equal(isGridLiveAction({ type: "typeText", text: "hello", ref: 2 }), true);
  assert.equal(
    isGridLiveAction({
      type: "doubleTapPoint",
      clickX: 1,
      clickY: 2,
      displayWidth: 3,
      displayHeight: 4,
    }),
    true,
  );
  assert.equal(isGridLiveAction({ type: "pinch", zoomIn: true }), true);
  assert.equal(isGridLiveAction({ type: "appSwitcher" }), true);
  assert.equal(isGridLiveAction({ type: "home" }), true);
});

test("isGridLiveAction: 未知の type・型不一致・フィールド欠落は false", () => {
  assert.equal(isGridLiveAction(null), false);
  assert.equal(isGridLiveAction("refreshDevices"), false);
  assert.equal(isGridLiveAction({}), false);
  assert.equal(isGridLiveAction({ type: "unknown" }), false);
  assert.equal(isGridLiveAction({ type: "selectDevice" }), false);
  assert.equal(isGridLiveAction({ type: "openDevice" }), false);
  assert.equal(
    isGridLiveAction({ type: "dragPoints", fromX: 1, fromY: 2, toX: 3, displayWidth: 5, displayHeight: 6 }),
    false,
    "toY 欠落は不正",
  );
  assert.equal(
    isGridLiveAction({
      type: "dragPoints",
      fromX: 1,
      fromY: 2,
      toX: 3,
      toY: 4,
      displayWidth: 5,
      displayHeight: 6,
      pressMs: 50,
    }),
    false,
    "dragMs 欠落は不正",
  );
  assert.equal(
    isGridLiveAction({ type: "pressPoint", clickX: 1, clickY: 2, displayWidth: 3, displayHeight: 4 }),
    false,
    "holdMs 欠落は不正",
  );
  assert.equal(
    isGridLiveAction({ type: "doubleTapPoint", clickX: 1, clickY: 2, displayWidth: 3 }),
    false,
    "displayHeight 欠落は不正",
  );
  assert.equal(isGridLiveAction({ type: "pinch" }), false, "zoomIn 欠落は不正");
  assert.equal(isGridLiveAction({ type: "pinch", zoomIn: "yes" }), false);
  assert.equal(isGridLiveAction({ type: "typeText", text: 1, ref: null }), false);
  assert.equal(isGridLiveAction({ type: "visibility" }), false);
});

// ---- 統合: mock-live.mjs を実際に spawn して liveModel の解析関数に通す ----

const MOCK_LIVE = path.resolve(process.cwd(), "test", "fixtures", "mock-live.mjs");

/** mock-live.mjs list-devices をワンショット spawn し、monitorLiveController.ts の runOneShot() 相当の挙動
 * (stdout 全体を JSON.parse)を再現して { json, exitCode } を返す。 */
function runMockListDevices(args) {
  return new Promise((resolve, reject) => {
    const proc = spawn(process.execPath, [MOCK_LIVE, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    const chunks = [];
    proc.stdout.on("data", (chunk) => chunks.push(chunk));
    proc.on("error", reject);
    proc.on("close", (exitCode) => {
      const text = Buffer.concat(chunks).toString("utf8").trim();
      let json;
      if (text.length > 0) {
        try {
          json = JSON.parse(text);
        } catch {
          json = undefined;
        }
      }
      resolve({ json, exitCode });
    });
  });
}

/**
 * mock-live.mjs live serve(または実バイナリの `api live serve`)を常駐 spawn し、
 * monitorLiveController.ts の sendServeCommand() 相当の挙動(コマンド送信 → NDJSON 行を指定数だけ読む)を
 * 再現するテストダブル。send() は生の JSON.parse 値の配列を返す(parseLiveServeEvent への
 * 通し方はテスト側に委ねる)。close() は stdin を閉じてプロセスの終了(exitCode)を待つ。
 */
function spawnServe(binaryPath, args, cwd) {
  const proc = spawn(binaryPath, args, { cwd, stdio: ["pipe", "pipe", "pipe"] });
  const rl = createInterface({ input: proc.stdout, terminal: false });
  const lineQueue = [];
  const waiters = [];
  rl.on("line", (line) => {
    let value;
    try {
      value = JSON.parse(line);
    } catch {
      return;
    }
    const waiter = waiters.shift();
    if (waiter) {
      waiter(value);
    } else {
      lineQueue.push(value);
    }
  });

  function nextLine() {
    const queued = lineQueue.shift();
    if (queued !== undefined) {
      return Promise.resolve(queued);
    }
    return new Promise((resolve) => waiters.push(resolve));
  }

  return {
    async send(command, expectLines) {
      proc.stdin.write(`${JSON.stringify(command)}\n`);
      const lines = [];
      for (let i = 0; i < expectLines; i += 1) {
        lines.push(await nextLine());
      }
      return lines;
    },
    close() {
      return new Promise((resolve) => {
        proc.once("close", (exitCode) => resolve(exitCode));
        proc.stdin.end();
      });
    },
  };
}

test("統合: mock-live.mjs list-devices の成功出力を parseListDevicesResult に通せる", async () => {
  const { json, exitCode } = await runMockListDevices(["list-devices", "--project", "SampleApp"]);
  assert.equal(exitCode, 0);
  const parsed = parseListDevicesResult(json);
  assert.ok(parsed, "解析できること");
  assert.equal(parsed.project, "SampleApp");
  assert.equal(parsed.devices.length, 2);
  assert.equal(parsed.devices[0].state, "connected");
  assert.equal(parsed.devices[1].state, "offline");
});

test("統合: mock-live.mjs list-devices --project NoMachine は非0終了・stdout無しで parseListDevicesResult が undefined を返す", async () => {
  const { json, exitCode } = await runMockListDevices(["list-devices", "--project", "NoMachine"]);
  assert.equal(exitCode, 1);
  assert.equal(json, undefined);
  assert.equal(parseListDevicesResult(json), undefined);
});

test("統合: mock-live.mjs live serve の refresh は snapshot イベント1行だけを返す", async () => {
  const serve = spawnServe(process.execPath, [MOCK_LIVE, "live", "serve", "--platform", "ios"], process.cwd());
  const [line] = await serve.send({ cmd: "refresh" }, 1);
  const event = parseLiveServeEvent(line);
  assert.ok(event && event.kind === "snapshot" && event.result.ok, "snapshot が成功として解析できること");
  assert.equal(event.result.screen.width, 402);
  assert.equal(event.result.elements.length, 2);
  const message = toSnapshotMessage(event.result);
  assert.equal(message.elements[0].line, '[1] Button "ログイン" id=login_button');
  assert.equal(message.elements[0].frameText, "(20,780 362x48)");
  const exitCode = await serve.close();
  assert.equal(exitCode, 0, "stdin EOF でクリーンに終了すること");
});

test("統合: mock-live.mjs live serve の tap は actionResult(ok:true) → snapshot の2行を返す", async () => {
  const serve = spawnServe(process.execPath, [MOCK_LIVE, "live", "serve", "--platform", "ios"], process.cwd());
  const [actionLine, snapshotLine] = await serve.send({ cmd: "tap", ref: 1 }, 2);
  const actionEvent = parseLiveServeEvent(actionLine);
  assert.deepEqual(actionEvent, { kind: "actionResult", result: { ok: true, bridgeStarting: false, dsl: 'tap("#mock")', dslSelector: "#mock" } });
  const snapshotEvent = parseLiveServeEvent(snapshotLine);
  assert.ok(snapshotEvent && snapshotEvent.kind === "snapshot" && snapshotEvent.result.ok);
  await serve.close();
});

test("統合: mock-live.mjs live serve の tap --ref 999 は actionResult(ok:false) を返す", async () => {
  const serve = spawnServe(process.execPath, [MOCK_LIVE, "live", "serve", "--platform", "ios"], process.cwd());
  const [actionLine] = await serve.send({ cmd: "tap", ref: 999 }, 1);
  const actionEvent = parseLiveServeEvent(actionLine);
  assert.ok(actionEvent && actionEvent.kind === "actionResult" && actionEvent.result.ok === false);
  assert.ok(actionEvent.result.error.includes("tap"));
  await serve.close();
});

test("統合: mock-live.mjs live serve --fail-all は snapshot も ok:false を返す(常駐プロセスの継続的な異常を再現)", async () => {
  const serve = spawnServe(
    process.execPath,
    [MOCK_LIVE, "live", "serve", "--platform", "ios", "--fail-all"],
    process.cwd(),
  );
  const [line] = await serve.send({ cmd: "refresh" }, 1);
  const event = parseLiveServeEvent(line);
  assert.ok(event && event.kind === "snapshot" && event.result.ok === false);
  await serve.close();
});

// ---- 実バイナリ(存在すれば): api live serve ----

// npm test は vscode-fleetest/ を cwd として実行される(package.json の "test" スクリプト)ので、
// リポジトリルート(Package.swift のあるフォルダ)はその1つ上(profileModel.test.mjs と同じ)。
const REPO_ROOT = path.resolve(process.cwd(), "..");
const BINARY_PATH = path.join(REPO_ROOT, ".build", "debug", "fleetest");
const BINARY_EXISTS = existsSync(BINARY_PATH);

test(
  "実バイナリ(存在すれば): `fleetest api live serve --platform ios --port 9999` はデバイス無しでも refresh に ok:false で応答し、stdin EOF でクリーンに終了する",
  { skip: !BINARY_EXISTS && "実バイナリ(.build/debug/fleetest)が見つからないため skip します" },
  async () => {
    const serve = spawnServe(
      BINARY_PATH,
      ["api", "live", "serve", "--platform", "ios", "--port", "9999"],
      REPO_ROOT,
    );
    const [line] = await serve.send({ cmd: "refresh" }, 1);
    const event = parseLiveServeEvent(line);
    assert.ok(
      event && event.kind === "snapshot" && event.result.ok === false,
      `ok:false の snapshot として解析できること: ${JSON.stringify(line)}`,
    );
    assert.ok(event.result.error.length > 0);

    const exitCode = await serve.close();
    assert.equal(exitCode, 0, "接続失敗しても常駐は継続し、stdin EOF でクリーンに(exit 0 で)終了すること");
  },
);

// ---- 他の機械のデバイス(remoteDeviceOption / sameLiveDeviceRef の machine) ----

test("remoteDeviceOption: タイル id と machine を保ち、port は渡さない(向こうの serve が udid で探す)", () => {
  const option = remoteDeviceOption({
    id: "ios:M1Ultra/iPhone wave", name: "iPhone wave", platform: "ios", state: "connected",
    udid: "00008130-001819863E60001C", serial: null, kind: "physical", machine: "M1Ultra",
  });
  assert.equal(option.id, "ios:M1Ultra/iPhone wave");
  assert.equal(option.machine, "M1Ultra");
  assert.equal(option.port, null);
  assert.equal(option.udid, "00008130-001819863E60001C");
});

test("sameLiveDeviceRef: 同じ udid でも機械が違えば別の台(serve を張り替える)", () => {
  const base = { platform: "ios", port: null, serial: null, udid: "U" };
  assert.equal(sameLiveDeviceRef(base, { ...base }), true);
  assert.equal(sameLiveDeviceRef(base, { ...base, machine: "M1Ultra" }), false);
  assert.equal(sameLiveDeviceRef({ ...base, machine: "M1Ultra" }, { ...base, machine: "M1Ultra" }), true);
});

// ---- 軌跡モード(gesture) ----
// ワイヤ形(GestureRequest)は t が秒。gestureStepsFromPoints = 点列→move/hold の列
// (serve 側の同等品は TouchGesture.fingers(fromPoints:))。

test("gestureStepsFromPoints: 同座標が続く区間は hold、動けば move", () => {
  // t は2進で誤差なく表現できる値を選ぶ(0.3-0.9 のような値は浮動小数点誤差(0.6000...1)が
  // 出て本題と関係のない失敗になる)
  const points = [
    { x: 10, y: 20, t: 0 },
    { x: 10, y: 20, t: 0.25 },
    { x: 50, y: 80, t: 1 },
  ];
  assert.deepEqual(gestureStepsFromPoints(points), [
    { kind: "hold", seconds: 0.25 },
    { kind: "move", x: 50, y: 80, seconds: 0.75 },
  ]);
});

test("gestureStepsFromPoints: 時刻が巻き戻る/止まっている点(dt<=0)は畳む(ステップを作らない)", () => {
  const points = [
    { x: 10, y: 20, t: 0 },
    { x: 10, y: 20, t: 0 }, // 同時刻 → 畳む
    { x: 30, y: 40, t: 0.5 },
  ];
  assert.deepEqual(gestureStepsFromPoints(points), [
    { kind: "move", x: 30, y: 40, seconds: 0.5 },
  ]);
});

// ---- isGridLiveAction: tracePoints ----

test("isGridLiveAction: tracePoints は points(有限数のx/y/t)+displayWidth/Height を要求する", () => {
  assert.equal(
    isGridLiveAction({
      type: "tracePoints",
      points: [{ x: 1, y: 2, t: 0 }, { x: 3, y: 4, t: 10 }],
      displayWidth: 400, displayHeight: 800,
    }),
    true,
  );
});

test("isGridLiveAction: tracePoints は空配列を拒否する", () => {
  assert.equal(
    isGridLiveAction({ type: "tracePoints", points: [], displayWidth: 400, displayHeight: 800 }),
    false,
  );
});

test("isGridLiveAction: tracePoints は非有限の点(NaN/Infinity)を拒否する", () => {
  assert.equal(
    isGridLiveAction({
      type: "tracePoints", points: [{ x: NaN, y: 1, t: 0 }], displayWidth: 400, displayHeight: 800,
    }),
    false,
  );
  assert.equal(
    isGridLiveAction({
      type: "tracePoints", points: [{ x: 1, y: Infinity, t: 0 }], displayWidth: 400, displayHeight: 800,
    }),
    false,
  );
});

test("isGridLiveAction: tracePoints は displayWidth/Height 欠落を拒否する", () => {
  assert.equal(
    isGridLiveAction({ type: "tracePoints", points: [{ x: 1, y: 2, t: 0 }], displayWidth: 400 }),
    false,
  );
});

// ---- 軌跡の上限(縮めない) ----

test("gestureCapFor: 10秒以下は既定のまま・10秒超は切り上げた秒で上げる・60秒超は断る", () => {
  assert.equal(gestureCapFor(3), undefined);
  assert.equal(gestureCapFor(10), undefined);
  assert.equal(gestureCapFor(10.2), 11);
  assert.equal(gestureCapFor(59.5), 60);
  assert.equal(gestureCapFor(60), 60);
  assert.equal(gestureCapFor(60.01), "tooLong");
});

test("serveCommandAllowanceMs: gesture は最後の点の時刻(秒→ms)・他の内側上限を持たないコマンドは 0", () => {
  const fingers = [{ points: [{ x: 0, y: 0, t: 0 }, { x: 1, y: 1, t: 14.25 }] }];
  assert.equal(serveCommandAllowanceMs({ cmd: "gesture", fingers }), 14250);
  assert.equal(serveCommandAllowanceMs({ cmd: "tap", x: 1, y: 1 }), 0);
});

test("serveCommandAllowanceMs: press/drag/pinch は指定秒数そのもの(秒→ms)", () => {
  assert.equal(serveCommandAllowanceMs({ cmd: "press", x: 0, y: 0, duration: 5 }), 5000);
  // fold は開閉の確かめの待ち(serve の既定 5 秒 = FTCore.DefaultWait.seconds)
  assert.equal(serveCommandAllowanceMs({ cmd: "fold", state: "fold" }), 5000);
  assert.equal(
    serveCommandAllowanceMs({ cmd: "drag", fromX: 0, fromY: 0, toX: 1, toY: 1, press: 0.05, duration: 0.3 }),
    350,
  );
  assert.equal(serveCommandAllowanceMs({ cmd: "pinch", scale: 2, duration: 0.5 }), 500);
});

test("traceSummary: 点の数・時間・範囲・隣り合う点の最大の跳び(左上の角を経由した点列は最小 0 と大きな跳びで分かる)", async () => {
  const { traceSummary } = await import("../src/liveModel");
  const display = { width: 300, height: 600 };
  assert.equal(traceSummary([], display), "0 points");
  assert.equal(
    traceSummary([{ x: 100, y: 200, t: 0 }, { x: 110, y: 210, t: 16 }, { x: 0, y: 0, t: 32 }, { x: 120, y: 220, t: 48 }], display),
    "4 points over 48ms on 300x600 / first move at 16ms / x 0..120 y 0..220 / largest jump 251px to (120,220) at 48ms");
  assert.match(traceSummary([{ x: 5, y: 5, t: 0 }, { x: 5, y: 5, t: 600 }, { x: 9, y: 5, t: 630 }], display),
    / first move at 630ms /, "始めに止まっていた時間が分かる");
});
