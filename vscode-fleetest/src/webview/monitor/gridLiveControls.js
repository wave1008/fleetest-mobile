// グリッドビュー(1台だけ選択したときの拡大表示)のライブ操作: ツールバー(ホーム・タスク切替・拡大・縮小・
// 折りたたみ機なら折りたたむ・開く)と
// 画面の操作(クリック = タップ / Command+クリック = ダブルタップ / 500ms 以上ホールド = 長押し /
// ドラッグ = スワイプ / Option+ドラッグ = 軌跡)。送り先は host の
// MonitorLiveController.handleGridAction(serve は1本。選択中のデバイスが違えば切り替える)。
// 契約: monitorWebviewMessages.ts の gridLiveAction / liveModel.ts の GridLiveAction・gridActionError。
// ツールバーの DOM は monitorHtml.ts(#grid-live-controls。文言は host 側 t() 済み)が持ち、ここで
// 1台表示の .lane-pair の中、拡大表示の右隣へ縦のカラムとして移す(laneLog.js の updateLaneVisibility が
// syncGridLiveControls を呼ぶ)。
// 画面(絵)の上のダブルクリックは2回のタップで、「このデバイスのみ選択」の切り替えは絵の外側だけ
// (laneLog.js が isGridLiveScreenTarget で除く)。
// 要素一覧・枠・入力するテキスト・操作記録のパネルは gridLivePanel.js(ここから postAction を渡す)。
// **テスト実行中でも操作を止めない**(ユーザー決定: 介入は利用者の自己責任)。run が使用中のデバイスへの操作は
// serve が台帳へ残し、そのシナリオの結果に「人の操作」として載る(HumanOperationLedger)。

import { t } from '../i18n.js';
import { vscode } from './vscodeApi.js';
import { firstMoveT, thinTracePoints, tracePrefix } from './traceThinning.js';
import { setHoverTip, setHeldTip } from './hoverTip.js';
import { exitSingleSelection, liveRemoteTargetFor, onMirrorFrame, showMirrorStill } from './deviceTiles.js';
import { DRAG_MIN_PX, HELD_TIP_DELAY_MS, LONG_PRESS_MS, TRACE_MAX_MS } from './liveConstants.js';
import { isDeviceRunning, relayoutPreviewsForResize } from './laneLog.js';
import { bindFoldButtons } from './foldButtons.js';
import { applyGridLivePanelMessage, initGridLivePanel, noteMirrorFrame, noteScreenAction, syncGridLivePanel } from './gridLivePanel.js';

const parking = document.getElementById('grid-live-parking');
const controls = document.getElementById('grid-live-controls');
const errorEl = document.getElementById('grid-live-error');
const traceIndicator = document.getElementById('grid-live-trace-indicator');
const doubleTapIndicator = document.getElementById('grid-live-doubletap-indicator');
// 「戻る」は選択を変えるだけでデバイスを触らないので busy の対象にしない
const buttons = [...controls.querySelectorAll('button')].filter((button) => button.id !== 'grid-live-btn-back');

const svgNS = 'http://www.w3.org/2000/svg';
const dragOverlay = document.createElementNS(svgNS, 'svg');
dragOverlay.setAttribute('class', 'grid-live-drag-overlay');
dragOverlay.setAttribute('aria-hidden', 'true');
const dragTrace = document.createElementNS(svgNS, 'polyline');
// 離した後の再生中だけ使う「操作が済んだ部分」(なぞった線 dragTrace を薄くし、こちらを太く重ねる)
const dragTraceDone = document.createElementNS(svgNS, 'polyline');
dragTraceDone.setAttribute('class', 'done');
const dragStartDot = document.createElementNS(svgNS, 'circle');
dragStartDot.setAttribute('r', '6');
const dragLine = document.createElementNS(svgNS, 'line');
// 押したまま動かさずに LONG_PRESS_MS を過ぎた印(.long-press)。デバイスは止まっていた時間ごと再生するので長押しになる
// (iOS のマップはピンを立て、続けて動かしてもパンしない)。意図しない長押しに、離す前に気付かせる
const longPressLabel = document.createElementNS(svgNS, 'text');
longPressLabel.setAttribute('class', 'long-press-label');
dragOverlay.append(dragLine, dragTrace, dragTraceDone, dragStartDot, longPressLabel);

