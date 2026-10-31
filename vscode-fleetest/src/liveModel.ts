// liveModel.ts
// グリッドビューのライブ操作(liveTabHost.ts)向けの vscode 非依存ロジック(検証・型定義・座標変換・
// webview プロトコル)。
//
// 契約(Sources/fleetest/ApiListDevicesCommand.swift・ApiLiveCommand.swift):
//   `fleetest api list-devices --project <p>`: 成功時は stdout 1行JSON、失敗時
//   (実行プロファイルの devices 未設定等)は stdout 出力なし・非0終了(診断は stderr のみ)。
//   各デバイスの udid: iOS は解決済み UDID(シミュレータ/実機とも)、Android・解決失敗は null
//   (ApiListDevicesCommand.swift 参照。live serve --udid の自動起動判定に使う)。
//   kind: "virtual"(シミュレータ/エミュレータ)/ "physical"(実機)。実機は録画・画面配信が
//   できないので UI 側の出し分けに使う。
//   `fleetest api live serve --platform <p> [--port <n>|--serial <s>]`(常駐。stdin から NDJSON で
//   コマンドを1行ずつ受け、逐次処理する。コマンド/イベントの形は LiveServeCommand/LiveServeEvent
//   型を参照): イベントは refresh 以外は actionResult→snapshot の順で2行、refresh は snapshot の
//   1行のみ(parseLiveServeEvent が "kind" で判別)。

import { t, type MessageKey } from "./i18n";
import type { MonitorDeviceState, MonitorPlatform } from "./monitorModel";

export type LivePlatform = MonitorPlatform;
/** デバイスの実体種別(list-devices の kind)。 */
export type LiveDeviceKind = "virtual" | "physical";
/** list-devices の state 語彙は ApiMonitorCommand.determineStates と同一(monitorModel.ts を再利用)。 */
export type LiveDeviceState = MonitorDeviceState;

const PLATFORMS: ReadonlySet<string> = new Set<LivePlatform>(["ios", "android"]);
const DEVICE_STATES: ReadonlySet<string> = new Set<LiveDeviceState>(["connected", "booted", "offline"]);
const DEVICE_KINDS: ReadonlySet<string> = new Set<LiveDeviceKind>(["virtual", "physical"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// ---- list-devices ------------------------------------------------------------------

export interface LiveDevice {
  readonly name: string;
  readonly platform: LivePlatform;
  readonly state: LiveDeviceState;
  readonly detail: string;
  readonly port: number | null;
  readonly serial: string | null;
  readonly udid: string | null;
  readonly kind: LiveDeviceKind;
}

export interface ListDevicesResult {
  readonly project: string;
  readonly devices: readonly LiveDevice[];
}

function isLiveDevice(value: unknown): value is LiveDevice {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.name === "string" &&
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    typeof value.state === "string" &&
    DEVICE_STATES.has(value.state) &&
    typeof value.detail === "string" &&
    (value.port === null || typeof value.port === "number") &&
    (value.serial === null || typeof value.serial === "string") &&
    (value.udid === null || typeof value.udid === "string") &&
    typeof value.kind === "string" && DEVICE_KINDS.has(value.kind)
  );
}

export function isListDevicesResult(value: unknown): value is ListDevicesResult {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.project === "string" &&
    Array.isArray(value.devices) &&
    value.devices.every(isLiveDevice)
  );
}

export function parseListDevicesResult(value: unknown): ListDevicesResult | undefined {
  if (!isListDevicesResult(value)) {
    return undefined;
  }
  return value;
}

// ---- live snapshot / アクション共通 ----------------------------------------------------

export interface LiveRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface LiveSize {
  readonly width: number;
  readonly height: number;
}

export interface LivePoint {
  readonly x: number;
  readonly y: number;
}

export interface LiveElement {
  readonly ref: number;
  readonly type: string;
  readonly label: string | null;
  readonly identifier: string | null;
  readonly value: string | null;
  readonly frame: LiveRect;
}

export interface LiveSnapshot {
  readonly ok: true;
  readonly platform: string;
  readonly screen: LiveSize;
  readonly image: string;
  readonly elements: readonly LiveElement[];
  /** 観測そのものへの注記(鮮度警告等。契約: ApiLiveCommand.swift 冒頭・FTCore.StaleFrameDetector)。
   * 注記が無い回も常に空配列(CLI 側は null にしない)。 */
  readonly notes: readonly string[];
  /** LiveBridgeAutoStarter.isStarting(契約: ApiLiveCommand.swift 冒頭)。ok/エラーを問わず全イベント
   * 共通の必須フィールド。monitorLiveController.ts の applyBridgeStarting が読む。 */
  readonly bridgeStarting: boolean;
  /** 画面を撮り始めた時刻(デバイスの居る機械の epoch ms。契約: ApiLiveCommand.swift 冒頭)。グリッドビューが
   * この絵を出したあと、これより前に撮られたモニターのポーリングの絵を捨てる(deviceTiles.js の showMirrorStill) */
  readonly capturedAtMs: number;
}

