// actionTachometerModel.ts
// run ボード見出しの「アクション/分」メーターの純粋ロジック(vscode 非依存)。**表示文字列は置かない** ——
// このファイルは webview バンドルにも入る(runBoard.js が直接 import。runBoardModel.ts と同じ形)ので
// i18n/index.ts を import できない。文言は呼び手が t() で作る。
//
// 入力: monitorRuns イベントの runs[].actions(その run がデバイスへ送った操作の累計。増えるだけ)。
// 時刻は呼び手が引数で渡す(テスト可能にするため Date.now() を直読みしない)。

import { LOCAL_MACHINE_KEY } from "./runBoardModel";

/** 表示値の窓(ms)。「アクション/分」という単位の定義そのもの(直近 60 秒に増えた数)。 */
export const RATE_WINDOW_MS = 60_000;
/** メーターの段数(見出しの残り幅に引き伸ばして描く)。 */
export const METER_SEGMENTS = 40;
/** メーター(LED バー)の窓(ms)。直近 3 秒に増えた数 ÷ 3 = 1 秒あたり(ユーザー決定)。数値・推移の 60 秒窓とは別 */
export const METER_WINDOW_MS = 3_000;
/** 1目盛りのアクション/秒(ユーザー決定)。METER_SEGMENTS 段(40/秒)を超えたら段を右へ足す(右端に張り付かせない。ユーザー決定)。 */
export const ACTIONS_PER_SECOND_PER_SEGMENT = 1;
/** サンプルの保持(ms)。いちばん長い窓(RATE_WINDOW_MS)の前端の値を引けるぶん。 */
const SAMPLE_RETENTION_MS = RATE_WINDOW_MS;

/** バーの慣性の時定数(ms)。元の更新はモニターの周期(約 2 秒)ごとなので、その半分にすると次の更新までに
 * 約 86% 追いつく = 段々に跳ねず、遅れも 1 周期に収まる(車のタコメーターの針のように連続的に動かす。ユーザー決定) */
export const METER_TIME_CONSTANT_MS = 1_000;

/** 表示中の値を目標へ dtMs ぶん近づける(指数的な追従)。dtMs ≤ 0 なら動かさない。 */
export function easeToward(shown: number, target: number, dtMs: number): number {
  if (!(dtMs > 0)) {
    return shown;
  }
  return shown + (target - shown) * (1 - Math.exp(-dtMs / METER_TIME_CONSTANT_MS));
}

/** index 段目の明るさ(0…1)。表示値が段の途中ならその割合だけ点ける = バーが連続的に伸び縮みする。 */
export function segmentLevel(shownPerSecond: number, index: number): number {
  const level = shownPerSecond / ACTIONS_PER_SECOND_PER_SEGMENT - index;
  return Math.min(1, Math.max(0, level));
}

export type SegmentTier = "low" | "mid" | "high";

/** 下から 7/12 までが低・10/12 までが中・残りが高(段数に依らない割合)。右へ足した段(index ≥ METER_SEGMENTS)は高。 */
export function segmentTier(index: number): SegmentTier {
  const f = index / METER_SEGMENTS;
  return f < 7 / 12 ? "low" : f < 10 / 12 ? "mid" : "high";
}

/** 点灯する段数(上限なし)。引数はアクション/秒(`meterPerSecond`)。1段 = ACTIONS_PER_SECOND_PER_SEGMENT。 */
export function litSegments(perSecond: number): number {
  if (!(perSecond > 0)) {
    return 0;
  }
  return Math.round(perSecond / ACTIONS_PER_SECOND_PER_SEGMENT);
}

/** 描く段数。既定の METER_SEGMENTS 段に収まらない値なら、途中の段まで含めて右へ足した段数(下がれば戻る)。 */
export function segmentCount(shownPerSecond: number): number {
  const needed = shownPerSecond > 0 ? Math.ceil(shownPerSecond / ACTIONS_PER_SECOND_PER_SEGMENT) : 0;
  return Math.max(METER_SEGMENTS, needed);
}

export interface ActionTachometerEvent {
  /** undefined = 手元。 */
  readonly machine?: string;
  readonly observed: boolean;
  readonly runs: readonly { readonly pid: number; readonly runID?: string; readonly actions: number }[];
}

export interface MachineRate {
  /** LOCAL_MACHINE_KEY("")= 手元。表示語への変換は呼び手。 */
  readonly machine: string;
  /** 直近 60 秒に増えた数(推移と同じ計算)。 */
  readonly value: number;
  /** メーターと同じ窓(直近 METER_WINDOW_MS)の 1 分あたり。表示する数値はこちら(バーと連動させる。ユーザー決定)。 */
  readonly meterPerMinute: number;
}

export interface ActionTachometerSnapshot {
  /** 直近 60 秒に増えた数(推移の点と同じ計算。表示する数値ではない = 数値はバーと連動する meterPerSecond × 60)。 */
  readonly value: number;
  /** メーターの値: 直近 METER_WINDOW_MS に増えた数を秒に割った 1 秒あたり。 */
  readonly meterPerSecond: number;
  /** 機械別の同じ計算(手元を先頭、残りは名前順)。 */
  readonly byMachine: readonly MachineRate[];
  /** observed:false の機械(寄与は凍結中)。 */
  readonly unobservedMachines: readonly string[];
  /** 観測を始めてからの秒。60 未満の間は value が少なめに出る(割り戻しはしない)。 */
  readonly observedSeconds: number;
}