// 操作の対象(1台表示のデバイス)。1台表示でない間は null
let target = null;
// host の serve が今つないでいるデバイス(host の devices.selectedId)。actionError はこれが target と
// 一致するときだけ出す(別のデバイスを操作した失敗をここに出さない)
let liveSelectedId = null;
let busy = false;
// busy の原因が画面を変えない観測か(host の busy.observing)。この間の画面の操作・ボタンは受け付ける
// (host が観測の終わりを待って撃つ)。捨てると、撮り直しの窓に押したタップが黙って空振りしていた
let busyObserving = false;
function operationBlocked() {
  return busy && !busyObserving;
}
let dragStart = null;
// 実行中に押されて送らなかった旨を出している(busy が解けたら消す)
let blockedNoticeShown = false;
function applyButtonState() {
  for (const button of buttons) { button.disabled = operationBlocked(); }
}

// 拡大表示の絵の描き替わりをパネルへ渡す購読(gridLivePanel.js の waitingForImage)。**読み込み時に購読しない** ——
// このモジュールは deviceTiles.js の読み込みの途中で評価される(deviceTiles → laneLog → ここ)ので、その時点では
// 購読者の集合がまだ無い。最初の1台表示(実行時)で張る
let mirrorFrameSubscribed = false;

/** id: 1台表示のデバイス(1台表示でなければ null)。previewEl: その拡大表示の .lane-preview */
export function syncGridLiveControls(id, previewEl) {
  if (!mirrorFrameSubscribed && id !== null) {
    mirrorFrameSubscribed = true;
    onMirrorFrame((deviceId) => {
      noteMirrorFrame(deviceId);
      noteTracePicture(deviceId);
    });
  }
  if (target && (target.id !== id || target.previewEl !== previewEl)) {
    releaseTraceOverlay();
    cancelDrag();
    target.previewEl.removeEventListener('pointerdown', handlePointerDown);
    parking.appendChild(controls);
    dragOverlay.remove();
    target = null;
    // 置き場へ戻した表示灯の位置に、押している間のツールチップを残さない
    cancelHeldTips();
    showError('');
    refreshFoldButtons();
  }
  if (id === null || !previewEl) {
    syncGridLivePanel(null, null);
    return;
  }
  if (!target) {
    target = { id, previewEl };
    previewEl.addEventListener('pointerdown', handlePointerDown);
    refreshFoldButtons();
  }
  // 操作のカラムは .lane-pair の中で拡大表示の右隣(拡大表示 | 操作 | 操作パネル | 実行ログ)。laneLog.js の
  // syncLogMirror が組を作り直す(拡大表示を取り出して入れ直す)ので毎回位置を確かめる。**ずれているときだけ動かす**
  // (毎周動かすとマウスを載せたボタンのツールチップが点滅する)
  if (previewEl.parentElement && previewEl.nextElementSibling !== controls) {
    previewEl.after(controls);
  }
  // パネルはこのカラムの右隣(先にカラムを置いてから並べる = 2つが互いを押しのけて毎周入れ替わらない)
  syncGridLivePanel(id, previewEl, controls);
  // 拡大表示は作り直すときに中身を空にする(deviceTiles.js の attachDeviceMirror)ので毎回見る
  if (dragOverlay.parentElement !== previewEl) {
    previewEl.appendChild(dragOverlay);
  }
}

/** el が1台表示の絵(操作を受ける画面)の中か。laneLog.js のダブルクリック(選択の切り替え)が除くのに使う */
export function isGridLiveScreenTarget(el) {
  return !!target && el instanceof Element && target.previewEl.contains(el) && !!el.closest('.lane-preview-media');
}