export interface LiveOkResult {
  readonly ok: true;
  /** actionResult のみ: その操作を撃った先(セッションの向き先の bundle ID)。契約は
   * Sources/fleetest/ApiLiveCommand.swift 冒頭。iOS のみ・不明なら undefined。 */
  readonly app?: string;
  /** LiveSnapshot.bridgeStarting と同じ。 */
  readonly bridgeStarting: boolean;
}

export interface LiveErrorResult {
  readonly ok: false;
  readonly error: string;
  /** LiveOkResult.app と同じ(失敗した操作の撃ち先)。 */
  readonly app?: string;
  /** LiveSnapshot.bridgeStarting と同じ。 */
  readonly bridgeStarting: boolean;
}

/** actionResult の成否に共通の欄。`dsl` = 撃った操作と同じ操作の Swift DSL の1行(行末コメントつき)。
 * **必須(値は null 可)**: serve が組めなかった操作(観測だけ・DSL に行が無い・ref が木に無い)は null。
 * 契約と変換は Sources/fleetest/ApiLiveCommand.swift 冒頭・LiveOperationDSL.swift。 */
export interface LiveActionDsl {
  readonly dsl: string | null;
  /** dsl の行が対象に書いたセレクタ(座標の行・対象を取らない行は null)。必須(値は null 可)。
   * 操作の列に添える(withDslSelector)。dsl の行から切り出さない */
  readonly dslSelector: string | null;
}

/** 操作の列(「タップ: Apple マップ」)に、DSL の行が対象に書いたセレクタを `("…")` で添える。
 * **ラベルの末尾(要素名 = live.opLabel.* の `{target}`)がそのセレクタなら添えない**(要素名が id のとき =
 * 「ダブルタップ: #Viewport」に同じ文字列を重ねない)。`{target}` 全体との一致で見る(直前の `": "` まで含める)——
 * 素の末尾一致だと「タップ: Not OK」と `OK` を同じと読む。セレクタが無い(座標の行等)ならラベルのまま */
export function withDslSelector(label: string, selector: string | null | undefined): string {
  if (!selector || label.endsWith(`: ${selector}`)) {
    return label;
  }
  return `${label}(${JSON.stringify(selector)})`;
}

/** 操作の失敗だけが持つ欄。true = 届いたか分からない(契約: ApiLiveCommand.swift 冒頭) */
export type LiveActionError = LiveErrorResult & { readonly deliveryUnknown: boolean };
export type LiveActionResult = (LiveOkResult | LiveActionError) & LiveActionDsl;

function isLiveRect(value: unknown): value is LiveRect {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.x === "number" &&
    typeof value.y === "number" &&
    typeof value.width === "number" &&
    typeof value.height === "number"
  );
}

function isLiveElement(value: unknown): value is LiveElement {
  if (!isRecord(value)) {
    return false;
  }
  return (
    typeof value.ref === "number" &&
    typeof value.type === "string" &&
    (value.label === null || typeof value.label === "string") &&
    (value.identifier === null || typeof value.identifier === "string") &&
    (value.value === null || typeof value.value === "string") &&
    isLiveRect(value.frame)
  );
}

export function isLiveSnapshot(value: unknown): value is LiveSnapshot {
  if (!isRecord(value) || value.ok !== true) {
    return false;
  }
  return (
    typeof value.platform === "string" &&
    PLATFORMS.has(value.platform) &&
    isRecord(value.screen) &&
    typeof value.screen.width === "number" &&
    typeof value.screen.height === "number" &&
    typeof value.image === "string" &&
    Array.isArray(value.elements) &&
    value.elements.every(isLiveElement) &&
    Array.isArray(value.notes) &&
    value.notes.every((note) => typeof note === "string") &&
    typeof value.bridgeStarting === "boolean" &&
    typeof value.capturedAtMs === "number"
  );
}

export function isLiveErrorResult(value: unknown): value is LiveErrorResult {
  if (!isRecord(value) || value.ok !== false) {
    return false;
  }
  return typeof value.error === "string" && typeof value.bridgeStarting === "boolean";
}

export function isLiveOkResult(value: unknown): value is LiveOkResult {
  return isRecord(value) && value.ok === true && typeof value.bridgeStarting === "boolean";
}

export function parseLiveSnapshotResult(value: unknown): LiveSnapshot | LiveErrorResult | undefined {
  if (isLiveSnapshot(value)) {
    return value;
  }
  if (isLiveErrorResult(value)) {
    return value;
  }
  return undefined;
}

