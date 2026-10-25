// monitorLiveController.ts
// デバイスモニターのグリッドビュー(1台選択)のライブ操作(liveTabHost.ts)のロジック本体。
//
// - `fleetest api list-devices` は FleetestCli の直列キュー(`fleetest api run` と共有。シナリオ実行が
//   `swift build` を伴い得るため同時2プロセスを防ぐ SPM ビルドロック対策)には乗せず、oneShotCli.ts の
//   runOneShot() で専用 spawn する。ライブ操作は実行中でも待たされず応答する必要があり、
//   list-devices はビルドを伴わないので run 側と競合しないため問題ない。
// - タップ/入力/スワイプ/終了/スナップショット取得は、選択デバイスごとに
//   `fleetest api live serve` を常駐 spawn し、stdin へ NDJSON でコマンドを送って stdout の NDJSON
//   イベント(NdjsonParser)を待つ方式で行う。プロセス管理は monitorProcessManager.ts の host-metrics
//   パターンを踏襲: stdin パイプ保持(EOF が終了指示)・SIGTERM 送信後2秒で SIGKILL・予期しない
//   終了は5秒後に自動再起動・起動10秒未満の異常終了が3連続したら諦める(serveGaveUp)。ただし
//   serve はデバイスごとの状態を持つプロセスなので、デバイス選択が変わったら明示的に再バインド
//   (停止→新デバイスで起動)し諦め状態もリセットする(=デバイスを選び直す操作が host-metrics の
//   「再起動ボタン」に相当する回復経路。専用ボタンは無い)。
// - webview 資産は src/webview/monitor/gridLiveControls.js・gridLivePanel.js(main.js から
//   applyGridLiveMessage を import)。frameToDisplayRect の計算だけを手書きで複製している(要素一覧の
//   表示テキストは host 側で事前整形して送るため複製不要)。liveModel.ts の frameToDisplayRect を変更したら
//   liveListViews.js 側も追随させること。

import { type ChildProcessByStdio, spawn } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import type * as vscode from "vscode";
import { childEnv } from "./childEnv";
import { type FleetestConfig, resolveProjectName } from "./config";
import { checkForDyldLaunchFailure } from "./dyldLaunchNotice";
import { t } from "./i18n";
import {
  buildDeviceArgs,
  describeElementShort,
  devicesToOptions,
  fallbackDeviceOption,
  hitTestElement,
  isTextInputElement,
  type LiveActionResult,
  type LiveDeviceOption,
  type LiveDeviceRef,
  type LiveElement,
  type LiveErrorResult,
  type LiveServeCommand,
  type LiveSize,
  type LiveSnapshot,
  type LiveToWebviewMessage,
  parseListDevicesResult,
  GESTURE_SECONDS_CEILING,
  type GridLiveAction,
  gestureCapFor,
  parseLiveServeEvent,
  pointFromClick,
  sameLiveDeviceRef,
  serializeLiveServeCommand,
  serveCommandAllowanceMs,
  swipeDirectionLabel,
  toSnapshotMessage,
  traceSummary,
  truncateOperationLabelText,
} from "./liveModel";
import type { LiveDeps } from "./liveDeps";
import { NdjsonParser } from "./ndjson";
import { type OneShotResult, type PipeProcess, runOneShot } from "./oneShotCli";

/**
 * serve プロセス用: stdin もパイプで保持する(monitorProcessManager.ts の MonitorProcess/host-metrics
 * プロセスと同じ形。`fleetest api live serve` は stdin へのコマンド送信と EOF 終了指示の両方に
 * stdin パイプを使うため、stdio を "ignore" にはできない)。
 */
type ServeProcess = ChildProcessByStdio<Writable, Readable, Readable>;

/** serve への1リクエスト(コマンド送信〜応答受信)のタイムアウト(ms)。通常は1秒未満で応答が
 * 返るが、アプリ起動(ブリッジ側の静止待ち上限10秒)等を考慮して余裕を持たせた安全弁。
 * 応答が無いまま常駐プロセスが停止したり壊れたりしても busy 状態のまま固まらないようにする。 */
const SERVE_REQUEST_TIMEOUT_MS = 20000;

/** 応答タイムアウトによる wedge 復旧(serve の kill→自動 respawn)を連続で試みる上限。これを
 * 超えたら自動再起動を止め、serveUnavailableMessage() を出す(デバイス選び直し=rebind で解除)。 */
const MAX_CONSECUTIVE_TIMEOUT_KILLS = 3;

/** デバイス切り替えの再バインド(rebindServeProcess の stop→start)が終わるのを待つ上限(ms)。
 * 旧 serve は SIGTERM を無視するので、停止は stdin EOF か killServeProcess の2秒後 SIGKILL まで
 * 掛かり、その間 serveProcess は未設定になる。この窓のコマンドを待たずに断ると、利用者が
 * **たった今選び直したデバイス**に対して「起動していません。デバイスを選び直してください」を出す
 * ことになる(案内どおり選び直しても同じ再バインドなので同じ文言が出る)。2秒の停止 + close→spawn
 * の余裕。超えたらそのまま断る(本当に立ち上がらない場合の固まりを作らない)。 */
const SERVE_REBIND_WAIT_MS = 6000;

/** 再バインドで旧 serve の close を待つ上限(ms)。killServeProcess は SIGTERM の 2 秒後に SIGKILL
 * するので close は通常 2〜3 秒で来る。8 秒は monitorProcessManager の RESTART_CLOSE_TIMEOUT_MS と同じ余裕 */
const SERVE_REBIND_CLOSE_TIMEOUT_MS = 8000;

/** 「全て終了」の前に serve を畳むときの close 待ちの上限(ms)。killServeProcess は stdin EOF +
 * SIGTERM を送り 2 秒後に SIGKILL へ上げるので、その 2 秒 + 余裕。上限に当たっても掃討へ進む
 * (印が残っていても持ち主の pid は死んでいる = CLI は生きた印としては数えない)。 */
const SERVE_SWEEP_STOP_WAIT_MS = 2500;

/** serve 常駐プロセスの不在・応答不能・終了を表す文言。これらは個々の操作失敗(タップ失敗・
 * 未入力など)とは違い「接続状態」の問題で、serve が復帰すれば自動で解消する。postActionError が
 * isConnectionClassMessage との一致で connectionBannerShown を立て、復帰時(handleConnectionOk)に
 * バナーを自動で消す。文言(キー)を増やしたら isConnectionClassMessage も追随させること。
 * locale 切替後も表示側と比較側が食い違わないよう、値はキャッシュせず都度 t() で引く。 */