/** host からの live メッセージ(main.js から)。 */
export function applyGridLiveMessage(message) {
  applyGridLivePanelMessage(message);
  switch (message.type) {
    case 'devices':
      liveSelectedId = message.selectedId ?? null;
      break;
    case 'busy':
      busy = !!message.busy;
      busyObserving = busy && !!message.observing;
      applyButtonState();
      if (blockedNoticeShown && !operationBlocked()) {
        blockedNoticeShown = false;
        // 後から届いた失敗の文言(前の操作の actionError)は消さない
        if (errorEl.textContent === t('wvMonitor.live.blockedWhileBusy')) { showError(''); }
      }
      if (traceHold !== null) {
        if (busy && !busyObserving) {
          if (!traceHold.sawBusy) { startTracePlayback(); } // 軌跡の実行が始まった
          traceHold.sawBusy = true;
        } else if (!busy && traceHold.sawBusy) {
          releaseTraceOverlay(); // なぞり終えた
        }
      }
      break;
    case 'actionError':
      if (target && liveSelectedId === target.id) {
        showError(message.message || '', !!message.neutral);
      }
      // busy を立てずに返った失敗 = 撃つ前に断られた(撃った後の失敗は busy の間に届く)
      if (message.message && !busy) { releaseTraceOverlay(); }
      break;
    case 'gestureActionDone':
      finishTracePlayback(!!message.ok);
      break;
    case 'gridActionError':
      if (target && message.id === target.id) {
        releaseTraceOverlay();
        showError(message.message);
      }
      break;
  }
}

function showError(text, neutral = false) {
  if (errorEl.textContent === text && errorEl.classList.contains('neutral') === neutral) {
    return;
  }
  errorEl.textContent = text;
  errorEl.classList.toggle('neutral', neutral);
  // 行の出し入れで拡大表示の固定費(高さ)が変わる
  relayoutPreviewsForResize();
}

/** 送れたら true(操作の最中・1台表示でないときは送らない。観測の最中は送る = operationBlocked) */
function postAction(action) {
  if (!target || operationBlocked()) {
    return false;
  }
  showError('');
  const remote = liveRemoteTargetFor(target.id);
  vscode.postMessage({ type: 'gridLiveAction', id: target.id, action, ...(remote ? { remote } : {}) });
  // 「更新」以外は画面を変える操作 = パネルの枠を消す(gridLivePanel.js の枠の鮮度)
  if (action.type !== 'refreshSnapshot') { noteScreenAction(); }
  return true;
}
initGridLivePanel({ postAction, showStill: showMirrorStill, isRunning: isDeviceRunning });

document.getElementById('grid-live-btn-back').addEventListener('click', () => exitSingleSelection());
document.getElementById('grid-live-btn-home').addEventListener('click', () => postAction({ type: 'home' }));
document.getElementById('grid-live-btn-app-switcher').addEventListener('click', () => postAction({ type: 'appSwitcher' }));
document.getElementById('grid-live-btn-zoom-in').addEventListener('click', () => postAction({ type: 'pinch', zoomIn: true }));
document.getElementById('grid-live-btn-zoom-out').addEventListener('click', () => postAction({ type: 'pinch', zoomIn: false }));
const refreshFoldButtons = bindFoldButtons(
  buttons.filter((button) => button.dataset.fold),
  () => target?.id ?? null,
  (state) => postAction({ type: 'fold', state }),
);
// ボタンの押下を拡大表示のダブルクリック(選択の切り替え)へ伝えない
controls.addEventListener('dblclick', (event) => event.stopPropagation());

