// グリッドビューの操作(gridLiveControls.js)と枠の整定(gridLivePanel.js)が共有する定数。
// **何も import しない** —— gridLivePanel.js は deviceTiles.js / laneLog.js を import できない(循環の評価順が変わり、
// 別モジュールの初期化前の値を踏む)ので、共有の値はここだけに置く。

// 押下→ほぼ動かさず離す=タップ、動かして離す=ドラッグ(スワイプ)の境[px]。
export const DRAG_MIN_PX = 5;

// 軌跡の再生時間の絶対上限[ms]。liveModel.ts の GESTURE_SECONDS_CEILING(= BridgeAPI.gestureSecondsCeiling)と同値。
// なぞっている最中に超えた時点で中止して言う(離すまで気付けないと操作が無駄になる)。host の gestureCapFor も同じ上限で断る。
export const TRACE_MAX_MS = 60000;

// 修飾キー(Command / Option)を押してから表示灯の説明のツールチップを出すまで[ms](ユーザー指定)。
// ショートカット(⌘C・⌘⇧P 等)で一瞬押しただけのときに出さないための待ち。表示灯そのものは押した瞬間に点ける。
export const HELD_TIP_DELAY_MS = 800;

// 動かさずに押し続けて長押しとみなす時間[ms]。
export const LONG_PRESS_MS = 500;

// 画面が動いて止まったら一度だけ木を撮り直すまでの待ち[ms]。操作の応答(絵と木)は操作直後の1枚なので、遷移の途中や
// アプリが遅れて出すもの(システムアラート等)を捉えられない。遷移の完了は待たず、あとから撮り直して差し替える。
// 値: 既定 12fps の配信で数フレーム分の空白を「止まった」と見なす長さ。短くするとアニメーションの途中で撃ち、
// 長くすると追随が遅れる。尽きたとき: 画面が動かないまま内容だけ変わる場合は追随しない(「更新」で撮り直す)。
export const SETTLE_REFRESH_MS = 700;

// 枠の整定を待つ上限[ms]。ループするアニメーションの画面は何秒待っても静まらないので必ず打ち切る。
// DSL の整定(StepExecutor+Settle.swift)が減速中に限って回す絶対上限(基本予算の 4 倍)を借りる。
// 尽きたとき: 打ち切って最新の木で描く(動いている画面の枠を出さないより、止まらない画面で永久に出ないほうが害が大きい)。
export const BOXES_SETTLE_CAP_MS = SETTLE_REFRESH_MS * 4;