interface RunCounter {
  readonly machine: string;
  /** 寄与の累計(初見の基準からの増分。run が消えても残す)。 */
  contribution: number;
  /** 最後に見た actions。 */
  last: number;
}

interface Sample {
  readonly t: number;
  readonly total: number;
  readonly byMachine: ReadonlyMap<string, number>;
}

export class ActionTachometer {
  private readonly runs = new Map<string, RunCounter>();
  /** 機械 → 観測できているか。 */
  private readonly observed = new Map<string, boolean>();
  /** 観測が途切れた機械(次に観測できたとき基準を取り直す)。 */
  private readonly needsRebase = new Set<string>();
  private samples: Sample[] = [];
  private startMs: number | undefined;

  /** monitorRuns イベント1件を畳み、サンプルを積む。 */
  apply(event: ActionTachometerEvent, nowMs: number): void {
    const machine = event.machine ?? LOCAL_MACHINE_KEY;
    if (!event.observed) {
      this.observed.set(machine, false);
      this.needsRebase.add(machine);
    } else {
      const rebase = this.needsRebase.delete(machine);
      this.observed.set(machine, true);
      for (const run of event.runs) {
        const key = `${machine}#${run.runID ?? run.pid}`;
        const counter = this.runs.get(key);
        if (!counter) {
          this.runs.set(key, { machine, contribution: 0, last: run.actions });
        } else {
          if (!rebase) {
            counter.contribution += Math.max(0, run.actions - counter.last);
          }
          counter.last = run.actions;
        }
      }
    }
    this.tick(nowMs);
  }

  /** 観測が途切れた扱いにする(monitor プロセスの再起動。間の増分は数えない)。 */
  markAllUnobserved(): void {
    for (const machine of this.observed.keys()) {
      this.observed.set(machine, false);
      this.needsRebase.add(machine);
    }
  }

  /** 時計のたび(1 秒ごと)と apply のたびにサンプルを積む。 */
  tick(nowMs: number): void {
    const byMachine = new Map<string, number>();
    let total = 0;
    for (const counter of this.runs.values()) {
      total += counter.contribution;
      byMachine.set(counter.machine, (byMachine.get(counter.machine) ?? 0) + counter.contribution);
    }
    this.startMs ??= nowMs;
    this.samples.push({ t: nowMs, total, byMachine });
    const cutoff = nowMs - SAMPLE_RETENTION_MS;
    let drop = 0;
    while (drop + 1 < this.samples.length && this.samples[drop + 1]!.t <= cutoff) {
      drop += 1;
    }
    if (drop > 0) {
      this.samples = this.samples.slice(drop);
    }
  }

  /** t 以前で最新のサンプル。無ければ最古。呼び手は samples が空でないことを保証する(snapshot が先に tick する)。 */
  private sampleAt(t: number): Sample {
    let found = this.samples[0]!;
    for (const s of this.samples) {
      if (s.t <= t) {
        found = s;
      } else {
        break;
      }
    }
    return found;
  }

  /** t までの windowMs に増えた数。 */
  private rateAt(t: number, pick: (s: Sample) => number, windowMs = RATE_WINDOW_MS): number {
    const newest = this.sampleAt(t);
    const older = this.sampleAt(t - windowMs);
    return Math.max(0, pick(newest) - pick(older));
  }

  snapshot(nowMs: number): ActionTachometerSnapshot {
    if (this.samples.length === 0) {
      this.tick(nowMs);
    }
    const totalOf = (s: Sample) => s.total;
    const value = this.rateAt(nowMs, totalOf);
    const meterPerSecond = this.rateAt(nowMs, totalOf, METER_WINDOW_MS) / (METER_WINDOW_MS / 1000);

    const machines = new Set<string>(this.samples[this.samples.length - 1]!.byMachine.keys());
    const byMachine = [...machines]
      .map((machine) => ({
        machine,
        value: this.rateAt(nowMs, (s) => s.byMachine.get(machine) ?? 0),
        meterPerMinute: this.rateAt(nowMs, (s) => s.byMachine.get(machine) ?? 0, METER_WINDOW_MS)
          * (60_000 / METER_WINDOW_MS),
      }))
      .sort((a, b) => (a.machine === b.machine ? 0
        : a.machine === LOCAL_MACHINE_KEY ? -1
        : b.machine === LOCAL_MACHINE_KEY ? 1
        : a.machine < b.machine ? -1 : 1));

    const unobservedMachines = [...this.observed.entries()]
      .filter(([, ok]) => !ok)
      .map(([machine]) => machine)
      .sort();

    const start = this.startMs ?? nowMs;

    return {
      value,
      meterPerSecond,
      byMachine,
      unobservedMachines,
      observedSeconds: Math.max(0, Math.floor((nowMs - start) / 1000)),
    };
  }
}