// 修飾キーの表示灯: ダブルタップ = Command(Meta)・軌跡 = Option(Alt)を押している間だけ点け、押し続けたら
// HELD_TIP_DELAY_MS 後に説明のツールチップも出す。**ツールチップを出すのは1台表示の間だけ**で、入力欄で押したとき
// (⌘V 等)・他のキーと一緒に押したとき(⌘C・⌘⇧P 等のショートカット)は出さない。
// 点け消しは状態が変わったときだけ(pointermove が毎回呼ぶ = 毎回置き直すとツールチップが揺れる)
setHoverTip(traceIndicator, traceIndicator.title);
setHoverTip(doubleTapIndicator, doubleTapIndicator.title);
const heldTipTimers = new Map(); // 表示灯 → ツールチップを出す setTimeout
function cancelHeldTip(indicator) {
  clearTimeout(heldTipTimers.get(indicator));
  heldTipTimers.delete(indicator);
  setHeldTip(indicator, false);
}
function cancelHeldTips() {
  cancelHeldTip(traceIndicator);
  cancelHeldTip(doubleTapIndicator);
}
function setModifierIndicator(indicator, on, showTip = true) {
  if (indicator.classList.contains('active') === !!on) { return; }
  indicator.classList.toggle('active', !!on);
  cancelHeldTip(indicator);
  if (on && showTip && target !== null) {
    heldTipTimers.set(indicator, setTimeout(() => {
      heldTipTimers.delete(indicator);
      if (indicator.classList.contains('active') && target !== null) { setHeldTip(indicator, true); }
    }, HELD_TIP_DELAY_MS));
  }
}
function setTraceIndicator(on, showTip) { setModifierIndicator(traceIndicator, on, showTip); }
function setDoubleTapIndicator(on, showTip) { setModifierIndicator(doubleTapIndicator, on, showTip); }
function isTextEntry(el) {
  return el instanceof Element && (el.closest('input, textarea, select, [contenteditable="true"]') !== null);
}
const MODIFIER_KEYS = new Set(['Meta', 'Alt', 'Shift', 'Control']);
window.addEventListener('keydown', (event) => {
  if (!MODIFIER_KEYS.has(event.key)) {
    cancelHeldTips(); // ショートカットの途中 = 表示灯は点けたまま、説明は出さない
    return;
  }
  const showTip = !isTextEntry(event.target);
  if (event.key === 'Meta') { setDoubleTapIndicator(true, showTip); }
  if (event.key === 'Alt') { setTraceIndicator(true, showTip); }
});
window.addEventListener('keyup', (event) => {
  if (event.key === 'Meta') { setDoubleTapIndicator(false); }
  if (event.key === 'Alt') { setTraceIndicator(false); }
});
window.addEventListener('blur', () => { setTraceIndicator(false); setDoubleTapIndicator(false); });

// 座標がウィンドウの原点ちょうど (0,0) のポインターイベントは採らない。押したまま動かしている最中に (0,0) の
// イベントが1つだけ混ざり、軌跡が絵の左上の角を経由してデバイスにもその形で送られた(実地: Option+ドラッグ)。
// 原点は拡大表示の絵の上ではない(上にツールバー・見出しがある)ので、本物の (0,0) を捨てても失うものは無い
function isOriginPointer(event) {
  return event.clientX === 0 && event.clientY === 0;
}

// **押した後も絵の要素を握らず、毎回引き直す** —— 拡大表示の絵は配信の canvas と操作の結果の一枚絵の img を
// 入れ替えて出す(deviceTiles.js の renderMirror)。押した時点の要素を握っていると、入れ替わった後の矩形は 0×0 で、
// clampToRect が座標を絵の左上 (0,0) に丸め、軌跡が左上に吸われてデバイスにもその形で送られた(iOS Simulator)。
// 測れない(0×0)ときは null
function currentMediaRect() {
  const rect = target?.previewEl.querySelector('.lane-preview-media')?.getBoundingClientRect();
  return rect && rect.width > 0 && rect.height > 0 ? rect : null;
}

function clampToRect(event, rect) {
  return {
    x: Math.min(Math.max(event.clientX - rect.left, 0), rect.width),
    y: Math.min(Math.max(event.clientY - rect.top, 0), rect.height),
  };
}