export function parseLiveActionResult(value: unknown): LiveActionResult | undefined {
  // dsl・dslSelector は必須(null 可)。欠落・文字列でも null でもない値は不正な actionResult として捨てる
  // (後方互換の読み替えは置かない。版を揃える運用 = 版と契約の同期)
  if (!isRecord(value) || !(value.dsl === null || typeof value.dsl === "string")
      || !(value.dslSelector === null || typeof value.dslSelector === "string")) {
    return undefined;
  }
  const dsl = value.dsl;
  const dslSelector = value.dslSelector;
  // app は**在るときだけ載せる**(undefined の欄を作らない。serve は分からなければ null を送る)
  const app = typeof value.app === "string" ? { app: value.app } : {};
  if (isLiveOkResult(value)) {
    return { ok: true, bridgeStarting: value.bridgeStarting, dsl, dslSelector, ...app };
  }
  if (isLiveErrorResult(value) && typeof value.deliveryUnknown === "boolean") {
    return { ok: false, error: value.error, bridgeStarting: value.bridgeStarting,
      deliveryUnknown: value.deliveryUnknown, dsl, dslSelector, ...app };
  }
  return undefined;
}

// ---- live serve(常駐プロセス)のコマンド組み立て・イベント検証(契約はファイル冒頭参照) -----------

/** GesturePoint と同じ形(x/y は device 座標、t はジェスチャ開始からの秒)。 */
export interface LiveGesturePoint {
  readonly x: number;
  readonly y: number;
  readonly t: number;
}

export interface LiveGestureFinger {
  readonly points: readonly LiveGesturePoint[];
}

export type LiveServeCommand =
  | { readonly cmd: "tap"; readonly ref: number }
  | { readonly cmd: "tap"; readonly x: number; readonly y: number }
  // ref は省くか整数。**null を送らない** —— serve(ApiLiveServeCommand.intField)はキーがあれば整数を要求し、
  // null は型違いとして操作せずに断る(省略とは読まない)
  | { readonly cmd: "type"; readonly text: string; readonly ref?: number }
  | {
      readonly cmd: "drag";
      readonly fromX: number;
      readonly fromY: number;
      readonly toX: number;
      readonly toY: number;
      readonly press: number;
      readonly duration: number;
    }
  | { readonly cmd: "press"; readonly x: number; readonly y: number; readonly duration: number }
  | { readonly cmd: "doubleTap"; readonly x: number; readonly y: number }
  /** 軌跡モード専用(グリッドビューの Option+ドラッグ)。ワイヤ形は
   * `Sources/FTCore/BridgeDTO.swift` の `GestureRequest.fingers` と同じ(`GesturePoint.t` は
   * ジェスチャ開始からの**秒**)。座標は既に device 座標(pointFromClick 済み)。呼び手
   * (monitorLiveController.ts の tracePoints ハンドラ)がここへ揃える前は webview の点列は
   * 表示pxかつ ms 単位なので、そのまま送らない */
  | {
      readonly cmd: "gesture";
      readonly fingers: readonly LiveGestureFinger[];
      /** 再生時間が既定の上限(10秒)を超えるときだけ付ける。値の出どころは gestureCapFor */
      readonly maxGestureSeconds?: number;
    }
  | { readonly cmd: "pinch"; readonly scale: number; readonly duration: number }
  | { readonly cmd: "appSwitcher" }
  | { readonly cmd: "home" }
  /** 折りたたみ機の開閉(FTCore.FoldControl。折りたためない端末は serve が何も送らずに断る) */
  | { readonly cmd: "fold"; readonly state: "fold" | "unfold" }
  | { readonly cmd: "refresh" };

export interface GestureStepMove {
  readonly kind: "move";
  readonly x: number;
  readonly y: number;
  readonly seconds: number;
}
export interface GestureStepHold {
  readonly kind: "hold";
  readonly seconds: number;
}
export type GestureStep = GestureStepMove | GestureStepHold;

/** 点列(x/y は絶対座標、t は秒)→ move/hold の列。**同じ座標が続く区間は静止(hold)**、そうでなければ
 * 移動(move)。時刻が巻き戻る/止まっている点(dt<=0)は畳む(捨てる)—— 間引き後の点列や
 * pointerup の最終点が直前の点と同時刻・同座標になり得るため。serve 側の同等品は
 * `TouchGesture.fingers(fromPoints:)`(Sources/FTCore/TouchGesture.swift。片方だけ変えない)。 */
export function gestureStepsFromPoints(
  points: readonly LiveGesturePoint[],
): GestureStep[] {
  const steps: GestureStep[] = [];
  for (let i = 1; i < points.length; i++) {
    const previous = points[i - 1]!;
    const current = points[i]!;
    const seconds = current.t - previous.t;
    if (seconds <= 0) {
      continue;
    }
    if (current.x === previous.x && current.y === previous.y) {
      steps.push({ kind: "hold", seconds });
    } else {
      steps.push({ kind: "move", x: current.x, y: current.y, seconds });
    }
  }
  return steps;
}

/** serve の stdin へ書き込む1行(末尾改行付き)を組み立てる。 */
/** ジェスチャ秒数の既定上限・絶対上限(秒)。`BridgeAPI.defaultMaxGestureSeconds` /
 * `BridgeAPI.gestureSecondsCeiling` と同値(片方だけ変えない) */