function serveUnavailableMessage(): string {
  return t("live.serveUnavailableMessage");
}
function serveTimeoutMessage(): string {
  return t("live.serveTimeoutMessage");
}
function serveClosedMessage(): string {
  return t("live.serveClosedMessage");
}
function isConnectionClassMessage(message: string): boolean {
  return message === serveUnavailableMessage() || message === serveTimeoutMessage() || message === serveClosedMessage();
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** sendServeCommand() が返す1リクエスト分の結果。action は refresh(アクション無し)のときのみ
 * undefined になる(snapshot は refresh でも常に届く)。 */
interface ServeRequestOutcome {
  readonly action: LiveActionResult | undefined;
  readonly snapshot: LiveSnapshot | LiveErrorResult;
}

/** sendServeCommand の resolve に渡す払い出し。 */
interface PendingServeOutcome {
  readonly action?: LiveActionResult;
  readonly snapshot?: LiveSnapshot | LiveErrorResult;
}

/** 送信中(応答待ち)の serve リクエスト1件分。ユーザー操作と観測が enqueueServeSend で
 * 直列化されるため同時に2件以上送らない(単一スロットで管理。activeChild と同じ「一度に1つだけ」の設計)。 */
interface PendingServeRequest {
  /** refresh は actionResult を出さないため false。 */
  readonly expectsAction: boolean;
  /** 送ったコマンドの cmd(gesture の応答だけ webview へ即座に知らせる = gestureActionDone) */
  readonly cmd: LiveServeCommand["cmd"];
  /** actionResult イベントが先に届いたら保持し、snapshot イベント到着時にまとめて resolve する。 */
  action: LiveActionResult | undefined;
  readonly resolve: (outcome: PendingServeOutcome) => void;
  readonly timeout: ReturnType<typeof setTimeout>;
}

/** 観測(画面を変えない busy)の最中に届いたら、観測の終わりを待って撃つ操作(runGridAction)。
 * 画面の操作とツールバーだけ —— 「更新」(refreshSnapshot)は従来どおり busy で何もしない */
const OBSERVATION_DEFERRABLE_ACTIONS: ReadonlySet<GridLiveAction["type"]> = new Set<GridLiveAction["type"]>([
  "tapPoint", "doubleTapPoint", "pressPoint", "dragPoints", "tracePoints", "typeText",
  "home", "appSwitcher", "pinch", "fold",
]);

export class MonitorLiveController implements vscode.Disposable {
  private devices: LiveDeviceOption[] = [];
  /** タイル右クリックで開いた**他の機械のデバイス**(registerRemoteDevice)。list-devices はこの Mac のデバイスしか
   * 返さないので、一覧を取り直すたびに applyDevices がここから足し戻す(足さないと選択が消えて
   * 先頭のデバイスへ戻る)。 */
  private readonly remoteOptions = new Map<string, LiveDeviceOption>();
  private selectedDeviceId: string | undefined;
  /** openDevice 用: 次の applyDevices で優先選択する id(消費したら undefined に戻す)。
   * **busy が解けた時点でも消化する**(setBusy)—— busy の原因が refreshDevices でない(画面取得・
   * 操作の最中)と applyDevices が来ず、切り替えが黙って捨てられる。 */
  private pendingSelectId: string | undefined;
  /** booted のデバイスへ切り替えたときの観測1回(requestOpenObservation)。busy の間は撃てない
   * (refreshSnapshot は busy なら何もしない)ので、ここに控えて setBusy(false) で撃つ。 */
  private openObservationPending = false;
  /** 直近の snapshot の screen(ポイント座標のサイズ)。クリック→タップ座標変換に使う。 */
  private lastScreen: LiveSize | undefined;
  /** 直近の snapshot の要素一覧。タップ位置のヒットテストに使う。 */
  private lastElements: readonly LiveElement[] = [];
  private busy = false;
  /** busy の原因が**画面を変えない観測**(画面の撮り直し・デバイス一覧の取り直し)か。webview はこの間の画面の操作を
   * 捨てずに送り、runGridAction が観測の終わりを待って撃つ(OBSERVATION_DEFERRABLE_ACTIONS)。操作の busy
   * (runAction)では false —— その間は画面が変わっている最中なので、これまでどおり受け付けない */
  private busyObserving = false;
  /** busy が解けるのを待つ手(waitForIdle)。setBusy(false) の後もなお busy でなければ全件起こす。 */
  private idleWaiters: Array<() => void> = [];
  /** 直近 post した actionError バナーが接続系(isConnectionClassMessage)かどうか。true の間は
   * serve 復帰(handleConnectionOk)で自動的に消す。個々の操作失敗バナーは false のまま。 */
  private connectionBannerShown = false;
  /** list-devices のワンショット spawn(専用。runOneShot 経由)。 */
  private activeChild: PipeProcess | undefined;

  // ---- live serve(常駐プロセス。デバイス選択ごとに1つ)。ファイル冒頭のコメント参照 ----
  private serveProcess: ServeProcess | undefined;
  /** serveProcess が実際にバインドされている(起動時に渡した)デバイス。selectServeProcess の
   * 「デバイスが変わったか」判定、および再起動時に同じデバイスへ再バインドするために保持する。 */
  private serveDevice: LiveDeviceRef | undefined;
  /** stopServeProcess() 経由(dispose/再バインド)による意図した終了かどうか
   * (monitorProcessManager.ts の stoppingMonitor と同じ役割)。 */
  private stoppingServe = false;
  /** rebindServeProcess() の多重起動ガード(monitorProcessManager.ts の restartPending と
   * 同じ役割)。true の間に来た再バインド要求は serveDevice の更新だけ行い、進行中の切り替えが
   * 完了した時点の最新の serveDevice を使って起動する(restartMonitorProcess と同じ
   * 「最終的に最新設定が勝つ」方式)。 */
  private serveRestartPending = false;
  /** 再バインドの完了(新しい serveProcess が立つ/起動しないと確定する)を待っている呼び出し手。
   * rebindServeProcess の startLatest が全件起こす(awaitServeRebind の doc 参照)。 */
  private serveReadyWaiters: Array<() => void> = [];
  /** stopServeProcess のたびに進む番号。close 待ちの再バインドは、待つ間にパネルが閉じた
   * (stopProcesses)なら起動しない —— 起動すると閉じたパネルの裏で serve がデバイスの lease を
   * 掴んだまま居続ける(monitorProcessManager.ts の monitorStopEpoch と同じ)。 */
  private serveStopEpoch = 0;
  /** 予期しない終了後の自動再起動タイマー(5秒後)。dispose/停止時に必ずクリアする。 */
  private serveRestartTimer: ReturnType<typeof setTimeout> | undefined;
  /** 直近の起動時刻(ms)。close イベントでの経過時間から「起動後10秒未満での異常終了」を判定する。 */
  private serveStartedAt: number | undefined;
  /** 「起動後10秒未満での異常終了」が連続した回数。3回連続したら諦めて自動再起動を止める。 */
  private serveFailureStreak = 0;
  /** 応答タイムアウトで serve を kill→respawn した連続回数。成功応答(handleConnectionOk)と
   * 明示的な再バインドでリセットする。MAX_CONSECUTIVE_TIMEOUT_KILLS で諦める。 */
  private serveTimeoutKillStreak = 0;
  /** 自動再起動を諦めた状態。true の間は close イベントで再起動をスケジュールしない
   * (rebindServeProcess でリセットされる。詳細はファイル冒頭のコメント参照)。 */
  private serveGaveUp = false;
  /** 「全て終了」(suspendServeForSweep)で畳んでから resumeServeAfterSweep までの間 true。
   * この間は startServeProcess が起動しない(掃討の途中で serve が立ち直り、デバイスの印を書き戻して
   * 掃討に断られる・掃討中のブリッジと取り合う、を作らない)。 */
  private serveSuspendedForSweep = false;
  /** 送信中(応答待ち)の serve リクエスト。同時に1件のみ(enqueueServeSend で直列化されるため)。 */
  private pendingServeRequest: PendingServeRequest | undefined;
  /** serve への送信を直列化するチェーン(観測とユーザー操作の pending 競合を防ぐ)。 */
  private serveSendChain: Promise<unknown> = Promise.resolve();

  constructor(private readonly deps: LiveDeps) {}

  /** パネル close 時・dispose 時の両方から呼ばれる。パネル再オープン後は次のグリッド操作の
   * handleGridAction→openDevice→applyDevices→ensureServeProcessForSelection で serve が再起動される。 */
  stopProcesses(): void {
    this.killActiveChild();
    this.stopServeProcess();
  }

  dispose(): void {
    this.stopProcesses();
  }

  private post(message: LiveToWebviewMessage): void {
    this.deps.post({ type: "live", message });
  }

  private setBusy(busy: boolean, observing = false): void {
    this.busy = busy;
    this.busyObserving = busy && observing;
    this.post({ type: "busy", busy, observing: this.busyObserving });
    if (busy) {
      return;
    }
    const pendingId = this.pendingSelectId;
    if (pendingId !== undefined) {
      this.pendingSelectId = undefined;
      void this.openDevice(pendingId);
      return;
    }
    if (this.openObservationPending) {
      this.openObservationPending = false;
      void this.refreshSnapshot();
    }
    // 控えていた観測が busy を立て直した回は起こさない(その観測の終わりで起こす)
    if (!this.busy && this.idleWaiters.length > 0) {
      const waiters = this.idleWaiters;
      this.idleWaiters = [];
      for (const wake of waiters) {
        wake();
      }
    }
  }

  /** busy が解けるまで待つ(上限 timeoutMs。尽きたら待たずに返る = 続く操作が busyRetry で断られる)。 */
  private waitForIdle(timeoutMs: number): Promise<void> {
    if (!this.busy) {
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      const wake = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        const i = this.idleWaiters.indexOf(wake);
        if (i >= 0) {
          this.idleWaiters.splice(i, 1);
        }
        resolve();
      }, timeoutMs);
      this.idleWaiters.push(wake);
    });
  }

  /** **booted(デバイスは起動済み・ブリッジ未接続)のデバイスへ切り替えたら観測を1回撃つ**。serve の自動起動
   * (LiveBridgeAutoStarter)の引き金は観測・操作の接続拒否だけ。撃たないと、ブリッジの無いデバイス
   * (実機では普通)を開いても「接続できません」のまま何も始まらない(実地: iPhone wave)。
   * 切り替えの全経路(openDevice / applyDevices)が通る
   * ensureServeProcess から呼ぶ。offline は撃たない(デバイスそのものが起きていない = start-device の役目) */
  private requestOpenObservation(): void {
    if (this.selectedOption()?.state !== "booted") {
      return;
    }
    if (this.busy) {
      this.openObservationPending = true;
      return;
    }
    void this.refreshSnapshot();
  }

  /** 「操作記録」1行を webview へ送る(対向: gridLivePanel.js の operationLog ハンドラ)。
   * 全ユーザー操作(tap/swipe/type/press/home/appSwitcher)の成否をここへ流す。 */
  private postOperationLog(label: string, ok: boolean, dsl?: string, deviceId?: string): void {
    this.post({
      type: "operationLog", label, ok,
      ...(dsl !== undefined ? { dsl } : {}),
      ...(deviceId !== undefined ? { deviceId } : {}),
    });
  }

  /** actionError バナーを出す共通経路。接続系の文言(serve 不在・タイムアウト・終了)なら
   * connectionBannerShown を立て、serve 復帰時に自動で消せるようにする。個々の操作失敗は
   * false のまま残す。全 actionError post はここを通す。
   * neutral: true は bridgeStarting 中の操作失敗(live.bridgeStartingActionNotice)専用 ——
   * 接続系と同じく自動で消える(connectionBannerShown を立てる)が、webview 側はエラー色にしない。 */
  private postActionError(message: string, neutral = false): void {
    this.connectionBannerShown = neutral || isConnectionClassMessage(message);
    this.post({ type: "actionError", message, ...(neutral ? { neutral: true } : {}) });
  }

  /** serve の応答が届いた(接続が生きている)ことを反映する。timeout kill の連続回数を戻し、残っている
   * 接続系 actionError バナー(常駐プロセス不在・タイムアウト・終了)を消す。デバイス切り替えの再バインド中は
   * serve が undefined→復帰するので、この経路でしかバナーを消せない(操作可能なのにエラーが残る問題の本丸)。 */
  private handleConnectionOk(): void {
    this.serveTimeoutKillStreak = 0;
    if (this.connectionBannerShown) {
      this.connectionBannerShown = false;
      this.post({ type: "actionError", message: "" });
    }
  }

  /** 実行中の live CLI プロセスがあれば SIGTERM(2秒後 SIGKILL)で止める(cli.ts と同じ方針)。 */
  private killActiveChild(): void {
    const proc = this.activeChild;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** FleetestCli のキューは使わず専用 spawn する(理由はファイル冒頭のコメント参照)。 */
  private async runCli(args: string[]): Promise<OneShotResult> {
    const config = this.deps.getConfig();
    try {
      return await runOneShot(config.binaryPath, this.deps.workspaceRoot, args, this.deps.outputChannel, (proc) => {
        this.activeChild = proc;
      });
    } finally {
      this.activeChild = undefined;
    }
  }

  private currentDeviceRef(): LiveDeviceRef | undefined {
    const option = this.devices.find((device) => device.id === this.selectedDeviceId);
    return option
      ? { platform: option.platform, port: option.port, serial: option.serial, udid: option.udid,
          machine: option.machine }
      : undefined;
  }

  // ---- デバイス一覧 ---------------------------------------------------------------

  private async refreshDevices(): Promise<void> {
    if (this.busy) {
      return;
    }
    const config = this.deps.getConfig();
    const resolution = resolveProjectName(this.deps.workspaceRoot, config);
    if (resolution.kind !== "resolved") {
      this.applyFallback(config, t("live.projectUnresolved"));
      return;
    }

    this.setBusy(true, true);
    try {
      // --profile が無いと machines/ が複数のとき「マシン名が未登録」で落ちる(monitorDeviceOps.ts と同経路)
      const listArgs = ["api", "list-devices", "--project", resolution.project];
      if (config.profile) {
        listArgs.push("--profile", config.profile);
      }
      const result = await this.runCli(listArgs);
      const parsed = parseListDevicesResult(result.json);
      if (!parsed) {
        const detail = result.stderrTail.length > 0 ? result.stderrTail : `exit code: ${String(result.exitCode)}`;
        this.applyFallback(config, t("live.deviceListFailedDetail", { detail }));
        return;
      }
      this.applyDevices(devicesToOptions(parsed.devices), undefined);
    } catch (error) {
      this.applyFallback(config, t("live.deviceListFailedError", { error: errorMessage(error) }));
    } finally {
      this.setBusy(false);
    }
  }

  /** pendingSelectId(openDevice 由来)があればそれを優先選択する。無ければ直前の選択が新しい
   * 一覧にも存在するとき維持し、それ以外は未選択にする。**先頭や fallback へ倒さない** —— 呼び手は
   * グリッドの操作だけで、頼まれていないデバイスに serve を立てるとブリッジの自動起動まで撃つ。 */
  private applyDevices(listed: LiveDeviceOption[], bannerMessage: string | undefined): void {
    this.handleConnectionOk();
    const options = [...listed.filter((o) => !this.remoteOptions.has(o.id)), ...this.remoteOptions.values()];
    this.devices = options;
    const pending = this.pendingSelectId;
    this.pendingSelectId = undefined;
    const preferred = pending !== undefined && options.some((o) => o.id === pending) ? pending : undefined;
    const stillExists = this.selectedDeviceId !== undefined && options.some((o) => o.id === this.selectedDeviceId);
    this.selectedDeviceId = preferred ?? (stillExists ? this.selectedDeviceId : undefined);
    this.post({ type: "devices", devices: options, selectedId: this.selectedDeviceId });
    if (bannerMessage !== undefined) {
      this.deps.outputChannel.appendLine(`[live] ${bannerMessage}`);
    }
    this.ensureServeProcessForSelection();
  }

  private applyFallback(config: FleetestConfig, bannerMessage: string): void {
    const option = fallbackDeviceOption({ platform: config.platform, port: config.port, serial: config.serial });
    this.applyDevices([option], bannerMessage);
  }

  private selectedOption(): LiveDeviceOption | undefined {
    return this.devices.find((o) => o.id === this.selectedDeviceId);
  }

  /** グリッドビューのタイル(liveTabHost.ts の gridAction)から来た**他の機械のデバイス**を選択肢に加える。
   * 続く openDevice が一覧を取り直さずにこの id で選べるよう、this.devices にもすぐ入れる */
  registerRemoteDevice(option: LiveDeviceOption): void {
    this.remoteOptions.set(option.id, option);
    const index = this.devices.findIndex((device) => device.id === option.id);
    if (index >= 0) {
      this.devices[index] = option;
    } else {
      this.devices.push(option);
    }
  }

  /** グリッドビュー(1台表示)のツールバー・修飾キー操作(liveTabHost.ts の gridAction)。
   * serve は1本だけ(同じデバイスへ2本の常駐を立てない)—— 選択中のデバイスが id と違えば、
   * id へ切り替えてから撃つ。
   * 座標の操作は画面サイズ(lastScreen)が要るので、切り替え直後の観測が済むのを待ってから撃つ。 */
  async handleGridAction(id: string, action: GridLiveAction): Promise<void> {
    const switching = this.selectedDeviceId !== id;
    if (switching) {
      if (this.busy) {
        this.post({ type: "gridActionError", id, message: t("live.busyRetry") });
        return;
      }
      await this.openDevice(id);
      if (this.selectedDeviceId !== id) {
        this.post({ type: "gridActionError", id, message: t("live.deviceNotOpenable", { id }) });
        return;
      }
    }
    // 切り替えの中で観測が済んで画面サイズが揃っているなら「更新」を二重に撃たない
    if (switching && action.type === "refreshSnapshot" && this.lastScreen) {
      return;
    }
    if ((action.type === "tapPoint" || action.type === "doubleTapPoint" || action.type === "tracePoints"
      || action.type === "dragPoints" || action.type === "pressPoint") && !this.lastScreen) {
      // 上限は観測1回の応答待ち(sendServeCommand のタイムアウト)と同じ
      await this.waitForIdle(SERVE_REQUEST_TIMEOUT_MS);
      if (!this.lastScreen) {
        await this.refreshSnapshot();
      }
    } else {
      await this.waitForIdle(SERVE_REQUEST_TIMEOUT_MS);
    }
    // **撃つ直前に合図する**(gridLivePanel.js の枠の鮮度)。切り替え・待ちの間に届いた観測(開いたときの観測・
    // 整定の撮り直し)を、webview が「この操作の直接の結果」と取り違えないため。runGridAction は
    // 同期で runAction へ入り、最初の await より前に busy を立てるので、合図と操作の結果の間に別の観測は割り込まない
    this.post({ type: "gridActionStarted", id });
    this.runGridAction(action);
  }

  private async openDevice(id: string): Promise<void> {
    if (this.busy) {
      // 進行中の refreshDevices があれば、その applyDevices がこの id を優先選択する。
      this.pendingSelectId = id;
      return;
    }
    if (this.devices.some((device) => device.id === id)) {
      this.selectedDeviceId = id;
      this.post({ type: "devices", devices: this.devices, selectedId: id });
      this.ensureServeProcessForSelection();
    } else {
      this.pendingSelectId = id;
      await this.refreshDevices();
    }
    if (this.selectedDeviceId !== id) {
      // 開けなかった旨は呼び手(handleGridAction)が gridActionError で言う
      return;
    }
    const selected = this.devices.find((device) => device.id === id);
    // booted は切り替えの時点で requestOpenObservation が撃つ(ここで撃つと二重になる)
    if (selected?.state === "connected") {
      await this.refreshSnapshot();
    }
  }

  // ---- live serve(常駐プロセス)の起動・停止・再バインド ------------------------------------
  // ファイル冒頭のコメント参照(monitorProcessManager.ts の host-metrics プロセス管理パターンを踏襲)。

  /** 現在選択中のデバイスに serve プロセスをバインドする(未選択なら止める)。デバイス一覧の
   * 取得・切り替えのたびに呼ぶ(applyDevices 経由)。 */
  private ensureServeProcessForSelection(): void {
    const device = this.currentDeviceRef();
    if (!device) {
      if (this.serveDevice) {
        this.clearSnapshotCache();
      }
      this.serveDevice = undefined;
      this.stopServeProcess();
    } else {
      this.ensureServeProcess(device);
    }
  }

  /** device 向けの serve プロセスが既に起動していれば何もしない。そうでなければ
   * (未選択→選択・別デバイスへの切り替え・予期しない終了[giveUp 含む]のいずれでも)再バインドする。 */
  private ensureServeProcess(device: LiveDeviceRef): void {
    const bound = this.serveDevice;
    if (this.serveProcess && bound && sameLiveDeviceRef(bound, device)) {
      return;
    }
    const switched = !bound || !sameLiveDeviceRef(bound, device);
    if (switched) {
      this.clearSnapshotCache();
    }
    this.rebindServeProcess(device);
    if (switched) {
      this.requestOpenObservation();
    }
  }

  /** 直前のデバイスのスナップショット(画面サイズ・要素一覧)を捨てる。デバイスを切り替えた
   * のに残っていると、**タップ座標が前のデバイスの画面サイズで換算され**(px の Android →
   * pt の iOS で特に大きく外れる)、要素一覧の行タップは**新しいデバイスの木の同じ番号**を
   * 叩く(ref はスナップショットごとの採番なので、別の要素に当たっても誰も気付けない)。
   * webview 側も同時に捨てさせ、次のフレームで撮り直しを要求させる(clearSnapshot の doc)。 */
  private clearSnapshotCache(): void {
    this.lastScreen = undefined;
    this.lastElements = [];
    this.post({ type: "clearSnapshot" });
  }

  /**
   * 現在の serve(あれば)を止めて device 向けに起動し直す。明示的な再バインドなので直前の giveUp
   * (抑止対象は scheduleServeRestart の無人5秒後リトライのみ)は無視して仕切り直す。多重起動ガードは
   * デバイス連続切り替えでの stop/start 重複を防ぐ(ガード中は serveDevice 更新のみ行い、進行中の
   * 切り替え完了後は最新の serveDevice へ起動する)。
   */
  private rebindServeProcess(device: LiveDeviceRef): void {
    this.serveFailureStreak = 0;
    this.serveGaveUp = false;
    this.serveTimeoutKillStreak = 0;
    this.serveDevice = device;
    if (this.serveRestartPending) {
      return;
    }
    this.serveRestartPending = true;
    const proc = this.serveProcess;
    // 停止処理(SIGTERM→close)完了前に旧プロセスへの参照を消す: sendServeCommand は serveProcess
    // 未設定なら即座にエラーを返すため、切り替え中に送られたコマンドが停止中の旧プロセス
    // (旧デバイス宛)に届くことは無い。
    this.serveProcess = undefined;
    this.killServeProcess(proc);
    const epoch = this.serveStopEpoch;
    let proceeded = false;
    // startLatest は proc が無いとき setTimeout より前に同期で走る。const で後ろに宣言すると TDZ で投げる
    let timer: NodeJS.Timeout | undefined;
    const startLatest = (): void => {
      if (proceeded) {
        return;
      }
      proceeded = true;
      clearTimeout(timer);
      this.serveRestartPending = false;
      const target = this.serveDevice;
      if (target && epoch === this.serveStopEpoch) {
        this.startServeProcess(target);
      }
      // 起動できた場合もできなかった場合も待ち手を解放する(起動しなかった回を待たせ続けない)。
      this.wakeServeReadyWaiters();
    };
    if (!proc) {
      startLatest();
      return;
    }
    // close が来ない(defunct 等)と serveRestartPending が永久 true になり、以後の再バインドと
    // ライブ操作が全て止まる。monitorProcessManager の RESTART_CLOSE_TIMEOUT_MS と同じ安全弁
    timer = setTimeout(startLatest, SERVE_REBIND_CLOSE_TIMEOUT_MS);
    proc.once("close", startLatest);
  }

  /** 再バインド完了を待っている呼び出し手を全件起こす(startLatest の終端から1回だけ)。 */
  private wakeServeReadyWaiters(): void {
    if (this.serveReadyWaiters.length === 0) {
      return;
    }
    const waiters = this.serveReadyWaiters;
    this.serveReadyWaiters = [];
    for (const wake of waiters) {
      wake();
    }
  }

  /**
   * 再バインド中(serveRestartPending)なら、新しい serve が立つまで待たせる。デバイスを選んだ
   * 直後の snapshot/操作はこの窓に必ず入るため、待たずに serveUnavailableMessage() を返すと
   * 「常駐プロセスが起動していません。デバイスを選び直してください」が数秒だけ出て、その後
   * 何事もなく画面が出る = 利用者に対処のしようが無い誤報になる(実際にあった)。
   * 再バインド中でないとき(本当に居ない・諦めた)は待たず、そのまま即座に断る。
   */
  private awaitServeRebind(): Promise<void> {
    if (!this.serveRestartPending) {
      return Promise.resolve();
    }
    return new Promise((resolve) => {
      let settled = false;
      const wake = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(wake, SERVE_REBIND_WAIT_MS);
      this.serveReadyWaiters.push(wake);
    });
  }

  private startServeProcess(device: LiveDeviceRef): void {
    if (this.serveSuspendedForSweep) {
      return;
    }
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const config = this.deps.getConfig();
    const serveArgs = ["api", "live", "serve", ...buildDeviceArgs(device)];
    if (device.platform === "ios" && device.udid) {
      serveArgs.push("--udid", device.udid);
    }
    // 他の機械のデバイスは**向こうで** serve を起こす(そのデバイスを USB で握っているのはその機械。この Mac から
    // Wi-Fi で2本目のランナーを立てると1台に2本になり両方落ちる)。NDJSON は ssh の stdin/stdout を
    // そのまま通る(remote exec の到達確認は -n で stdin を読まない = RemoteSetupCommand.swift)
    const args = device.machine ? ["remote", "exec", device.machine, "--", ...serveArgs] : serveArgs;
    let proc: ServeProcess;
    try {
      proc = spawn(config.binaryPath, args, {
        cwd: this.deps.workspaceRoot,
        shell: false,
        env: childEnv(),
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      this.deps.outputChannel.appendLine(t("live.serveSpawnFailed", { error: String(error) }));
      return;
    }
    proc.stdin.on("error", () => undefined);

    this.stoppingServe = false;
    this.serveProcess = proc;
    this.serveStartedAt = Date.now();

    const stdoutParser = new NdjsonParser(
      (value) => this.handleServeEvent(value),
      (line) => this.deps.outputChannel.appendLine(`[live serve stdout] ${line}`),
    );
    const stderrParser = new NdjsonParser(
      (value) => this.deps.outputChannel.appendLine(`[live serve stderr] ${JSON.stringify(value)}`),
      (line) => this.deps.outputChannel.appendLine(`[live serve stderr] ${line}`),
    );
    proc.stdout.on("data", (chunk: Buffer) => stdoutParser.push(chunk));
    proc.stderr.on("data", (chunk: Buffer) => {
      checkForDyldLaunchFailure(chunk.toString("utf8"), this.deps.workspaceRoot);
      stderrParser.push(chunk);
    });

    proc.on("error", (error) => {
      this.deps.outputChannel.appendLine(t("live.serveProcessError", { error: error.message }));
    });

    proc.on("close", () => {
      stdoutParser.end();
      stderrParser.end();
      if (this.serveProcess === proc) {
        this.serveProcess = undefined;
      }
      this.failPendingServeRequest(serveClosedMessage());
      // 意図した停止(dispose/再バインド)かどうかはフラグだけで判定する(monitorProcessManager.ts と同じ理由)。
      const selfInitiated = this.stoppingServe;
      this.stoppingServe = false;
      if (selfInitiated) {
        return;
      }
      this.scheduleServeRestart();
    });
  }

  /**
   * serve プロセスの予期しない終了を受けて、5秒後に再起動するか諦めるかを決める
   * (monitorProcessManager.ts の scheduleHostMetricsRestart と同じロジック)。起動後10秒未満での
   * 異常終了が3回連続したら諦める(旧バイナリに `api live serve` が無い環境等で無限に再起動
   * ループしないための安全弁)。10秒以上動いてからの終了は正常運転とみなして連続回数をリセットする。
   */
  private scheduleServeRestart(): void {
    const elapsedMs = Date.now() - (this.serveStartedAt ?? Date.now());
    if (elapsedMs < 10000) {
      this.serveFailureStreak += 1;
    } else {
      this.serveFailureStreak = 0;
    }
    if (this.serveFailureStreak >= 3) {
      if (!this.serveGaveUp) {
        this.serveGaveUp = true;
        this.deps.outputChannel.appendLine(t("live.serveGiveUpEarlyExit"));
      }
      return;
    }
    this.serveRestartTimer = setTimeout(() => {
      this.serveRestartTimer = undefined;
      if (this.deps.isPanelActive() && this.serveDevice) {
        this.startServeProcess(this.serveDevice);
      }
    }, 5000);
  }

  /**
   * 「全て終了」の直前に呼ぶ。serve を止めて終了(close)まで待つ —— serve は終了時に自分のデバイスの印
   * (`.fleetest/mcp-<鍵>.lease`。Sources/fleetest/LiveDeviceLease.swift)を消すので、これで
   * 全掃討(`devices down` の sweepRefusal)がこの印で丸ごと断られなくなる。掴んだままだと
   * 「MCP session が駆動中」と名指しされて何も止まらない(実地)。
   * 他の機械のデバイス(remote exec 越しの serve)も同じに畳む: 掃討はその機械へも分散し、向こうの印は
   * 向こうの serve が stdin EOF で消す(こちらで待つのは手元の子の close まで)。
   * resumeServeAfterSweep が呼ばれるまで serve は起動しない。
   */
  async suspendServeForSweep(): Promise<void> {
    this.serveSuspendedForSweep = true;
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const proc = this.serveProcess;
    this.serveProcess = undefined;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    await new Promise<void>((resolve) => {
      let settled = false;
      const done = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(done, SERVE_SWEEP_STOP_WAIT_MS);
      proc.once("close", done);
      this.killServeProcess(proc);
    });
  }

  /** 「全て終了」が終わったら呼ぶ。起動の抑止を解く。serve は次のグリッド操作が立て直す
   * (runAction → ensureServeProcess。選んでいたデバイスが落ちた・ブリッジが消えた後の扱いもそちらに任せる)。 */
  resumeServeAfterSweep(): void {
    if (!this.serveSuspendedForSweep) {
      return;
    }
    this.serveSuspendedForSweep = false;
  }

  /** 実行中の serve プロセスがあれば止めて(this.serveProcess も即座に未設定に戻す)、参照を
   * 手放す(dispose/panel破棄から呼ぶ。デバイス切り替え中の再バインドは rebindServeProcess が
   * 個別に this.serveProcess を扱うため、こちらは呼ばない)。 */
  private stopServeProcess(): void {
    this.serveStopEpoch += 1;
    if (this.serveRestartTimer) {
      clearTimeout(this.serveRestartTimer);
      this.serveRestartTimer = undefined;
    }
    const proc = this.serveProcess;
    this.serveProcess = undefined;
    this.killServeProcess(proc);
  }

  /** proc(あれば)を SIGTERM(2秒後 SIGKILL)で止める(stdin EOF も送ってどちらでもクリーンに
   * 終了できるようにする)。this.serveProcess の書き換えは行わない(呼び出し元の責務。
   * rebindServeProcess/stopServeProcess のどちらも、旧プロセスへの参照を手放してから呼ぶ)。 */
  private killServeProcess(proc: ServeProcess | undefined): void {
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.stoppingServe = true;
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** 応答タイムアウト時に、生きたまま無応答になった(wedge した)serve を止める。serve 側は
   * SIGTERM を SIG_IGN で無視するため、実際の停止は stdin EOF(serve の ResidentProcessGuard による
   * 2秒強制終了)か2秒後の SIGKILL による。killServeProcess とは違い stoppingServe を立てないので、
   * close ハンドラが scheduleServeRestart で現デバイスへ自動 respawn する(=wedge からの自動復帰)。
   * 連続 MAX_CONSECUTIVE_TIMEOUT_KILLS 回で諦め、再起動させず serveUnavailableMessage() を出す。 */
  private restartWedgedServe(proc: ServeProcess): void {
    if (this.serveProcess !== proc || proc.exitCode !== null || proc.signalCode !== null) {
      return;
    }
    this.serveTimeoutKillStreak += 1;
    if (this.serveTimeoutKillStreak >= MAX_CONSECUTIVE_TIMEOUT_KILLS) {
      this.serveGaveUp = true;
      this.stoppingServe = true; // close ハンドラに自己終了とみなさせ、再起動を抑止する
      this.deps.outputChannel.appendLine(t("live.serveGiveUpTimeout"));
      this.postActionError(serveUnavailableMessage());
    } else {
      this.deps.outputChannel.appendLine(
        t("live.serveTimeoutRestart", { seconds: SERVE_REQUEST_TIMEOUT_MS / 1000 }),
      );
    }
    proc.stdin.end();
    proc.kill("SIGTERM");
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        proc.kill("SIGKILL");
      }
    }, 2000);
  }

  /** serve の stdout から届いた NDJSON 1行を pendingServeRequest に配る。actionResult は
   * 保持だけして、続く snapshot イベントで resolve する(ファイル冒頭プロトコル参照)。 */
  private handleServeEvent(value: unknown): void {
    const event = parseLiveServeEvent(value);
    if (!event) {
      this.deps.outputChannel.appendLine(t("live.serveUnknownLine", { value: JSON.stringify(value) }));
      return;
    }
    const pending = this.pendingServeRequest;
    if (!pending) {
      this.deps.outputChannel.appendLine(t("live.serveNoPendingRequest", { kind: event.kind }));
      return;
    }
    if (event.kind === "actionResult") {
      pending.action = event.result;
      if (pending.cmd === "gesture") {
        this.post({ type: "gestureActionDone", ok: event.result.ok });
      }
      return;
    }
    this.settlePendingServeRequest({ action: pending.action, snapshot: event.result });
  }

  private settlePendingServeRequest(outcome: PendingServeOutcome): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    this.pendingServeRequest = undefined;
    clearTimeout(pending.timeout);
    pending.resolve(outcome);
  }

  /** 応答を受け取れなくなった(プロセス終了・タイムアウト)ときに、待たせている呼び出し元を
   * エラー結果で解放する(busy 状態のまま固まらないようにする安全弁)。 */
  private failPendingServeRequest(message: string): void {
    const pending = this.pendingServeRequest;
    if (!pending) {
      return;
    }
    // **bridgeStarting は常に false**(この経路は自動起動とは無関係の host 側の障害
    // [プロセス終了・応答タイムアウト]なので、デバイスが起動中かどうかは分からない・関係ない)
    this.settlePendingServeRequest({
      action: pending.expectsAction ? { ok: false, error: message, bridgeStarting: false, dsl: null } : undefined,
      snapshot: { ok: false, error: message, bridgeStarting: false },
    });
  }

  /** serve への送信を直列化するチェーン内で run を実行する(観測とユーザー操作の pending
   * スロット競合を防ぐ)。チェーン自体は常に成功状態を維持する(run の失敗を次回以降へ持ち越さない)。 */
  private enqueueServeSend<T>(run: () => Promise<T>): Promise<T> {
    const result = this.serveSendChain.then(run, run);
    this.serveSendChain = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  /** command を serve の stdin へ送り、対応する応答(actionResult[refresh以外]+snapshot)が
   * 揃うまで待つ。再バインド中なら新しい serve が立つのを待ち(awaitServeRebind)、それでも
   * 起動していなければ CLI を呼ばずに即座にエラー結果を返す。
   * enqueueServeSend で直列化する(実体は sendServeCommandNow)。 */
  private sendServeCommand(command: LiveServeCommand): Promise<ServeRequestOutcome> {
    return this.enqueueServeSend(() => this.sendServeCommandNow(command));
  }

  private async sendServeCommandNow(command: LiveServeCommand): Promise<ServeRequestOutcome> {
    await this.awaitServeRebind();
    const proc = this.serveProcess;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null) {
      const message = serveUnavailableMessage();
      // serve プロセス自体が居ない(bridgeStarting とは無関係の host 側の障害)
      return Promise.resolve({
        action: command.cmd === "refresh" ? undefined : { ok: false, error: message, bridgeStarting: false, dsl: null },
        snapshot: { ok: false, error: message, bridgeStarting: false },
      });
    }
    return new Promise((resolve) => {
      // 正当に長く占有しうる操作(軌跡・press/drag/pinch・fold)は応答待ちの上限に
      // その分を足す(serve 側の command watchdog も同じだけ延びる)
      const timeout = setTimeout(() => {
        this.failPendingServeRequest(serveTimeoutMessage());
        this.restartWedgedServe(proc);
      }, SERVE_REQUEST_TIMEOUT_MS + serveCommandAllowanceMs(command));
      this.pendingServeRequest = {
        expectsAction: command.cmd !== "refresh",
        cmd: command.cmd,
        action: undefined,
        resolve: (outcome) =>
          resolve({
            action: outcome.action,
            snapshot: outcome.snapshot ?? {
              ok: false, error: t("live.internalErrorSnapshotMissing"), bridgeStarting: false,
            },
          }),
        timeout,
      };
      proc.stdin.write(serializeLiveServeCommand(command));
    });
  }

  // ---- snapshot -------------------------------------------------------------------

  private applySnapshotResult(result: LiveSnapshot | LiveErrorResult): void {
    if (!result.ok) {
      // 自動起動が進行中の失敗はエラーとして出さない(起動が終わっていればこの回は自動で reachable になる
      // = 撃ち直しはしない)
      if (result.bridgeStarting) {
        return;
      }
      this.postActionError(result.error);
      return;
    }
    this.handleConnectionOk();
    this.lastScreen = result.screen;
    this.lastElements = result.elements;
    this.post(toSnapshotMessage(result));
  }

  private async fetchSnapshot(): Promise<void> {
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return;
    }
    this.ensureServeProcess(device);
    const { snapshot } = await this.sendServeCommand({ cmd: "refresh" });
    this.applySnapshotResult(snapshot);
  }

  private async refreshSnapshot(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.setBusy(true, true);
    try {
      await this.fetchSnapshot();
    } catch (error) {
      this.postActionError(t("live.snapshotFailed", { error: errorMessage(error) }));
    } finally {
      this.setBusy(false);
    }
  }

  // ---- tap/type/drag/press/appSwitcher/home ---------------------------

  /** serve へ1コマンド送って結果を反映する。成功時は serve が続けて返す観測イベント(操作後の
   * 追加待ちなしで届く。ブリッジ応答=UI整定済みのため)をそのまま画面へ反映する。失敗時は
   * 画面を再取得しない(観測イベント自体は届くが反映せず、直近のエラーを表示する)。
   * 戻り値は操作と直後の観測が成功したか。 */
  private async runAction(
    command: LiveServeCommand,
    options?: { readonly logLabel?: string },
  ): Promise<boolean> {
    if (this.busy) {
      // **黙って落とさない** —— 画面タップ・ツールバーは busy 中 webview 側で止まるので、
      // ここに来るのは host 内部の呼び出しだけ
      this.postActionError(t("live.busyRetry"));
      return false;
    }
    const device = this.currentDeviceRef();
    if (!device) {
      this.postActionError(t("live.noDeviceSelected"));
      return false;
    }
    this.setBusy(true);
    // 操作中に選択が変わっても、行は操作を撃ったデバイスのものとして届ける
    const loggedDeviceId = this.selectedDeviceId;
    try {
      this.ensureServeProcess(device);
      const { action, snapshot } = await this.sendServeCommand(command);
      if (action && !action.ok) {
        // 自動起動が進行中の失敗はエラーとして出さない —— 撃ち直しはしない
        // (利用者が画面の復帰を見てから自分でやり直す。interruption-no-resend-policy と同じ理由)
        if (action.bridgeStarting) {
          this.postActionError(t("live.bridgeStartingActionNotice"), true);
        } else {
          this.postActionError(action.error);
        }
        if (options?.logLabel) {
          this.postOperationLog(options.logLabel, false, action.dsl ?? undefined, loggedDeviceId);
        }
        return false;
      }
      // **利用者の操作が通ったら前のエラーは消す** —— 自動で消えるのは接続系の3文言だけ
      // (isConnectionClassMessage)なので、ブリッジ接続拒否のように serve が返した文言は
      // 状況が直っても残り続ける。
      this.post({ type: "actionError", message: "" });
      this.connectionBannerShown = false;
      if (options?.logLabel) {
        this.postOperationLog(options.logLabel, true, action?.dsl ?? undefined, loggedDeviceId);
      }
      this.applySnapshotResult(snapshot);
      return snapshot.ok;
    } catch (error) {
      this.postActionError(t("live.actionFailed", { error: errorMessage(error) }));
      return false;
    } finally {
      this.setBusy(false);
    }
  }

  /** 画像上の点タップ専用。タップ成功後、当たった要素がテキスト入力欄なら webview の
   * 「入力するテキスト」欄へフォーカスを移す(デバイス側の入力欄フォーカスに続けてすぐ入力できる)。
   * hit は tapPoint 側で算出済みの当たり要素。 */
  private async runTapAtPoint(
    command: LiveServeCommand,
    hit: LiveElement | undefined,
    logLabel: string,
  ): Promise<void> {
    const ok = await this.runAction(command, { logLabel });
    if (ok && hit && isTextInputElement(hit)) {
      this.post({ type: "focusTypeInput" });
    }
  }

  // ---- グリッドビューからの操作 -----------------------------------------------------

  private runGridAction(message: GridLiveAction): void {
    // **観測の最中に届いた画面の操作は、観測が終わってから撃つ**(断らない)。画面の撮り直しは操作の結果のたびに
    // 走る(webview の整定の撮り直し・グリッドビューの絵の変化)ので、その窓に押したタップが黙って消えていた
    // (実地: 画面が止まっているのにタップが空振りした)。まだ撃っていない操作を後で撃つだけ = 撃ち直しではない
    if (this.busy && this.busyObserving && OBSERVATION_DEFERRABLE_ACTIONS.has(message.type)) {
      void this.waitForIdle(SERVE_REQUEST_TIMEOUT_MS).then(() => this.runGridAction(message));
      return;
    }
    switch (message.type) {
      case "refreshSnapshot":
        void this.refreshSnapshot();
        break;
      case "tapPoint": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        const tapHit = hitTestElement(point, this.lastElements);
        const tapLabel = tapHit
          ? t("live.opLabel.tap", { target: describeElementShort(tapHit) })
          : t("live.opLabel.tap", { target: `(${Math.round(point.x)}, ${Math.round(point.y)})` });
        void this.runTapAtPoint({ cmd: "tap", x: point.x, y: point.y }, tapHit, tapLabel);
        break;
      }
      case "dragPoints": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const display = { width: message.displayWidth, height: message.displayHeight };
        const from = pointFromClick({ x: message.fromX, y: message.fromY }, display, this.lastScreen);
        const to = pointFromClick({ x: message.toX, y: message.toY }, display, this.lastScreen);
        // 実測時間をそのまま実機に流すと serve タイムアウト(20秒)に触れるためクランプする
        const pressSeconds = Math.min(Math.max(message.pressMs / 1000, 0), 3);
        const durationSeconds = Math.min(Math.max(message.dragMs / 1000, 0.05), 8);
        const dx = message.toX - message.fromX;
        const dy = message.toY - message.fromY;
        const direction: "up" | "down" | "left" | "right" =
          Math.abs(dx) >= Math.abs(dy) ? (dx >= 0 ? "right" : "left") : dy < 0 ? "up" : "down";
        const swipeLabel = t("live.opLabel.swipe", { direction: swipeDirectionLabel(direction) });
        void this.runAction(
          {
            cmd: "drag",
            fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
            press: pressSeconds, duration: durationSeconds,
          },
          { logLabel: swipeLabel },
        );
        break;
      }
      case "tracePoints": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const screen = this.lastScreen;
        const display = { width: message.displayWidth, height: message.displayHeight };
        // t は webview ではミリ秒(pointerdown からの経過)。GestureRequest/ft_gesture は秒なので
        // ここで一度だけ変換する(座標は既存のドラッグと同じ pointFromClick)
        const devicePoints = message.points.map((p) => ({
          ...pointFromClick({ x: p.x, y: p.y }, display, screen),
          t: p.t / 1000,
        }));
        const totalSeconds = devicePoints[devicePoints.length - 1]?.t ?? 0;
        // **時間を縮めない**(利用者の決定: なぞった時間どおりに再生する)。既定上限を超えたら
        // この1回だけ maxGestureSeconds で上げ、絶対上限を超えるものは送らずに断る
        const cap = gestureCapFor(totalSeconds);
        if (cap === "tooLong") {
          this.postActionError(t("live.traceTooLong", {
            seconds: Math.round(totalSeconds), max: GESTURE_SECONDS_CEILING,
          }));
          break;
        }
        const fingers = [{ points: devicePoints }];
        // 送った軌跡の要約を残す(出力パネル)。点が飛んだ報告(軌跡が絵の左上を経由した)を、拡張の側で混ざったのか
        // デバイスの側で起きたのかに分けるため —— 範囲の最小が 0 で跳びが大きければ、送った点列に混ざっていた
        this.deps.outputChannel.appendLine(`[live] trace: ${traceSummary(message.points, display)}`);
        void this.runAction(
          cap === undefined ? { cmd: "gesture", fingers } : { cmd: "gesture", fingers, maxGestureSeconds: cap },
          { logLabel: t("live.opLabel.trace") },
        );
        break;
      }
      case "pressPoint": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        // 実測ホールド時間をそのまま流す(serve タイムアウト対策で 0.5〜5 秒にクランプ)
        const duration = Math.min(Math.max(message.holdMs / 1000, 0.5), 5);
        const pressHit = hitTestElement(point, this.lastElements);
        const pressLabel = pressHit
          ? t("live.opLabel.press", { target: describeElementShort(pressHit) })
          : t("live.opLabel.press", { target: `(${Math.round(point.x)}, ${Math.round(point.y)})` });
        void this.runAction({ cmd: "press", x: point.x, y: point.y, duration }, { logLabel: pressLabel });
        break;
      }
      case "doubleTapPoint": {
        if (!this.lastScreen) {
          this.postActionError(t("live.refreshFirst"));
          break;
        }
        const point = pointFromClick(
          { x: message.clickX, y: message.clickY },
          { width: message.displayWidth, height: message.displayHeight },
          this.lastScreen,
        );
        // **座標へ畳んでから送る**のは ref の名前空間がブリッジごとに違うため(AppDriver の注記)
        const hit = hitTestElement(point, this.lastElements);
        const label = hit
          ? t("live.opLabel.doubleTap", { target: describeElementShort(hit) })
          : t("live.opLabel.doubleTap", { target: `(${Math.round(point.x)}, ${Math.round(point.y)})` });
        void this.runAction({ cmd: "doubleTap", x: point.x, y: point.y }, { logLabel: label });
        break;
      }
      case "pinch": {
        // 画面全体が対象(要素指定はパネルからは出さない — 対象の指し方が経路で違い、
        // 人が選べる形にすると誤解を招く。DSL 側は pinchOut("#map") が書ける)
        const zoomIn = message.zoomIn;
        void this.runAction(
          { cmd: "pinch", scale: zoomIn ? 2 : 0.5, duration: 0.5 },
          { logLabel: t(zoomIn ? "live.opLabel.pinchOut" : "live.opLabel.pinchIn") },
        );
        break;
      }
      case "typeText": {
        if (message.text.trim().length === 0) {
          this.postActionError(t("live.typeTextEmpty"));
          break;
        }
        // **入力先はデバイス側でフォーカスしている要素**(ref は付けない。理由は GridLiveAction の typeText の doc)
        void this.runAction(
          { cmd: "type", text: message.text },
          { logLabel: t("live.opLabel.type", { text: truncateOperationLabelText(message.text) }) },
        );
        break;
      }
      case "home":
        void this.runAction({ cmd: "home" }, { logLabel: t("live.opLabel.home") });
        break;
      case "fold":
        void this.runAction(
          { cmd: "fold", state: message.state },
          { logLabel: t(message.state === "fold" ? "live.opLabel.fold" : "live.opLabel.unfold") },
        );
        break;
      case "appSwitcher":
        void this.runAction({ cmd: "appSwitcher" }, { logLabel: t("live.opLabel.appSwitcher") });
        break;
    }
  }
}