function handlePointerDown(event) {
  if (event.button !== 0 || !target) {
    return;
  }
  const media = event.target instanceof Element ? event.target.closest('.lane-preview-media') : null;
  if (!media) {
    return;
  }
  // 絵の上の押下は操作として扱う(テキスト選択を始めない)
  event.preventDefault();
  event.stopPropagation();
  if (operationBlocked()) {
    // **黙って捨てない**(iOS は操作の後の観測まで busy が続き、続けて押すと2回目が空振りに見えた)。溜めて後で撃つ
    // こともしない —— 前の操作で画面が変わった後に届くと、押したつもりと違う物に当たる(観測の最中の操作を host が
    // 待って撃てるのは、観測が画面を変えないから)
    showError(t('wvMonitor.live.blockedWhileBusy'), true);
    blockedNoticeShown = true;
    return;
  }
  const rect = media.getBoundingClientRect();
  if (!(rect.width > 0) || !(rect.height > 0)) {
    return;
  }
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  // **押した時点の修飾キーを採る**(離す前に修飾キーが変わっても、構えた時点のモードで撃つ)
  releaseTraceOverlay(); // 前の軌跡の線は、次のドラッグで消す
  dragStart = {
    id: target.id, pointerId: event.pointerId, downAt: performance.now(), x, y,
    displayWidth: rect.width, displayHeight: rect.height,
    doubleTap: event.metaKey, trace: event.altKey, moveAt: null, lastX: x, lastY: y,
    points: [{ x, y, t: 0 }],
  };
  // 構成中のジェスチャを見せる(デバイス側のスワイプは離したときに1回で実行される)
  placeOverlay(rect);
  updateOverlay(x, y);
  dragOverlay.classList.remove('long-press');
  longPressLabel.setAttribute('x', String(x + 14));
  longPressLabel.setAttribute('y', String(y - 10));
  longPressLabel.textContent = t('wvMonitor.live.longPressMark');
  const pressed = dragStart;
  // ダブルタップのモード(Command)は押していた時間に関係なくダブルタップを送るので出さない(送るものと食い違う)
  pressed.longPressTimer = pressed.doubleTap ? null : setTimeout(() => {
    if (dragStart === pressed && pressed.moveAt === null) { dragOverlay.classList.add('long-press'); }
  }, LONG_PRESS_MS);
}

// 軌跡の SVG を絵の矩形にぴったり重ねる(.lane-preview の padding box 基準)
function placeOverlay(mediaRect) {
  const host = target.previewEl;
  const hostRect = host.getBoundingClientRect();
  dragOverlay.style.left = (mediaRect.left - hostRect.left - host.clientLeft) + 'px';
  dragOverlay.style.top = (mediaRect.top - hostRect.top - host.clientTop) + 'px';
  dragOverlay.style.width = mediaRect.width + 'px';
  dragOverlay.style.height = mediaRect.height + 'px';
  dragOverlay.setAttribute('viewBox', `0 0 ${mediaRect.width} ${mediaRect.height}`);
}

// 軌跡モードは送る中身(指の軌跡)をそのまま描く。直線を描くと送るものと見えるものが食い違う
function updateOverlay(x, y) {
  dragStartDot.setAttribute('cx', dragStart.x);
  dragStartDot.setAttribute('cy', dragStart.y);
  dragLine.setAttribute('x1', dragStart.x);
  dragLine.setAttribute('y1', dragStart.y);
  dragLine.setAttribute('x2', x);
  dragLine.setAttribute('y2', y);
  dragOverlay.classList.toggle('trace', dragStart.trace);
  if (dragStart.trace) {
    dragTrace.setAttribute('points', dragStart.points.map((p) => p.x + ',' + p.y).concat([x + ',' + y]).join(' '));
  }
  dragOverlay.classList.add('visible');
}

function cancelDrag() {
  if (dragStart) { clearTimeout(dragStart.longPressTimer); }
  dragOverlay.classList.remove('long-press');
  dragStart = null;
  if (traceHold === null) { dragOverlay.classList.remove('visible'); }
}

// **軌跡は離した後も、デバイスがなぞり終えるまで線を残す**(ユーザー決定)—— デバイスは描いた時間ぶんかけて同じ軌跡を
// 再生するので、離した瞬間に消すと何をなぞっているのか分からない。消すのは: その操作の busy(observing なし)が立って
// 解けたとき・撃つ前に断られたとき(gridActionError / busy の外の actionError)・次のドラッグ・対象の変更。
// 上限[ms]: 終わりの知らせが来ない異常の保険 = 軌跡の長さ + host の待ち(切り替え・観測の終わり = SERVE_REQUEST_TIMEOUT_MS
// 20 秒)+ serve の応答待ち(同 20 秒)
const TRACE_HOLD_MARGIN_MS = 40000;
// 実行の終わりを待って線を残している軌跡(holdTraceOverlay が作る。欄の意味はそこと下の doc)
let traceHold = null;