export const DEFAULT_MAX_GESTURE_SECONDS = 10;
export const GESTURE_SECONDS_CEILING = 60;

/** 軌跡の再生時間 → 送る maxGestureSeconds。**縮めない**(利用者がなぞった時間どおりに再生する)
 * ので、既定上限を超えたらこの1回だけ上限を上げる。undefined = 既定のままでよい /
 * "tooLong" = 絶対上限を超えていて再生できない */
export function gestureCapFor(totalSeconds: number): number | undefined | "tooLong" {
  if (totalSeconds <= DEFAULT_MAX_GESTURE_SECONDS) { return undefined; }
  if (totalSeconds > GESTURE_SECONDS_CEILING) { return "tooLong"; }
  return Math.min(GESTURE_SECONDS_CEILING, Math.ceil(totalSeconds));
}

/** fold の開閉の確かめを待つ上限(ms)。serve の既定(`FTCore.DefaultWait.seconds` = 5秒。
 * ApiLiveServeCommand.watchdogAllowanceSeconds の fold)と同値 —— 片方だけ変えない。 */
const FOLD_ALLOWANCE_MS = 5_000;

/** serve がこのコマンドで正当に占有する時間(ms)。応答待ちの上限にこのぶんを足す。
 * Swift 側は `ApiLiveServeCommand.watchdogAllowanceSeconds`(Sources/fleetest/ApiLiveCommand.swift)
 * が同じ表を持つ(片方だけ変えない)。 */
export function serveCommandAllowanceMs(command: LiveServeCommand): number {
  switch (command.cmd) {
    case "gesture": {
      let last = 0;
      for (const finger of command.fingers) {
        for (const p of finger.points) { last = Math.max(last, p.t); }
      }
      return Math.ceil(last * 1000);
    }
    case "press":
      return Math.ceil(command.duration * 1000);
    case "drag":
      return Math.ceil((command.press + command.duration) * 1000);
    case "pinch":
      return Math.ceil(command.duration * 1000);
    case "fold":
      return FOLD_ALLOWANCE_MS;
    default:
      return 0;
  }
}

export function serializeLiveServeCommand(command: LiveServeCommand): string {
  return `${JSON.stringify(command)}\n`;
}

export type LiveServeEvent =
  | { readonly kind: "actionResult"; readonly result: LiveActionResult }
  | { readonly kind: "snapshot"; readonly result: LiveSnapshot | LiveErrorResult };

/**
 * NDJSON 1行を "kind" で actionResult/snapshot に振り分ける。中身の検証は
 * parseLiveActionResult/parseLiveSnapshotResult に委ねるが、それらの戻り値には envelope 側の
 * "kind" が残らないため、ここで詰め直す。判別不能なら undefined。
 */
export function parseLiveServeEvent(value: unknown): LiveServeEvent | undefined {
  if (!isRecord(value) || typeof value.kind !== "string") {
    return undefined;
  }
  if (value.kind === "actionResult") {
    const result = parseLiveActionResult(value);
    if (!result) {
      return undefined;
    }
    // parseLiveActionResult が ok/error/app だけの新しい物を作るので、envelope の "kind" は残らない
    return { kind: "actionResult", result };
  }
  if (value.kind === "snapshot") {
    const result = parseLiveSnapshotResult(value);
    if (!result) {
      return undefined;
    }
    return {
      kind: "snapshot",
      result: result.ok
        ? {
            ok: true,
            platform: result.platform,
            screen: result.screen,
            image: result.image,
            elements: result.elements,
            notes: result.notes,
            bridgeStarting: result.bridgeStarting,
            capturedAtMs: result.capturedAtMs,
          }
        : { ok: false, error: result.error, bridgeStarting: result.bridgeStarting },
    };
  }
  return undefined;
}

// ---- 座標変換 ---------------------------------------------------------------------------
// 契約: screen/frame はポイント座標、表示側は画像左上を原点とする表示px。画像は screen の
// アスペクト比のままレターボックス無しで表示される前提。

/** クリック位置(表示px)→ ポイント座標(比例変換)。
 * 範囲外クリックでも screen の範囲にクランプする。 */
export function pointFromClick(click: LivePoint, display: LiveSize, screen: LiveSize): LivePoint {
  if (display.width <= 0 || display.height <= 0 || screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0 };
  }
  const x = (click.x / display.width) * screen.width;
  const y = (click.y / display.height) * screen.height;
  return {
    x: Math.min(Math.max(x, 0), screen.width),
    y: Math.min(Math.max(y, 0), screen.height),
  };
}