// 離した後は、なぞった線を薄く(.playing)、再生が済んだ部分を太く(dragTraceDone)描く。**済んだ部分は推定**:
// デバイスは指の位置を返さないので、経過時間をなぞった点の t に当てて伸ばす。
// **起点は見えている絵に合わせる**: 実行の開始(host の busy)の後、拡大表示の絵が初めて描き替わった時刻を
// 「指が動き始めた点(firstMoveT)が画面に映った時刻」とみなす。busy から起点にすると、ブリッジの合成の遅れと
// 配信の遅れ(撮影 → 符号化 → 転送 → 復号)の分だけ線が絵より先走る。起点は busy の時刻より前へは戻さない
// (無関係な描き替わりを拾っても、busy 起点より先走らない)。絵が変わらない操作では、再生が終わるまで太い線を出さない。
// **速さは実際の再生に合わせる**: iOS(XCUITest の合成タッチ)はなぞった時間どおりに再生しない(MN-50.6:
// Simulator で +0.4〜1 秒・実機で +0.9〜2 秒)。操作の応答(gestureActionDone = 再生の終わり)が届いたら線を描き切り、
// 「起点から終わりまでの実際の時間 ÷ なぞった時間」をデバイスごとに覚えて、次の軌跡の線の速さにする
// (直近の1回だけ。固定の倍率を置かない = 端末・負荷で変わる)
const traceRates = new Map(); // デバイス id → 実際の再生時間 ÷ なぞった時間
function holdTraceOverlay(durationMs, points) {
  releaseTraceOverlay();
  traceHold = {
    sawBusy: false, busyAt: null, points, deviceId: target.id, rate: traceRates.get(target.id) ?? 1,
    anchorAt: null, anchorT: 0, finished: false, frame: null,
    timer: setTimeout(releaseTraceOverlay, durationMs + TRACE_HOLD_MARGIN_MS),
  };
  dragTraceDone.setAttribute('points', '');
  dragOverlay.classList.add('playing');
}
function startTracePlayback() {
  traceHold.busyAt = performance.now();
}
function noteTracePicture(deviceId) {
  if (traceHold === null || traceHold.busyAt === null || traceHold.anchorAt !== null || traceHold.finished
      || deviceId !== traceHold.deviceId) { return; }
  const now = performance.now();
  traceHold.anchorAt = now;
  traceHold.anchorT = Math.min(firstMoveT(traceHold.points, DRAG_MIN_PX), now - traceHold.busyAt);
  drawTracePlayback();
}
function traceEndT() {
  return traceHold.points[traceHold.points.length - 1].t;
}
function drawTracePlayback() {
  if (traceHold === null || (traceHold.anchorAt === null && !traceHold.finished)) { return; }
  const elapsed = traceHold.finished
    ? traceEndT()
    : traceHold.anchorT + (performance.now() - traceHold.anchorAt) / traceHold.rate;
  dragTraceDone.setAttribute('points',
    tracePrefix(traceHold.points, elapsed).map((p) => p.x + ',' + p.y).join(' '));
  traceHold.frame = !traceHold.finished && elapsed < traceEndT() ? requestAnimationFrame(drawTracePlayback) : null;
}
function finishTracePlayback(ok) {
  if (traceHold === null || traceHold.finished || traceHold.busyAt === null) { return; }
  if (!ok) {
    releaseTraceOverlay(); // 再生できなかった = 描き切ると終わったように見える。速さも覚えない
    return;
  }
  if (traceHold.anchorAt !== null) {
    const actual = performance.now() - traceHold.anchorAt;
    const traced = traceEndT() - traceHold.anchorT;
    if (actual > 0 && traced > 0) { traceRates.set(traceHold.deviceId, actual / traced); }
  }
  traceHold.finished = true;
  if (traceHold.frame !== null) { cancelAnimationFrame(traceHold.frame); }
  drawTracePlayback();
}
function releaseTraceOverlay() {
  if (traceHold === null) { return; }
  clearTimeout(traceHold.timer);
  if (traceHold.frame !== null) { cancelAnimationFrame(traceHold.frame); }
  traceHold = null;
  dragTraceDone.setAttribute('points', '');
  dragOverlay.classList.remove('playing');
  if (dragStart === null) { dragOverlay.classList.remove('visible'); }
}