/** ポイント座標→表示pxの矩形(pointFromClick の逆変換)。要素一覧ホバー時の枠オーバーレイに使う。 */
export function frameToDisplayRect(frame: LiveRect, screen: LiveSize, display: LiveSize): LiveRect {
  if (screen.width <= 0 || screen.height <= 0) {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
  const scaleX = display.width / screen.width;
  const scaleY = display.height / screen.height;
  return {
    x: frame.x * scaleX,
    y: frame.y * scaleY,
    width: frame.width * scaleX,
    height: frame.height * scaleY,
  };
}

/** テキスト入力系の型語彙(タップ→入力欄フォーカス判定に使う)。契約: Sources/FTCore/
 * SnapshotRendering.swift の textInputTypes と同一。型名は**先頭小文字**(ホスト側の
 * ElementInfo.normalizedType が畳む。api の JSON もこの形)。変更したら Swift 側も追随させること。 */
const TEXT_INPUT_TYPES: ReadonlySet<string> = new Set(["textField", "secureTextField", "textView", "searchField"]);

/** 要素がテキスト入力欄(タップするとキーボード入力対象になる)かどうか。 */
export function isTextInputElement(element: LiveElement): boolean {
  return TEXT_INPUT_TYPES.has(element.type);
}

/** click の変換先ポイント座標を含む要素のうち、面積最小のもの(=重なりの中で最も具体的なもの)を返す。
 * 一致なしは undefined。 */
export function hitTestElement(point: LivePoint, elements: readonly LiveElement[]): LiveElement | undefined {
  let best: LiveElement | undefined;
  let bestArea = Infinity;
  for (const element of elements) {
    const { frame } = element;
    if (point.x < frame.x || point.x > frame.x + frame.width || point.y < frame.y || point.y > frame.y + frame.height) {
      continue;
    }
    const area = frame.width * frame.height;
    if (area < bestArea) {
      bestArea = area;
      best = element;
    }
  }
  return best;
}

// ---- 要素一覧の1行表示フォーマット --------------------------------------------------------

/**
 * 要素一覧の1行のうち**左の列**の表示テキストを組み立てる(形式:
 * `[ref] type "label" id=identifier =value`。label/identifier/value が空・null のフィールドは省く)。
 * 矩形は右の列(formatElementFrame)なのでここには含めない。
 */
export function formatElementLine(element: LiveElement): string {
  const parts = [`[${element.ref}]`, element.type];
  if (element.label !== null && element.label.length > 0) {
    parts.push(t("live.elementLine.label", { label: element.label }));
  }
  if (element.identifier !== null && element.identifier.length > 0) {
    parts.push(`id=${element.identifier}`);
  }
  if (element.value !== null && element.value.length > 0) {
    parts.push(`=${element.value}`);
  }
  return parts.join(" ");
}

/**
 * 要素一覧の1行のうち**右の列**(矩形)。書式は ft_snapshot の要素行
 * (Sources/FTCore/SnapshotRendering.swift)と同じ `(x,y WxH)`・ポイント座標で、
 * Swift 側の `Int(_:)` と同じ切り捨て(負値も 0 方向へ)。
 */
export function formatElementFrame(frame: LiveRect): string {
  const n = (value: number): number => (Number.isFinite(value) ? Math.trunc(value) : 0);
  return `(${n(frame.x)},${n(frame.y)} ${n(frame.width)}x${n(frame.height)})`;
}

/** 「操作記録」1行に使う要素の短い説明。label > #identifier > type の優先。 */
export function describeElementShort(element: LiveElement): string {
  if (element.label !== null && element.label.length > 0) {
    return element.label;
  }
  if (element.identifier !== null && element.identifier.length > 0) {
    return `#${element.identifier}`;
  }
  return element.type;
}

/** 「操作記録」ラベル("入力: {text}")の表示テキストを20文字に切り詰める(monitorLiveController.ts の typeText ハンドラ)。 */
export function truncateOperationLabelText(text: string): string {
  return text.length > 20 ? `${text.slice(0, 20)}…` : text;
}

const SWIPE_DIRECTION_KEYS = {
  up: "live.direction.up",
  down: "live.direction.down",
  left: "live.direction.left",
  right: "live.direction.right",
} as const satisfies Record<string, MessageKey>;

/** スワイプ方向の訳文("上"/"下"/"左"/"右" 等)。monitorLiveController.ts の dragPoints ハンドラが使う。 */
export function swipeDirectionLabel(direction: "up" | "down" | "left" | "right"): string {
  return t(SWIPE_DIRECTION_KEYS[direction]);
}

// ---- デバイス → CLI引数組み立て -----------------------------------------------------------

export interface LiveDeviceRef {
  readonly platform: LivePlatform;
  readonly port: number | null;
  readonly serial: string | null;
  readonly udid: string | null;
  /** そのデバイスが居る機械(登録簿の machine)。省略 = この Mac。あれば serve を
   * `fleetest remote exec <machine> -- api live serve` で**向こうで**起こす(monitorLiveController.ts) */
  readonly machine?: string;
}

/** udid は含めない(--udid は monitorLiveController.ts が `api live serve` 呼び出し時に個別に付与する)。 */
export function buildDeviceArgs(device: LiveDeviceRef): string[] {
  const args = ["--platform", device.platform];
  if (device.platform === "ios") {
    if (device.port !== null && device.port > 0) {
      args.push("--port", String(device.port));
    }
  } else if (device.serial !== null && device.serial.trim().length > 0) {
    args.push("--serial", device.serial.trim());
  }
  return args;
}

/** デバイス参照の同一性判定(monitorLiveController.ts の serve 再バインド要否判定に使う)。 */
export function sameLiveDeviceRef(a: LiveDeviceRef, b: LiveDeviceRef): boolean {
  return a.platform === b.platform && a.port === b.port && a.serial === b.serial && a.udid === b.udid
    && a.machine === b.machine;
}

/** fleetest.platform/port/serial 設定から作る「設定のデバイス」フォールバックの元データ。 */
export interface FallbackDeviceSource {
  readonly platform: LivePlatform;
  /** FleetestConfig.port と同じ規約: 0 は未指定。 */
  readonly port: number;
  /** FleetestConfig.serial と同じ規約: 空文字列は未指定。 */
  readonly serial: string;
}

export function buildFallbackDevice(source: FallbackDeviceSource): LiveDeviceRef {
  return {
    platform: source.platform,
    port: source.port > 0 ? source.port : null,
    serial: source.serial.trim().length > 0 ? source.serial.trim() : null,
    udid: null,
  };
}

// ---- デバイス選択UI向けのオプション -----------------------------------------------------

/** list-devices 由来の state に加え、フォールバック(設定のデバイス)用に "unknown" を許容する。 */
export type LiveDeviceOptionState = LiveDeviceState | "unknown";

export interface LiveDeviceOption {
  readonly id: string;
  readonly name: string;
  readonly platform: LivePlatform;
  readonly state: LiveDeviceOptionState;
  readonly detail: string;
  readonly port: number | null;
  readonly serial: string | null;
  readonly udid: string | null;
  /** 実体種別。フォールバックは実体が分からないので virtual を既定にする。 */
  readonly kind: LiveDeviceKind;
  /** LiveDeviceRef.machine と同じ。list-devices(この Mac)由来は常に省略 */
  readonly machine?: string;
}

/** 他の機械のデバイス(モニターのタイル)をライブ操作の選択肢にする。id はモニターのタイル id
 * (`<platform>:<machine>/<name>`)のまま —— handleGridAction がこの id で引く。
 * **port は渡さない**: 向こうの serve が udid で自分のブリッジを探す(既定ポートの本人確認 →
 * 走査 → 無ければ空きポートで自動起動。ApiLiveCommand.makeLiveDriver)。 */
export function remoteDeviceOption(source: {
  readonly id: string;
  readonly name: string;
  readonly platform: LivePlatform;
  readonly state: LiveDeviceOptionState;
  readonly udid: string | null;
  readonly serial: string | null;
  readonly kind: LiveDeviceKind;
  readonly machine: string;
}): LiveDeviceOption {
  return {
    id: source.id, name: source.name, platform: source.platform, state: source.state,
    detail: "", port: null, serial: source.serial, udid: source.udid, kind: source.kind,
    machine: source.machine,
  };
}

/** id はデバイス名(machines プロファイル検証で ios/android 横断の一意性が保証済み)を使うため、
 * 一覧の並び替え・再取得を挟んでも選択状態を維持できる。 */
export function devicesToOptions(devices: readonly LiveDevice[]): LiveDeviceOption[] {
  return devices.map((device) => ({
    id: `${device.platform}:${device.name}`,
    name: device.name,
    platform: device.platform,
    state: device.state,
    detail: device.detail,
    port: device.port,
    serial: device.serial,
    udid: device.udid,
    kind: device.kind,
  }));
}

export const FALLBACK_DEVICE_ID = "config-fallback";

export function fallbackDeviceOption(source: FallbackDeviceSource): LiveDeviceOption {
  const ref = buildFallbackDevice(source);
  return {
    id: FALLBACK_DEVICE_ID,
    name: t("live.fallbackDeviceName"),
    platform: ref.platform,
    state: "unknown",
    detail: t("live.fallbackDeviceDetail"),
    port: ref.port,
    serial: ref.serial,
    udid: ref.udid,
    kind: "virtual",
  };
}

// ---- webview メッセージプロトコル ---------------------------------------------------------

/** webview へ渡す要素一覧の行。line は左の列・frameText は右の列(表示テキストを host 側で事前整形して付与する)。 */
export interface LiveElementView extends LiveElement {
  readonly line: string;
  readonly frameText: string;
}

/** host → グリッドビュー(gridLiveControls.js・gridLivePanel.js)。封筒は LiveToWebviewEnvelope。 */
export type LiveToWebviewMessage =
  | {
      readonly type: "devices";
      readonly devices: readonly LiveDeviceOption[];
      readonly selectedId: string | undefined;
    }
  | {
      readonly type: "snapshot";
      readonly platform: string;
      readonly screen: LiveSize;
      readonly image: string;
      readonly elements: readonly LiveElementView[];
      readonly notes: readonly string[];
      /** LiveSnapshot.capturedAtMs(グリッドビューの古い絵の除外に使う) */
      readonly capturedAtMs: number;
    }
  /** 直前のデバイスのスナップショット(画面サイズ・要素一覧)を捨てさせる。デバイスを
   * 切り替えたのに残っていると、タップ座標が前のデバイスの画面サイズで換算され、要素一覧の
   * 行タップが**別のデバイスの ref** を叩く。 */
  | { readonly type: "clearSnapshot" }
  /** neutral: true のときは失敗(エラー)としての見た目(赤)にしない。省略 = false
   * (bridgeStarting 中の操作失敗だけが true を送る。live.bridgeStartingActionNotice)。 */
  | { readonly type: "actionError"; readonly message: string; readonly neutral?: boolean }
  /** observing: busy の原因が画面を変えない観測か(MonitorLiveController.busyObserving)。webview はこの間の画面の操作を
   * 捨てずに送る(host が観測の終わりを待って撃つ) */
  | { readonly type: "busy"; readonly busy: boolean; readonly observing: boolean }
  // テキスト入力欄をタップした直後に「入力するテキスト」欄へフォーカスを移す指示(受け手: gridLivePanel.js)。
  | { readonly type: "focusTypeInput" }
  // 「操作記録」1行(受け手: gridLivePanel.js)。
  // dsl: 同じ操作の Swift DSL の1行(serve が組んだもの。actionResult.dsl。無ければ省く)。
  // deviceId: 操作したときの selectedDeviceId(グリッドビューがデバイスごとに振り分ける)
  | {
      readonly type: "operationLog";
      readonly label: string;
      readonly ok: boolean;
      readonly dsl?: string;
      readonly deviceId?: string;
    }
  // グリッドビューの操作(GridLiveAction)が、serve へ流す前に断られた(受け手: gridLiveControls.js)。
  // 流した後の失敗は通常の actionError で届く(グリッド側は選択中のデバイスが id と一致するときだけ出す)
  | { readonly type: "gridActionError"; readonly id: string; readonly message: string }
  // グリッドビューの操作を今から撃つ(切り替え・待ちが済んだ直後。受け手: gridLivePanel.js)。この後に届く最初の
  // snapshot がその操作の直接の結果(MonitorLiveController.handleGridAction)
  | { readonly type: "gridActionStarted"; readonly id: string }
  // 軌跡(gesture)の操作の応答が届いた = デバイスでの再生が終わった(受け手: gridLiveControls.js の太い線)。
  // 応答は続く観測(snapshot)より先に届くので、busy の終わりより早く・再生の終わりに近い時刻で知らせられる
  | { readonly type: "gestureActionDone"; readonly ok: boolean };

export function toSnapshotMessage(snapshot: LiveSnapshot): LiveToWebviewMessage {
  return {
    type: "snapshot",
    platform: snapshot.platform,
    screen: snapshot.screen,
    image: snapshot.image,
    elements: snapshot.elements.map((element) => ({
      ...element,
      line: formatElementLine(element),
      frameText: formatElementFrame(element.frame),
    })),
    notes: snapshot.notes,
    capturedAtMs: snapshot.capturedAtMs,
  };
}

/** グリッドビュー(1台だけ選択したときの拡大表示)から撃てる操作(MonitorLiveController.handleGridAction が
 * serve の命令へ流す。送り手: src/webview/monitor/gridLiveControls.js・gridLivePanel.js)。 */
export type GridLiveAction =
  | { readonly type: "refreshSnapshot" }
  | {
      readonly type: "tapPoint";
      readonly clickX: number;
      readonly clickY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
    }
  | {
      readonly type: "pressPoint";
      readonly clickX: number;
      readonly clickY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
      readonly holdMs: number;
    }
  | {
      readonly type: "doubleTapPoint";
      readonly clickX: number;
      readonly clickY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
    }
  /** 画面全体のピンチ。zoomIn=false は縮小 */
  | { readonly type: "pinch"; readonly zoomIn: boolean }
  | {
      readonly type: "dragPoints";
      readonly fromX: number;
      readonly fromY: number;
      readonly toX: number;
      readonly toY: number;
      readonly displayWidth: number;
      readonly displayHeight: number;
      readonly pressMs: number;
      readonly dragMs: number;
    }
  /** 軌跡モード(pointerdown 時に Shift を押していた)のドラッグ。点は表示px・
   * t は pointerdown からの**ミリ秒**(host 側の tracePoints ハンドラが device 座標・秒へ変換する。
   * liveModel.ts の LiveGesturePoint.t は秒なので混同しないこと)。 */
  | {
      readonly type: "tracePoints";
      readonly points: readonly { readonly x: number; readonly y: number; readonly t: number }[];
      readonly displayWidth: number;
      readonly displayHeight: number;
    }
  /** 入力は**デバイス側でフォーカスしている要素**へ送る(ref は付けない)。パネルで最後に
   * 触った要素の ref は、その操作が返すスナップショットで採番し直されるため、次の入力の時点では
   * もう同じ要素を指していない —— 送ると別の要素へ黙って打ち込む。 */
  | { readonly type: "typeText"; readonly text: string }
  | { readonly type: "appSwitcher" }
  | { readonly type: "home" }
  /** 折りたたみ機の開閉。ボタンは折りたためる端末(MonitorDevice.foldable)にだけ出す */
  | { readonly type: "fold"; readonly state: "fold" | "unfold" };

const GRID_LIVE_ACTION_TYPES: ReadonlySet<string> = new Set([
  "home", "appSwitcher", "pinch", "fold", "tapPoint", "doubleTapPoint", "tracePoints",
  "dragPoints", "pressPoint", "typeText", "refreshSnapshot",
] satisfies GridLiveAction["type"][]);

export function isGridLiveAction(value: unknown): value is GridLiveAction {
  if (!isRecord(value) || typeof value.type !== "string" || !GRID_LIVE_ACTION_TYPES.has(value.type)) {
    return false;
  }
  switch (value.type) {
    case "refreshSnapshot":
    case "appSwitcher":
    case "home":
      return true;
    case "tapPoint":
      return (
        typeof value.clickX === "number" &&
        typeof value.clickY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number"
      );
    case "pressPoint":
      return (
        typeof value.clickX === "number" &&
        typeof value.clickY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number" &&
        typeof value.holdMs === "number"
      );
    case "doubleTapPoint":
      return (
        typeof value.clickX === "number" &&
        typeof value.clickY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number"
      );
    case "pinch":
      return typeof value.zoomIn === "boolean";
    case "dragPoints":
      return (
        typeof value.fromX === "number" &&
        typeof value.fromY === "number" &&
        typeof value.toX === "number" &&
        typeof value.toY === "number" &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number" &&
        typeof value.pressMs === "number" &&
        typeof value.dragMs === "number"
      );
    case "tracePoints":
      return (
        Array.isArray(value.points) &&
        value.points.length > 0 &&
        value.points.every(
          (p) =>
            isRecord(p) &&
            typeof p.x === "number" && Number.isFinite(p.x) &&
            typeof p.y === "number" && Number.isFinite(p.y) &&
            typeof p.t === "number" && Number.isFinite(p.t),
        ) &&
        typeof value.displayWidth === "number" &&
        typeof value.displayHeight === "number"
      );
    case "fold":
      return value.state === "fold" || value.state === "unfold";
    case "typeText":
      return typeof value.text === "string";
    default:
      return false;
  }
}

// ---- host⇔webview封筒 -------------------------------------------------------------------
// グリッドビューのライブ操作はデバイスモニターの webview に同居するため、type:"live" の封筒で他のメッセージと
// 多重化する(対向: src/webview/monitor/main.js → gridLiveControls.js の applyGridLiveMessage)。

/** host → webview。 */
export interface LiveToWebviewEnvelope {
  readonly type: "live";
  readonly message: LiveToWebviewMessage;
}

/** 軌跡の点列の要約(表示座標 = webview の絵の上の px)。点の数・時間・押してから動き出すまで(始点と違う最初の点の t。
 * 始めに止まっていると iOS のマップ等は長押しとして受け取りパンしない)・範囲・隣り合う点の最大の跳び */
export function traceSummary(
  points: ReadonlyArray<{ readonly x: number; readonly y: number; readonly t: number }>,
  display: { readonly width: number; readonly height: number },
): string {
  const first = points[0];
  const last = points[points.length - 1];
  if (!first || !last) {
    return "0 points";
  }
  let minX = first.x, maxX = first.x, minY = first.y, maxY = first.y;
  let maxJump = 0;
  let jumpTo = first;
  let prev = first;
  let movedAt: number | undefined;
  for (const p of points) {
    if (movedAt === undefined && (p.x !== first.x || p.y !== first.y)) {
      movedAt = p.t;
    }
    minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
    minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    const jump = Math.hypot(p.x - prev.x, p.y - prev.y);
    if (jump > maxJump) {
      maxJump = jump;
      jumpTo = p;
    }
    prev = p;
  }
  const r = (v: number) => Math.round(v);
  return `${points.length} points over ${r(last.t)}ms on ${r(display.width)}x${r(display.height)}`
    + ` / first move at ${movedAt === undefined ? "-" : `${r(movedAt)}ms`}`
    + ` / x ${r(minX)}..${r(maxX)} y ${r(minY)}..${r(maxY)}`
    + ` / largest jump ${r(maxJump)}px to (${r(jumpTo.x)},${r(jumpTo.y)}) at ${r(jumpTo.t)}ms`;
}