window.addEventListener('pointermove', (event) => {
  if (isOriginPointer(event)) {
    return; // 修飾キーの表示灯もこのイベントの修飾キーで切り替えない
  }
  setTraceIndicator(event.altKey);
  setDoubleTapIndicator(event.metaKey);
  if (!dragStart || event.pointerId !== dragStart.pointerId) {
    return;
  }
  const rect = currentMediaRect();
  if (rect === null) {
    return; // 絵が測れない瞬間の点は採らない(currentMediaRect)
  }
  const { x, y } = clampToRect(event, rect);
  dragStart.lastX = x;
  dragStart.lastY = y;
  if (dragStart.moveAt === null && Math.hypot(x - dragStart.x, y - dragStart.y) >= DRAG_MIN_PX) {
    dragStart.moveAt = performance.now();
  }
  if (!dragStart.trace) {
    updateOverlay(x, y);
    return;
  }
  const elapsed = performance.now() - dragStart.downAt;
  if (elapsed > TRACE_MAX_MS && dragStart.moveAt !== null) {
    // なぞっている最中に上限を超えたら中止して言う(離すまで気付けないと操作が無駄になる)
    cancelDrag();
    showError(t('wvMonitor.live.traceTooLong', { max: TRACE_MAX_MS / 1000 }));
    return;
  }
  dragStart.points.push({ x, y, t: Math.round(elapsed) });
  updateOverlay(x, y);
});

window.addEventListener('pointerup', (event) => {
  if (!dragStart || event.pointerId !== dragStart.pointerId) {
    return;
  }
  const start = dragStart;
  cancelDrag();
  if (!target || target.id !== start.id) {
    return;
  }
  const rect = currentMediaRect();
  // 離した位置が原点 (0,0)・絵が測れないなら、最後に採った位置で離したことにする(isOriginPointer・currentMediaRect)
  const { x, y } = isOriginPointer(event) || rect === null
    ? { x: start.lastX, y: start.lastY } : clampToRect(event, rect);
  const display = rect === null
    ? { displayWidth: start.displayWidth, displayHeight: start.displayHeight }
    : { displayWidth: rect.width, displayHeight: rect.height };
  const upAt = performance.now();
  if (Math.hypot(x - start.x, y - start.y) < DRAG_MIN_PX) {
    // 動かさずに離した: Command ならダブルタップ、LONG_PRESS_MS 以上押していれば長押し、それ以外はタップ
    // (Option だけのクリックもタップ)
    const holdMs = Math.max(0, Math.round(upAt - start.downAt));
    if (start.doubleTap) {
      postAction({ type: 'doubleTapPoint', clickX: x, clickY: y, ...display });
    } else if (holdMs >= LONG_PRESS_MS) {
      postAction({ type: 'pressPoint', clickX: x, clickY: y, ...display, holdMs });
    } else {
      postAction({ type: 'tapPoint', clickX: x, clickY: y, ...display });
    }
  } else if (start.trace) {
    const endT = Math.max(1, Math.round(upAt - start.downAt));
    const points = start.points.concat([{ x, y, t: endT }]);
    if (postAction({ type: 'tracePoints', points: thinTracePoints(points), ...display })) {
      // 描いた軌跡をそのまま残す(holdTraceOverlay の doc)
      dragTrace.setAttribute('points', points.map((p) => p.x + ',' + p.y).join(' '));
      dragOverlay.classList.add('trace', 'visible');
      holdTraceOverlay(endT, points);
    }
  } else {
    const moveAt = start.moveAt ?? upAt;
    postAction({
      type: 'dragPoints',
      fromX: start.x, fromY: start.y, toX: x, toY: y, ...display,
      pressMs: Math.max(0, Math.round(moveAt - start.downAt)),
      dragMs: Math.max(1, Math.round(upAt - moveAt)),
    });
  }
});

window.addEventListener('pointercancel', () => cancelDrag());
